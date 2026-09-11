import { Fragment, useEffect, useState } from 'react'
import { RefreshCw, Zap, Server, Monitor, KeyRound, ChevronDown, ChevronRight } from 'lucide-react'
import { Tip } from '../components/usage/Tip'
import { api } from '../services/api'
import type { UsageCache, AccountInfo, AiosSession } from '../types/aios'
import { UsageChart } from '../components/usage/UsageChart'
import { SessionDrillDown } from '../components/usage/SessionDrillDown'
import { LimitsPanel } from '../components/usage/LimitsPanel'
import { ModelGuardPanel } from '../components/usage/ModelGuardPanel'
// pricing.ts still used by SessionDrillDown (per-conversation cost with known model)

function fmtTokens(n: number): string {
  if (!n || n < 0) return '0'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}

function fmtRelative(iso: string | null): string {
  if (!iso) return '—'
  const t = new Date(iso).getTime()
  if (isNaN(t)) return '—'
  const diff = Date.now() - t
  const s = Math.floor(diff / 1000)
  if (s < 60) return 'just now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

function burnColor(n: number): string {
  if (n >= 100_000_000) return '#ef4444'
  if (n >= 10_000_000) return '#eab308'
  if (n > 0) return '#22c55e'
  return '#6b7280'
}

type SortKey = 'tokens_5m' | 'tokens_15m' | 'tokens_24h' | 'tokens_48h' | 'tokens_7d' | 'total_tokens' | 'conversations' | 'name' | 'pct_share'

export function UsagePage() {
  const [cache, setCache] = useState<UsageCache | null>(null)
  const [accounts, setAccounts] = useState<AccountInfo[]>([])
  const [sessions, setSessions] = useState<AiosSession[]>([])
  const [refreshing, setRefreshing] = useState(false)
  const [sortKey, setSortKey] = useState<SortKey>('tokens_24h')
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc')
  const [error, setError] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [accountFilter, setAccountFilter] = useState<string>('all')

  const toggleExpand = (name: string) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      return next
    })
  }

  const load = async () => {
    try {
      const [c, a, s] = await Promise.all([api.usage.get(), api.accounts.list(), api.sessions.list()])
      setCache(c)
      setAccounts(a)
      setSessions(s)
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Load failed')
    }
  }

  useEffect(() => {
    load()
    const t = setInterval(load, 15000)
    return () => clearInterval(t)
  }, [])

  const handleRefresh = async () => {
    setRefreshing(true)
    try {
      await api.usage.refresh()
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Refresh failed')
    } finally {
      setRefreshing(false)
    }
  }

  const handleSort = (key: SortKey) => {
    if (sortKey === key) {
      setSortDir(sortDir === 'asc' ? 'desc' : 'asc')
    } else {
      setSortKey(key)
      setSortDir('desc')
    }
  }

  // Unique account names for the filter toggle
  const accountNames = Array.from(new Set(
    (cache?.sessions || []).map((s) => s.account).filter(Boolean)
  )).sort()

  const filteredSessions = cache?.sessions.filter((s) => {
    if (accountFilter === 'all') return true
    return (s.account || '') === accountFilter
  }) || []

  // % share: this session's 7d tokens as a percentage of all visible sessions' 7d total
  const total7d = filteredSessions.reduce((s, r) => s + (r.usage?.tokens_7d || 0), 0)
  const pctShare = (row: UsageCache['sessions'][number]) =>
    total7d > 0 ? ((row.usage?.tokens_7d || 0) / total7d) * 100 : 0

  const sortedRows = filteredSessions.slice().sort((a, b) => {
    let av: number | string
    let bv: number | string
    if (sortKey === 'name') {
      av = a.name
      bv = b.name
    } else if (sortKey === 'pct_share') {
      av = pctShare(a)
      bv = pctShare(b)
    } else {
      av = (a.usage as Record<string, number>)[sortKey] || 0
      bv = (b.usage as Record<string, number>)[sortKey] || 0
    }
    const cmp = av < bv ? -1 : av > bv ? 1 : 0
    return sortDir === 'asc' ? cmp : -cmp
  }) || []

  const totals = filteredSessions.reduce(
    (acc, row) => ({
      tokens_24h: acc.tokens_24h + (row.usage?.tokens_24h || 0),
      tokens_7d: acc.tokens_7d + (row.usage?.tokens_7d || 0),
      total: acc.total + (row.usage?.total_tokens || 0),
      convs: acc.convs + (row.usage?.conversations || 0),
    }),
    { tokens_24h: 0, tokens_7d: 0, total: 0, convs: 0 },
  ) || { tokens_24h: 0, tokens_7d: 0, total: 0, convs: 0 }

  const accountByName = new Map(accounts.map((a) => [a.name, a]))

  return (
    <div className="p-6 max-w-[1400px] mx-auto">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-bold flex items-center gap-2">
            <Zap className="w-6 h-6 text-accent" />
            Token Usage
          </h1>
          <p className="text-sm text-muted mt-1">
            Per-session token consumption parsed from Claude Code JSONL conversations.
            {cache?.refreshed_at && ` Cached ${fmtRelative(cache.refreshed_at)}.`}
          </p>
        </div>
        <div className="flex items-center gap-3">
          {/* Account filter */}
          <div className="flex rounded bg-surface border border-border overflow-hidden text-xs">
            <button
              onClick={() => setAccountFilter('all')}
              className={`px-3 py-1.5 ${accountFilter === 'all' ? 'bg-accent/20 text-accent' : 'text-muted hover:text-white'}`}
            >
              All
            </button>
            {accountNames.map((name) => (
              <button
                key={name}
                onClick={() => setAccountFilter(name)}
                className={`px-3 py-1.5 ${accountFilter === name ? 'bg-accent/20 text-accent' : 'text-muted hover:text-white'}`}
              >
                {name}
              </button>
            ))}
          </div>

          <button
            onClick={handleRefresh}
            disabled={refreshing}
            className="flex items-center gap-1.5 px-3 py-2 rounded bg-accent/20 text-accent hover:bg-accent/30 disabled:opacity-50 text-sm"
          >
            <RefreshCw className={`w-4 h-4 ${refreshing ? 'animate-spin' : ''}`} />
            {refreshing ? 'Refreshing…' : 'Refresh'}
          </button>
        </div>
      </div>

      {error && (
        <div className="mb-4 p-3 rounded bg-danger/10 border border-danger/30 text-danger text-sm">
          {error}
        </div>
      )}

      {/* Subscription limits (live from Anthropic headers) */}
      <LimitsPanel />

      {/* Model Guard — auto Opus→Sonnet→Haiku based on 5h limits */}
      <ModelGuardPanel />

      {/* Time-series chart */}
      <div className="mb-6">
        <UsageChart cache={cache ? { ...cache, sessions: filteredSessions } : null} />
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-4 gap-4 mb-6">
        <SummaryCard label="Last 24h" value={fmtTokens(totals.tokens_24h)} color={burnColor(totals.tokens_24h)}
          tooltip="Total tokens (input + cache + output) consumed across all sessions in the last 24 hours. This is raw token count, not weighted by cost — cache_read tokens are ~10% the price of fresh input." />
        <SummaryCard label="Last 7 days" value={fmtTokens(totals.tokens_7d)} color="#9ca3af"
          tooltip="Total tokens consumed across all sessions in the last 7 days. Includes all token types (input, cache creation, cache read, output)." />
        <SummaryCard label="All-time" value={fmtTokens(totals.total)} color="#9ca3af"
          tooltip="Lifetime total tokens across all sessions and all conversations ever recorded in Claude Code's local JSONL files. This number only grows — it includes ALL historical usage." />
        <SummaryCard label="Conversations" value={String(totals.convs)} color="#9ca3af"
          tooltip="Total number of distinct conversations (JSONL files) across all sessions. Each 'claude' invocation or 'claude -p' call creates one conversation file." />
      </div>

      {/* Accounts summary */}
      {accounts.length > 0 && (
        <div className="mb-6 p-4 rounded bg-card border border-border">
          <div className="flex items-center gap-2 text-xs uppercase text-muted mb-3">
            <KeyRound className="w-3.5 h-3.5" />
            Claude Accounts
          </div>
          <div className="grid grid-cols-2 lg:grid-cols-3 gap-3">
            {accounts.map((a) => (
              <div key={a.name} className="flex items-center gap-3 p-2 rounded bg-surface">
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="font-mono text-sm">{a.name}</span>
                    {a.subscription && (
                      <span className="text-[10px] px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-300">
                        {a.subscription}
                      </span>
                    )}
                  </div>
                  <div className="text-xs text-muted truncate">{a.email || '(no email set)'}</div>
                </div>
                <div className="text-xs text-muted">{a.usedBy.length} session{a.usedBy.length !== 1 ? 's' : ''}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Table */}
      <div className="bg-card border border-border rounded overflow-x-auto">
        <table className="w-full text-sm min-w-[1000px]">
          <thead className="bg-surface border-b border-border">
            <tr>
              <th className="w-6"></th>
              <Th label="Session" sortKey="name" current={sortKey} dir={sortDir} onSort={handleSort} />
              <th className="text-left px-3 py-2 text-xs uppercase text-muted">Type</th>
              <th className="text-left px-3 py-2 text-xs uppercase text-muted">Account</th>
              <Th label="Convs" sortKey="conversations" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="Number of distinct conversations. Each 'claude' command or 'claude -p' call creates one."
                technical="Count of *.jsonl files (excluding subagent files) under ~/.claude/projects/<slug>/. Each file = one conversation session." />
              <Th label="5m" sortKey="tokens_5m" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="Tokens consumed in the last 5 minutes. Updates with each cache refresh (~2 min) — useful to spot which session is actively burning right now."
                technical="Sum of (input + cache_creation + cache_read + output) for all assistant messages with timestamps within the last 300 seconds." />
              <Th label="15m" sortKey="tokens_15m" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="Tokens consumed in the last 15 minutes. Smooths over short pauses better than 5m for visualizing recent activity."
                technical="Same formula as 5m but within 900 seconds." />
              <Th label="24h" sortKey="tokens_24h" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="Total tokens consumed in the last 24 hours. Includes all types — cache reads are cheap but inflate this number."
                technical="Sum of (input + cache_creation + cache_read + output) for all assistant messages with timestamps within the last 86400 seconds. Parsed from JSONL files." />
              <Th label="48h" sortKey="tokens_48h" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="Total tokens consumed in the last 48 hours."
                technical="Same formula as 24h but within 172800 seconds." />
              <Th label="7d" sortKey="tokens_7d" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="Total tokens consumed in the last 7 days. Same counting as 24h but wider window."
                technical="Same formula as 24h but within 604800 seconds. Aligns roughly with the 7-day subscription limit window." />
              <Th label="Total tok" sortKey="total_tokens" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="Lifetime total tokens across all conversations ever recorded for this session. This number only grows."
                technical="Sum across ALL assistant messages in ALL JSONL files for this session's project slug. No time filter applied." />
              <Th label="% share" sortKey="pct_share" current={sortKey} dir={sortDir} onSort={handleSort} right
                info="This session's share of total token burn across all visible sessions. Shows which sessions are consuming the most relative to everything else."
                technical="Calculated as: this session's 7d tokens / sum of all visible sessions' 7d tokens × 100. Uses the 7-day window to match the subscription's weekly limit cycle. Filtered by the All/max/pro toggle." />
              <th className="text-right px-3 py-2 text-xs uppercase text-muted">
                <span className="inline-flex items-center justify-end">
                  Last
                  <Tip
                    info="When was the last message exchanged with Claude in this session's project directory."
                    technical="Derived from file modification time of the most recent JSONL file under the session's project slug. On VPS, uses find -printf '%T@'."
                  />
                </span>
              </th>
            </tr>
          </thead>
          <tbody>
            {sortedRows.map((row) => {
              const acct = row.account ? accountByName.get(row.account) : null
              const accountLabel = acct?.email || row.account || '—'
              const isExpanded = expanded.has(row.name)
              const sessionCfg = sessions.find((s) => s.name === row.name)
              const sessionPath = sessionCfg?.path || ''
              const hasConversations = (row.usage.conversations || 0) > 0
              return (
                <Fragment key={row.name}>
                  <tr
                    className={`border-b border-border hover:bg-white/5 ${hasConversations ? 'cursor-pointer' : ''}`}
                    onClick={() => hasConversations && toggleExpand(row.name)}
                  >
                    <td className="px-2 py-2 text-muted">
                      {hasConversations && (
                        isExpanded ? <ChevronDown className="w-3.5 h-3.5" /> : <ChevronRight className="w-3.5 h-3.5" />
                      )}
                    </td>
                    <td className="px-3 py-2 font-medium">
                      <div className="flex items-center gap-2">
                        {row.type === 'remote' ? (
                          <Server className="w-3.5 h-3.5 text-purple-400" />
                        ) : (
                          <Monitor className="w-3.5 h-3.5 text-cyan-400" />
                        )}
                        {row.name}
                      </div>
                    </td>
                    <td className="px-3 py-2 text-xs text-muted">{row.type}</td>
                    <td className="px-3 py-2 text-xs text-muted truncate max-w-[200px]">
                      <div className="truncate">{accountLabel}</div>
                      {acct?.subscription && (
                        <div className="text-[10px] text-muted">{acct.subscription}</div>
                      )}
                    </td>
                    <td className="px-3 py-2 text-right tabular-nums text-muted">{row.usage.conversations}</td>
                    <td
                      className="px-3 py-2 text-right tabular-nums font-medium"
                      style={{ color: (row.usage.tokens_5m || 0) > 0 ? '#34d399' : '#6b7280' }}
                    >
                      {fmtTokens(row.usage.tokens_5m || 0)}
                    </td>
                    <td className="px-3 py-2 text-right tabular-nums text-gray-300">{fmtTokens(row.usage.tokens_15m || 0)}</td>
                    <td
                      className="px-3 py-2 text-right tabular-nums font-medium"
                      style={{ color: burnColor(row.usage.tokens_24h) }}
                    >
                      {fmtTokens(row.usage.tokens_24h)}
                    </td>
                    <td className="px-3 py-2 text-right tabular-nums text-gray-300">{fmtTokens(row.usage.tokens_48h || 0)}</td>
                    <td className="px-3 py-2 text-right tabular-nums text-gray-300">{fmtTokens(row.usage.tokens_7d)}</td>
                    <td className="px-3 py-2 text-right tabular-nums text-gray-400">{fmtTokens(row.usage.total_tokens)}</td>
                    <td className="px-3 py-2 text-right tabular-nums text-gray-300 font-medium">
                      {pctShare(row) >= 0.1 ? `${pctShare(row).toFixed(1)}%` : pctShare(row) > 0 ? '<0.1%' : '—'}
                    </td>
                    <td className="px-3 py-2 text-right text-xs text-muted">{fmtRelative(row.usage.last_activity)}</td>
                  </tr>
                  {isExpanded && (
                    <tr>
                      <td colSpan={13} className="p-0">
                        <SessionDrillDown
                          sessionName={row.name}
                          sessionPath={sessionPath}
                          conversations={row.usage.top_conversations}
                        />
                      </td>
                    </tr>
                  )}
                </Fragment>
              )
            })}
          </tbody>
        </table>
      </div>

      <p className="text-[11px] text-muted mt-4 leading-relaxed">
        24h/7d windows are computed from assistant-turn timestamps inside each conversation JSONL file.
        Usage cache refreshes automatically every 2 minutes in the background. Totals exclude subagent jsonl files.
        Token counts include input + cache read + cache creation + output.
      </p>
    </div>
  )
}

function SummaryCard({ label, value, color, tooltip }: { label: string; value: string; color: string; tooltip?: string }) {
  return (
    <div className="bg-card border border-border rounded p-4" title={tooltip}>
      <div className="text-xs uppercase text-muted">{label}</div>
      <div className="text-2xl font-bold mt-1 tabular-nums" style={{ color }}>
        {value}
      </div>
    </div>
  )
}

function Th({
  label,
  sortKey,
  current,
  dir,
  onSort,
  right = false,
  tooltip,
  info,
  technical,
}: {
  label: string
  sortKey: SortKey
  current: SortKey
  dir: 'asc' | 'desc'
  onSort: (key: SortKey) => void
  right?: boolean
  tooltip?: string
  info?: string
  technical?: string
}) {
  const isActive = current === sortKey
  return (
    <th
      className={`${right ? 'text-right' : 'text-left'} px-3 py-2 text-xs uppercase text-muted cursor-pointer select-none hover:text-white`}
      onClick={() => onSort(sortKey)}
      title={tooltip}
    >
      <span className={`inline-flex items-center ${right ? 'justify-end' : ''}`}>
        {label}
        {isActive && <span className="ml-1">{dir === 'asc' ? '↑' : '↓'}</span>}
        {info && technical && <Tip info={info} technical={technical} />}
      </span>
    </th>
  )
}
