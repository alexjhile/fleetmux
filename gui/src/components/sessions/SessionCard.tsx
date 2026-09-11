import { useState } from 'react'
import { Link } from 'react-router-dom'
import { Play, Square, Send, Server, Monitor, GitBranch, HardDrive, MemoryStick, Clock, ArrowUp, ArrowDown, Check, AlertTriangle, Zap, RotateCw } from 'lucide-react'
import type { AiosSession } from '../../types/aios'
import { api } from '../../services/api'
import { AccountPicker, invalidateAccountCache } from './AccountPicker'
import { modelLabel } from '../usage/pricing'

function fmtTokens(n: number): string {
  if (!n || n < 0) return '0'
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}

function burnColor(tokens24h: number): string {
  if (tokens24h >= 100_000_000) return '#ef4444' // red for > 100M
  if (tokens24h >= 10_000_000) return '#eab308'  // yellow
  if (tokens24h > 0) return '#22c55e'            // green
  return '#6b7280'                                // gray = no activity
}

const stateStyles = {
  running: { dot: 'bg-success', badge: 'bg-success/20 text-success', label: 'Running' },
  idle: { dot: 'bg-warning', badge: 'bg-warning/20 text-warning', label: 'Idle' },
  stopped: { dot: 'bg-gray-500', badge: 'bg-gray-500/20 text-gray-400', label: 'Stopped' },
}

function timeAgo(isoDate: string): string {
  const diff = Date.now() - new Date(isoDate).getTime()
  const s = Math.floor(diff / 1000)
  if (s < 0) return 'now'
  if (s < 60) return 'now'
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

function diskColor(disk?: string): string {
  if (!disk) return '#6b7280'
  const pct = parseInt(disk.replace('%', ''), 10)
  if (isNaN(pct)) return '#6b7280'
  if (pct >= 85) return '#ef4444'
  if (pct >= 70) return '#eab308'
  return '#22c55e'
}

function SyncBadge({ status, ahead, behind }: { status: string; ahead: number; behind: number }) {
  switch (status) {
    case 'synced':
      return (
        <span className="flex items-center gap-0.5 text-[10px]" style={{ color: '#22c55e' }}>
          <Check className="w-3 h-3" /> synced
        </span>
      )
    case 'ahead':
      return (
        <span className="flex items-center gap-0.5 text-[10px]" style={{ color: '#3b82f6' }}>
          <ArrowUp className="w-3 h-3" /> {ahead} ahead
        </span>
      )
    case 'behind':
      return (
        <span className="flex items-center gap-0.5 text-[10px]" style={{ color: '#eab308' }}>
          <ArrowDown className="w-3 h-3" /> {behind} behind
        </span>
      )
    case 'diverged':
      return (
        <span className="flex items-center gap-0.5 text-[10px]" style={{ color: '#ef4444' }}>
          <AlertTriangle className="w-3 h-3" /> diverged
        </span>
      )
    default:
      return null
  }
}

export function SessionCard({ session, onRefresh }: { session: AiosSession; onRefresh: () => void }) {
  const [task, setTask] = useState('')
  const [sending, setSending] = useState(false)
  const [acting, setActing] = useState(false)
  const [showDirty, setShowDirty] = useState(false)
  const style = stateStyles[session.state]
  const gd = session.gitDetail
  const hasDirty = gd && (gd.modified > 0 || gd.untracked > 0)

  const [actionError, setActionError] = useState<string | null>(null)

  const handleStartStop = async () => {
    setActing(true)
    setActionError(null)
    try {
      if (session.state === 'stopped') await api.sessions.start(session.name)
      else await api.sessions.stop(session.name)
      setTimeout(onRefresh, 1000)
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Action failed')
    } finally {
      setActing(false)
    }
  }

  const handleDispatch = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!task.trim() || session.state === 'stopped') return
    setSending(true)
    try {
      await api.tasks.dispatch(session.name, task)
      setTask('')
      onRefresh()
    } finally {
      setSending(false)
    }
  }

  return (
    <div className="bg-card border border-border rounded-lg p-4 hover:border-accent/30 transition-colors">
      {/* Header */}
      <div className="flex items-start justify-between mb-1">
        <Link to={`/session/${session.name}`} className="flex items-center gap-2 group">
          {session.type === 'remote' ? (
            <Server className="w-4 h-4 text-purple-400" />
          ) : (
            <Monitor className="w-4 h-4 text-cyan-400" />
          )}
          <h3 className="font-semibold group-hover:text-accent transition-colors">{session.name}</h3>
        </Link>
        <div className="flex flex-col items-end gap-0.5">
          <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${style.badge}`}>
            {style.label}
          </span>
          {session.state === 'running' && session.activity && (
            <span className="text-[10px] font-medium animate-pulse-dot" style={{ color: '#22c55e' }}>
              {session.activity}...
            </span>
          )}
          {session.state === 'idle' && (
            <span className="text-[10px] font-medium" style={{ color: '#eab308' }}>
              <span className="animate-blink">▍</span> Ready
            </span>
          )}
        </div>
      </div>

      {/* Description */}
      <p className="text-xs text-muted mb-2 line-clamp-1">{session.description}</p>

      {/* Last task */}
      {session.lastTask && (
        <div className="flex items-center gap-1.5 text-[11px] mb-2 min-w-0">
          {session.lastTask.status === 'completed' && (
            <span className="shrink-0" style={{ color: '#22c55e' }}>✓</span>
          )}
          {session.lastTask.status === 'failed' && (
            <span className="shrink-0" style={{ color: '#ef4444' }}>✗</span>
          )}
          {session.lastTask.status === 'dispatched' && (
            <span className="shrink-0 animate-pulse-dot" style={{ color: '#eab308' }}>⟳</span>
          )}
          <span className="truncate" style={{ color: '#9ca3af' }}>
            {session.lastTask.task}
          </span>
          <span className="shrink-0" style={{ color: '#6b7280' }}>
            {timeAgo(session.lastTask.completed_at || session.lastTask.dispatched_at)}
          </span>
        </div>
      )}

      {/* Tags + Account picker */}
      <div className="flex flex-wrap items-center gap-1 mb-2">
        {session.tags.map((tag) => (
          <span key={tag} className="text-[10px] px-1.5 py-0.5 rounded bg-white/5 text-gray-400">
            {tag}
          </span>
        ))}
        <div className="ml-auto">
          <AccountPicker
            sessionName={session.name}
            currentAccount={session.account}
            currentEmail={session.accountMeta?.email}
            currentTier={session.accountMeta?.subscription}
            onChange={() => {
              invalidateAccountCache()
              onRefresh()
            }}
          />
        </div>
      </div>

      {/* Token burn badge */}
      {session.usage && (session.usage.tokens_24h > 0 || session.usage.total_tokens > 0) && (
        <div className="flex items-center gap-2 mb-2 text-[10px]">
          <span className="flex items-center gap-1" title="Tokens in last 24 hours">
            <Zap className="w-3 h-3" style={{ color: burnColor(session.usage.tokens_24h) }} />
            <span style={{ color: burnColor(session.usage.tokens_24h) }}>
              {fmtTokens(session.usage.tokens_24h)}
            </span>
            <span className="text-muted">24h</span>
          </span>
          <span className="text-muted">·</span>
          <span className="text-muted">{fmtTokens(session.usage.tokens_7d)} 7d</span>
          <span className="text-muted">·</span>
          <span className="text-muted">{fmtTokens(session.usage.total_tokens)} all-time</span>
          <span className="text-muted">·</span>
          <span className="text-muted">{session.usage.conversations} convs</span>
        </div>
      )}

      {/* Git detail row */}
      <div className="flex items-center gap-3 mb-1.5">
        {gd ? (
          <>
            <div className="flex items-center gap-1 text-xs text-muted">
              <GitBranch className="w-3 h-3" />
              <span>{gd.branch}</span>
            </div>
            {hasDirty && (
              <button
                onClick={() => setShowDirty(!showDirty)}
                className="flex items-center gap-1.5 text-[10px] hover:opacity-80 cursor-pointer"
                title="Click to see dirty files"
              >
                {gd.modified > 0 && (
                  <span style={{ color: '#eab308' }}>{gd.modified}M</span>
                )}
                {gd.untracked > 0 && (
                  <span style={{ color: '#6b7280' }}>{gd.untracked}U</span>
                )}
                <span style={{ color: '#4b5563' }}>{showDirty ? '▴' : '▾'}</span>
              </button>
            )}
            <SyncBadge status={gd.syncStatus} ahead={gd.ahead} behind={gd.behind} />
          </>
        ) : session.gitInfo && session.gitInfo !== '-' ? (
          <div className="flex items-center gap-1 text-xs text-muted">
            <GitBranch className="w-3 h-3" />
            <span>{session.gitInfo}</span>
          </div>
        ) : null}
      </div>

      {/* Dirty files expandable */}
      {showDirty && gd?.dirtyFiles && gd.dirtyFiles.length > 0 && (
        <div className="bg-surface border border-border rounded px-2 py-1.5 mb-2 max-h-32 overflow-y-auto">
          {gd.dirtyFiles.map((f, i) => {
            const status = f.substring(0, 2).trim()
            const name = f.substring(2).trimStart()
            const isUntracked = status === '??'
            return (
              <div key={i} className="text-[10px] font-mono flex gap-1.5 leading-relaxed">
                <span style={{ color: isUntracked ? '#6b7280' : '#eab308' }} className="shrink-0 w-5">{status}</span>
                <span className="text-gray-400 truncate">{name}</span>
              </div>
            )
          })}
        </div>
      )}

      {/* Live session metadata (model, tokens, effort, plan) */}
      {session.state !== 'stopped' && (session.live || session.usage?.top_conversations?.[0]) && (
        <div className="flex items-center gap-2 mb-2 text-[10px]">
          {(session.live?.liveModel || session.usage?.top_conversations?.[0]?.model) && (
            <span className="px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-300 font-medium">
              {session.live?.liveModel || modelLabel(session.usage?.top_conversations?.[0]?.model)}
            </span>
          )}
          {session.live?.liveEffort && (
            <span className="px-1.5 py-0.5 rounded bg-white/5 text-gray-400">
              {session.live.liveEffort} effort
            </span>
          )}
          {session.live?.livePlan && (
            <span className="px-1.5 py-0.5 rounded bg-cyan-500/15 text-cyan-400">
              {session.live.livePlan}
            </span>
          )}
          {session.live?.liveTokens != null && session.live.liveTokens > 0 && (
            <span className="text-muted ml-auto tabular-nums" title="Current conversation context size">
              {fmtTokens(session.live.liveTokens)} ctx
            </span>
          )}
          {session.live?.liveVersion && (
            <span className="text-muted" title="Claude Code version">
              v{session.live.liveVersion}
            </span>
          )}
        </div>
      )}

      {/* VPS health + uptime row */}
      <div className="flex items-center gap-3 mb-3">
        {session.type === 'remote' && session.vpsHealth && session.vpsHealth.status === 'ok' && (
          <div className="flex items-center gap-2.5 text-[10px]">
            <span className="flex items-center gap-0.5">
              <HardDrive className="w-3 h-3" style={{ color: '#6b7280' }} />
              <span style={{ color: diskColor(session.vpsHealth.disk) }}>{session.vpsHealth.disk || '-'}</span>
            </span>
            <span className="flex items-center gap-0.5">
              <MemoryStick className="w-3 h-3" style={{ color: '#6b7280' }} />
              <span style={{ color: '#9ca3af' }}>{session.vpsHealth.memory || '-'}</span>
            </span>
          </div>
        )}
        {session.type === 'remote' && session.vpsHealth && session.vpsHealth.status === 'unreachable' && (
          <span className="text-[10px] font-medium" style={{ color: '#ef4444' }}>
            ⚠ unreachable
          </span>
        )}
        {session.uptime && (
          <span className="flex items-center gap-0.5 text-[10px] text-muted">
            <Clock className="w-3 h-3" /> {session.uptime}
          </span>
        )}
        {gd?.lastCommit && (
          <span className="text-[10px] text-muted">
            committed {timeAgo(gd.lastCommit)}
          </span>
        )}
      </div>

      {/* Error message */}
      {actionError && (
        <p className="text-[11px] text-danger mb-2 truncate" title={actionError}>{actionError}</p>
      )}

      {/* Actions */}
      <div className="flex gap-2">
        <button
          onClick={handleStartStop}
          disabled={acting}
          className={`flex items-center gap-1 px-3 py-1.5 rounded text-xs font-medium transition-colors ${
            session.state === 'stopped'
              ? 'bg-success/20 text-success hover:bg-success/30'
              : 'bg-danger/20 text-danger hover:bg-danger/30'
          } disabled:opacity-50`}
        >
          {session.state === 'stopped' ? <Play className="w-3 h-3" /> : <Square className="w-3 h-3" />}
          {session.state === 'stopped' ? 'Start' : 'Stop'}
        </button>

        {session.state !== 'stopped' && (
          <button
            onClick={async () => {
              setActing(true)
              setActionError(null)
              try {
                await api.sessions.stop(session.name)
                await new Promise((r) => setTimeout(r, 1500))
                await api.sessions.start(session.name)
                setTimeout(onRefresh, 1000)
              } catch (err) {
                setActionError(err instanceof Error ? err.message : 'Restart failed')
              } finally {
                setActing(false)
              }
            }}
            disabled={acting}
            title="Restart — stop + start (applies account/config changes)"
            className="flex items-center gap-1 px-2 py-1.5 rounded text-xs font-medium bg-yellow-500/20 text-yellow-400 hover:bg-yellow-500/30 disabled:opacity-50"
          >
            <RotateCw className="w-3 h-3" />
          </button>
        )}

        {session.state !== 'stopped' && (
          <form onSubmit={handleDispatch} className="flex-1 flex gap-1">
            <input
              type="text"
              value={task}
              onChange={(e) => setTask(e.target.value)}
              placeholder="Send task..."
              className="flex-1 bg-surface border border-border rounded px-2 py-1.5 text-xs text-white placeholder:text-muted focus:outline-none focus:border-accent"
            />
            <button
              type="submit"
              disabled={sending || !task.trim()}
              className="p-1.5 rounded bg-accent/20 text-accent hover:bg-accent/30 disabled:opacity-50"
            >
              <Send className="w-3 h-3" />
            </button>
          </form>
        )}
      </div>
    </div>
  )
}
