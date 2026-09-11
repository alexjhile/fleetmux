import { useEffect, useState } from 'react'
import { Gauge, RefreshCw, AlertTriangle } from 'lucide-react'
import { api } from '../../services/api'
import type { LimitsCache, AccountLimits, LimitsWindow } from '../../types/fleetmux'
import { Tip } from './Tip'

function fmtPct(frac: number | null): string {
  if (frac == null) return '—'
  return `${Math.round(frac * 100)}%`
}

function fmtReset(epoch: number | null): string {
  if (!epoch) return '—'
  const now = Date.now() / 1000
  const secs = epoch - now
  if (secs <= 0) return 'resetting'
  if (secs < 3600) return `${Math.round(secs / 60)}m`
  if (secs < 86400) {
    const h = Math.floor(secs / 3600)
    const m = Math.round((secs % 3600) / 60)
    return `${h}h ${m}m`
  }
  const d = Math.floor(secs / 86400)
  const h = Math.round((secs % 86400) / 3600)
  return `${d}d ${h}h`
}

function barColor(frac: number | null): string {
  if (frac == null) return '#4b5563'
  if (frac >= 0.9) return '#ef4444'
  if (frac >= 0.7) return '#eab308'
  return '#22c55e'
}

const TIPS: Record<string, { info: string; technical: string }> = {
  '5-hour session': {
    info: 'How much of your current session allowance you\'ve used. When it hits 100%, you\'re rate-limited until the window rolls over.',
    technical: 'Rolling 5-hour window. Probed via a 9-token Haiku API call that reads the anthropic-ratelimit-unified-5h-utilization response header. The % is a 0-1 fraction (0.61 = 61%). Resets continuously as the oldest usage drops out.',
  },
  '7-day all models': {
    info: 'Your weekly usage budget across Opus, Sonnet, and Haiku combined. Separate from the 5-hour session limit.',
    technical: 'Rolling 7-day window from anthropic-ratelimit-unified-7d-utilization. Max (20x) plan has a higher weekly cap than Pro. On Pro, Sonnet has its own separate weekly counter.',
  },
  '7-day Opus': {
    info: 'Separate weekly budget just for Opus. Opus typically gets a smaller weekly allocation than Sonnet on most plans.',
    technical: 'From anthropic-ratelimit-unified-7d-opus-utilization header. Only present when the plan includes Opus. Absent = null in the response.',
  },
}

function UsageBar({ label, window }: { label: string; window?: LimitsWindow }) {
  const pct = window?.used_percentage ?? null
  const clamped = pct == null ? 0 : Math.min(1, Math.max(0, pct))
  const tip = TIPS[label]
  return (
    <div className="flex-1 min-w-[180px]">
      <div className="flex items-center justify-between text-[10px] text-muted mb-1">
        <span className="uppercase flex items-center">
          {label}
          {tip && <Tip info={tip.info} technical={tip.technical} />}
        </span>
        <span title={`Exact reset: ${window?.resets_at ? new Date(window.resets_at * 1000).toLocaleString() : 'unknown'}`}>
          resets in {fmtReset(window?.resets_at ?? null)}
        </span>
      </div>
      <div className="flex items-center gap-2">
        <div className="flex-1 h-2 rounded bg-surface overflow-hidden border border-border">
          <div
            className="h-full transition-all"
            style={{ width: `${clamped * 100}%`, background: barColor(pct) }}
          />
        </div>
        <span
          className="text-xs tabular-nums font-medium w-10 text-right"
          style={{ color: barColor(pct) }}
        >
          {fmtPct(pct)}
        </span>
      </div>
    </div>
  )
}

function AccountCard({ a }: { a: AccountLimits }) {
  if (a.error) {
    return (
      <div className="bg-card border border-border rounded p-3">
        <div className="flex items-center gap-2 text-sm font-semibold">
          <Gauge className="w-4 h-4" />
          <span>{a.account}</span>
          <AlertTriangle className="w-3.5 h-3.5 text-danger ml-auto" />
        </div>
        <div className="text-xs text-danger mt-2">Probe failed: {a.error}</div>
      </div>
    )
  }
  return (
    <div className="bg-card border border-border rounded p-3">
      <div className="flex items-center gap-2 text-sm font-semibold mb-2">
        <Gauge className="w-4 h-4 text-accent" />
        <span>{a.account}</span>
        {a.representative && (
          <span className="text-[10px] text-muted font-normal ml-auto flex items-center">
            limiting: {a.representative.replace('_', ' ')}
            <Tip
              info="Which budget is closest to running out right now. When this one hits 100%, you get rate-limited."
              technical="From anthropic-ratelimit-unified-representative-claim header. Anthropic picks whichever window (5h or 7d) is most constrained for you right now."
            />
          </span>
        )}
      </div>
      <div className="flex flex-col gap-2.5">
        <UsageBar label="5-hour session" window={a.five_hour} />
        <UsageBar label="7-day all models" window={a.seven_day} />
        {a.seven_day_opus?.used_percentage != null && (
          <UsageBar label="7-day Opus" window={a.seven_day_opus} />
        )}
      </div>
      {a.overage_status && a.overage_status !== 'allowed' && (
        <div className="mt-2 text-[10px] text-yellow-400 flex items-center">
          overage: {a.overage_status}
          {a.overage_disabled_reason && ` (${a.overage_disabled_reason})`}
          <Tip
            info="'Extra usage' from Settings > Billing. When ON and you exceed your plan limit, you pay per token at API rates. When OFF (rejected), you're just rate-limited — no extra charges."
            technical="From anthropic-ratelimit-unified-overage-status header. 'rejected' = extra usage disabled or limit exceeded. 'allowed' = overflow will be billed. overage_disabled_reason shows why (e.g. org_level_disabled_until, spend_limit_reached)."
          />
        </div>
      )}
    </div>
  )
}

export function LimitsPanel() {
  const [cache, setCache] = useState<LimitsCache | null>(null)
  const [refreshing, setRefreshing] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  const load = async () => {
    try {
      const c = await api.limits.get()
      setCache(c)
      setErr(null)
    } catch (e) {
      setErr(e instanceof Error ? e.message : 'load failed')
    }
  }

  useEffect(() => {
    load()
    const t = setInterval(load, 30000)
    return () => clearInterval(t)
  }, [])

  const handleRefresh = async () => {
    setRefreshing(true)
    try {
      await api.limits.refresh()
      await load()
    } finally {
      setRefreshing(false)
    }
  }

  if (!cache || cache.accounts.length === 0) {
    return null
  }

  // Alert: any account with 5h or 7d ≥ 80%
  const warnings = cache.accounts.flatMap((a) => {
    const out: string[] = []
    if (a.five_hour?.used_percentage != null && a.five_hour.used_percentage >= 0.8)
      out.push(`${a.account} session at ${Math.round(a.five_hour.used_percentage * 100)}%`)
    if (a.seven_day?.used_percentage != null && a.seven_day.used_percentage >= 0.8)
      out.push(`${a.account} weekly at ${Math.round(a.seven_day.used_percentage * 100)}%`)
    if (a.seven_day_opus?.used_percentage != null && a.seven_day_opus.used_percentage >= 0.8)
      out.push(`${a.account} Opus weekly at ${Math.round(a.seven_day_opus.used_percentage * 100)}%`)
    return out
  })

  return (
    <div className="mb-6">
      {warnings.length > 0 && (
        <div className="mb-3 p-3 rounded-lg border border-danger/40 bg-danger/10 flex items-start gap-2">
          <AlertTriangle className="w-4 h-4 text-danger shrink-0 mt-0.5" />
          <div>
            <div className="text-sm font-semibold text-danger">Approaching rate limit</div>
            <div className="text-xs text-gray-300 mt-0.5">
              {warnings.join(' · ')} — reduce usage or wait for reset to avoid throttling.
            </div>
          </div>
        </div>
      )}
      <div className="flex items-center justify-between mb-3">
        <div>
          <div className="text-xs uppercase text-muted">Subscription limits</div>
          <div className="text-[11px] text-muted">
            Live from Anthropic rate-limit headers — not a token-count estimate. Probe cost ~9 Haiku tokens per account.
            {cache.refreshed_at && (
              <span className="ml-1">Last: {new Date(cache.refreshed_at).toLocaleTimeString()}</span>
            )}
          </div>
        </div>
        <button
          onClick={handleRefresh}
          disabled={refreshing}
          className="flex items-center gap-1 px-2 py-1 rounded bg-accent/20 text-accent hover:bg-accent/30 disabled:opacity-50 text-xs"
        >
          <RefreshCw className={`w-3 h-3 ${refreshing ? 'animate-spin' : ''}`} />
          {refreshing ? 'Probing…' : 'Probe now'}
        </button>
      </div>

      {err && <div className="mb-2 text-xs text-danger">{err}</div>}

      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
        {cache.accounts.map((a) => (
          <AccountCard key={a.account} a={a} />
        ))}
      </div>
    </div>
  )
}
