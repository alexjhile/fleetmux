import { useMemo, useState } from 'react'
import type { UsageCache } from '../../types/aios'
import { Tip } from './Tip'

// Distinct colors for the top-N stacked sessions. "Other" is gray.
const PALETTE = [
  '#22c55e', // green
  '#3b82f6', // blue
  '#a855f7', // purple
  '#ef4444', // red
  '#eab308', // yellow
  '#06b6d4', // cyan
  '#ec4899', // pink
  '#f97316', // orange
]
const OTHER_COLOR = '#4b5563'

type Window = '24h' | '7d'
type Metric = 'total' | 'effective'

function fmtTokens(n: number): string {
  if (!n || n < 0) return '0'
  if (n >= 1_000_000_000) return `${(n / 1_000_000_000).toFixed(1)}B`
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}k`
  return String(n)
}

function bucketLabels(window: Window): string[] {
  const now = new Date()
  if (window === '24h') {
    // 24 hourly bins ending "now". Show every 4th hour.
    const labels: string[] = []
    for (let i = 0; i < 24; i++) {
      const hoursAgo = 23 - i
      if (i === 0) labels.push('24h')
      else if (i === 23) labels.push('now')
      else if (hoursAgo % 4 === 0) labels.push(`${hoursAgo}h`)
      else labels.push('')
    }
    return labels
  } else {
    // 7 daily bins
    const labels: string[] = []
    for (let i = 0; i < 7; i++) {
      const daysAgo = 6 - i
      const d = new Date(now)
      d.setDate(d.getDate() - daysAgo)
      if (daysAgo === 0) labels.push('today')
      else if (daysAgo === 1) labels.push('yest')
      else labels.push(d.toLocaleDateString('en-US', { weekday: 'short' }).toLowerCase())
    }
    return labels
  }
}

type Props = {
  cache: UsageCache | null
}

export function UsageChart({ cache }: Props) {
  const [window, setWindow] = useState<Window>('24h')
  const [metric, setMetric] = useState<Metric>('effective')
  const [hoverBucket, setHoverBucket] = useState<number | null>(null)

  const chartData = useMemo(() => {
    if (!cache) return null
    const bucketCount = window === '24h' ? 24 : 7
    const bucketKey = window === '24h'
      ? (metric === 'total' ? 'hourly_total' : 'hourly_effective')
      : (metric === 'total' ? 'daily_total' : 'daily_effective')

    // Per-session total across the visible window
    const perSession = cache.sessions.map((s) => {
      const buckets = (s.usage?.buckets as Record<string, number[]> | undefined)?.[bucketKey] || new Array(bucketCount).fill(0)
      const total = buckets.reduce((a, b) => a + (b || 0), 0)
      return { name: s.name, total, buckets }
    }).filter((s) => s.total > 0)

    perSession.sort((a, b) => b.total - a.total)

    const top = perSession.slice(0, PALETTE.length)
    const rest = perSession.slice(PALETTE.length)

    // Build stacked data: series[i] = { name, color, values: number[] }
    const series = top.map((s, i) => ({
      name: s.name,
      color: PALETTE[i],
      values: s.buckets,
      total: s.total,
    }))

    if (rest.length > 0) {
      const otherValues = new Array(bucketCount).fill(0)
      let otherTotal = 0
      for (const s of rest) {
        for (let i = 0; i < bucketCount; i++) otherValues[i] += s.buckets[i] || 0
        otherTotal += s.total
      }
      series.push({
        name: `other (${rest.length})`,
        color: OTHER_COLOR,
        values: otherValues,
        total: otherTotal,
      })
    }

    // Bucket sums for Y-axis scaling
    const bucketSums = new Array(bucketCount).fill(0)
    for (const s of series) {
      for (let i = 0; i < bucketCount; i++) bucketSums[i] += s.values[i] || 0
    }
    const maxBucket = Math.max(1, ...bucketSums)

    return { series, bucketSums, maxBucket, bucketCount }
  }, [cache, window, metric])

  if (!chartData) {
    return <div className="text-sm text-muted">No usage data yet.</div>
  }

  const { series, bucketSums, maxBucket, bucketCount } = chartData
  const width = 880
  const height = 260
  const padL = 56
  const padR = 16
  const padT = 16
  const padB = 36
  const innerW = width - padL - padR
  const innerH = height - padT - padB
  const barSlot = innerW / bucketCount
  const barW = Math.max(2, barSlot - 4)

  const labels = bucketLabels(window)

  const metricExplainer = metric === 'effective'
    ? {
        headline: 'Billable tokens only',
        detail: 'input + cache_creation + output — what actually costs money on Anthropic pricing.',
      }
    : {
        headline: 'All tokens (incl. cache re-reads)',
        detail: 'includes cache_read tokens. Those are replays of your conversation history and cost ~10% of fresh input.',
      }

  // Y gridlines at 0%, 25%, 50%, 75%, 100% of maxBucket
  const yTicks = [0, 0.25, 0.5, 0.75, 1.0].map((f) => ({
    y: padT + innerH - f * innerH,
    val: f * maxBucket,
  }))

  return (
    <div className="bg-card border border-border rounded p-4">
      {/* Controls */}
      <div className="flex items-start justify-between mb-3 gap-4">
        <div className="min-w-0">
          <div className="text-xs uppercase text-muted">Token burn</div>
          <div className="text-sm text-gray-300 mt-0.5">
            {hoverBucket !== null ? (
              <span>
                <span className="text-accent font-semibold">{fmtTokens(bucketSums[hoverBucket])}</span>{' '}
                <span className="text-muted">at {labels[hoverBucket] || `bin ${hoverBucket}`}</span>
              </span>
            ) : (
              <span>{fmtTokens(bucketSums.reduce((a, b) => a + b, 0))} over window</span>
            )}
          </div>
          <div className="text-[11px] text-muted mt-1.5 flex items-center gap-1">
            <span>
              <span className="text-gray-300">{metricExplainer.headline}</span>
              <span className="mx-1">—</span>
              <span>{metricExplainer.detail}</span>
            </span>
            <Tip
              info={metric === 'effective'
                ? 'Shows only the tokens that cost real money: fresh input + cache creation + output. This is what you\'d pay for on an API plan.'
                : 'Shows the total raw token count including cached re-reads of your conversation history. Useful for seeing total API volume.'}
              technical={metric === 'effective'
                ? 'Formula: input_tokens + cache_creation_input_tokens + output_tokens. Excludes cache_read_input_tokens. On Anthropic pricing, cache_read costs ~10% of fresh input — so a session showing 400M "total" might only be 10M "billable".'
                : 'Formula: input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens. cache_read dominates in long --continue sessions where the full conversation history is re-sent every turn.'}
            />
          </div>
        </div>
        <div className="flex items-start gap-4 shrink-0">
          {/* Metric toggle with clear labels */}
          <div>
            <div className="text-[10px] uppercase text-muted mb-1 text-center">Counting</div>
            <div className="flex rounded bg-surface border border-border overflow-hidden text-xs">
              <button
                onClick={() => setMetric('effective')}
                className={`px-2.5 py-1 ${metric === 'effective' ? 'bg-accent/20 text-accent' : 'text-muted hover:text-white'}`}
              >
                billable only
              </button>
              <button
                onClick={() => setMetric('total')}
                className={`px-2.5 py-1 ${metric === 'total' ? 'bg-accent/20 text-accent' : 'text-muted hover:text-white'}`}
              >
                all tokens
              </button>
            </div>
          </div>

          {/* Window toggle */}
          <div>
            <div className="text-[10px] uppercase text-muted mb-1 text-center">Window</div>
            <div className="flex rounded bg-surface border border-border overflow-hidden text-xs">
              <button
                onClick={() => setWindow('24h')}
                className={`px-3 py-1 ${window === '24h' ? 'bg-accent/20 text-accent' : 'text-muted hover:text-white'}`}
              >
                24h
              </button>
              <button
                onClick={() => setWindow('7d')}
                className={`px-3 py-1 ${window === '7d' ? 'bg-accent/20 text-accent' : 'text-muted hover:text-white'}`}
              >
                7d
              </button>
            </div>
          </div>
        </div>
      </div>

      {/* SVG chart */}
      <svg viewBox={`0 0 ${width} ${height}`} className="w-full h-auto">
        {/* Y gridlines + labels */}
        {yTicks.map((t, i) => (
          <g key={i}>
            <line
              x1={padL}
              y1={t.y}
              x2={width - padR}
              y2={t.y}
              stroke="#1f2937"
              strokeDasharray={i === 0 ? undefined : '2,3'}
            />
            <text x={padL - 6} y={t.y + 3} textAnchor="end" fontSize="10" fill="#6b7280">
              {fmtTokens(Math.round(t.val))}
            </text>
          </g>
        ))}

        {/* Bars — stacked by series */}
        {Array.from({ length: bucketCount }, (_, bi) => {
          let stackY = padT + innerH
          const x = padL + bi * barSlot + (barSlot - barW) / 2
          return (
            <g
              key={bi}
              onMouseEnter={() => setHoverBucket(bi)}
              onMouseLeave={() => setHoverBucket(null)}
            >
              {/* Invisible hover zone covering full column */}
              <rect x={padL + bi * barSlot} y={padT} width={barSlot} height={innerH} fill="transparent" />
              {series.map((s, si) => {
                const v = s.values[bi] || 0
                if (v === 0) return null
                const h = (v / maxBucket) * innerH
                stackY -= h
                return <rect key={si} x={x} y={stackY} width={barW} height={h} fill={s.color} opacity={hoverBucket === null || hoverBucket === bi ? 1 : 0.35} />
              })}
            </g>
          )
        })}

        {/* X labels */}
        {labels.map((label, i) => {
          if (!label) return null
          const x = padL + i * barSlot + barSlot / 2
          return (
            <text key={i} x={x} y={height - padB + 16} textAnchor="middle" fontSize="10" fill="#6b7280">
              {label}
            </text>
          )
        })}
      </svg>

      {/* Legend */}
      <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-[11px]">
        {series.map((s) => (
          <div key={s.name} className="flex items-center gap-1.5">
            <span className="w-3 h-3 rounded-sm inline-block" style={{ background: s.color }} />
            <span className="text-gray-300">{s.name}</span>
            <span className="text-muted">{fmtTokens(s.total)}</span>
          </div>
        ))}
      </div>

      <p className="mt-2 text-[10px] text-muted">
        Parsed from Claude Code conversation JSONL files. Each bar stacks the top sessions for that bucket; hover a column to see the total.
      </p>
    </div>
  )
}
