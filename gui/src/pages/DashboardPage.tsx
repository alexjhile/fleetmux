import { useState } from 'react'
import { Monitor, Server, Zap, Activity, GitBranch, AlertTriangle, RefreshCw, ArrowDownUp, TerminalSquare } from 'lucide-react'
import type { AiosSession } from '../types/aios'
import { SessionCard } from '../components/sessions/SessionCard'
import { api } from '../services/api'

export function DashboardPage({ sessions, onRefresh }: { sessions: AiosSession[]; onRefresh: () => void }) {
  const [syncing, setSyncing] = useState(false)
  const [driftFixing, setDriftFixing] = useState(false)
  const [showDirtySummary, setShowDirtySummary] = useState(false)

  const running = sessions.filter((s) => s.state === 'running').length
  const idle = sessions.filter((s) => s.state === 'idle').length
  const stopped = sessions.filter((s) => s.state === 'stopped').length
  const active = sessions.filter((s) => s.state === 'running' && s.activity).length
  const local = sessions.filter((s) => s.type === 'local')
  const remote = sessions.filter((s) => s.type === 'remote')

  // Aggregate git stats
  const totalDirty = sessions.reduce((sum, s) => {
    if (s.gitDetail) return sum + s.gitDetail.modified + s.gitDetail.untracked
    return sum
  }, 0)
  const driftCount = sessions.filter(
    (s) => s.gitDetail && (s.gitDetail.syncStatus === 'behind' || s.gitDetail.syncStatus === 'diverged'),
  ).length
  const aheadCount = sessions.filter(
    (s) => s.gitDetail && s.gitDetail.syncStatus === 'ahead',
  ).length

  const handleSync = async () => {
    setSyncing(true)
    try {
      await api.actions.sync()
      setTimeout(onRefresh, 1500)
    } finally {
      setSyncing(false)
    }
  }

  const handleDriftFix = async () => {
    setDriftFixing(true)
    try {
      await api.actions.driftFix()
      setTimeout(onRefresh, 2000)
    } finally {
      setDriftFixing(false)
    }
  }

  const handleLaunchHomebase = () => {
    api.actions.launchHomebase().catch(() => {})
  }

  return (
    <div className="max-w-6xl">
      {/* Master Terminal + Stats row */}
      <div className="flex gap-4 mb-4">
        <button
          onClick={handleLaunchHomebase}
          className="bg-card border border-border rounded-lg px-4 py-3 flex items-center gap-3 hover:border-accent/50 transition-colors cursor-pointer"
          title="Open the master terminal (Terminal.app / Windows Terminal) — follows sidebar session clicks"
        >
          <TerminalSquare className="w-5 h-5 text-accent" />
          <div>
            <p className="text-sm font-bold text-accent">Master Terminal</p>
            <p className="text-[10px] text-muted">native window</p>
          </div>
        </button>
        {[
          { label: 'Active', value: active, color: 'text-accent', icon: Activity },
          { label: 'Running', value: running, color: 'text-success', icon: Zap },
          { label: 'Idle', value: idle, color: 'text-warning', icon: Monitor },
          { label: 'Stopped', value: stopped, color: 'text-gray-400', icon: Server },
        ].map(({ label, value, color, icon: Icon }) => (
          <div key={label} className="bg-card border border-border rounded-lg px-4 py-3 flex items-center gap-3">
            <Icon className={`w-5 h-5 ${color}`} />
            <div>
              <p className={`text-2xl font-bold ${color}`}>{value}</p>
              <p className="text-xs text-muted">{label}</p>
            </div>
          </div>
        ))}
      </div>

      {/* Git overview bar */}
      <div className="bg-card border border-border rounded-lg px-4 py-2.5 mb-6 flex items-center justify-between">
        <div className="flex items-center gap-5">
          <button
            onClick={() => totalDirty > 0 && setShowDirtySummary(!showDirtySummary)}
            className={`flex items-center gap-1.5 text-sm ${totalDirty > 0 ? 'cursor-pointer hover:opacity-80' : ''}`}
          >
            <GitBranch className="w-4 h-4 text-muted" />
            <span className={totalDirty > 0 ? 'text-warning font-medium' : 'text-success'}>
              {totalDirty} dirty
            </span>
            <span className="text-muted text-xs">across all sessions</span>
            {totalDirty > 0 && <span className="text-muted text-xs">{showDirtySummary ? '▴' : '▾'}</span>}
          </button>
          {driftCount > 0 && (
            <div className="flex items-center gap-1.5 text-sm">
              <AlertTriangle className="w-4 h-4" style={{ color: '#ef4444' }} />
              <span style={{ color: '#ef4444' }} className="font-medium">
                {driftCount} behind
              </span>
            </div>
          )}
          {aheadCount > 0 && (
            <div className="flex items-center gap-1.5 text-sm">
              <ArrowDownUp className="w-4 h-4" style={{ color: '#3b82f6' }} />
              <span style={{ color: '#3b82f6' }} className="font-medium">
                {aheadCount} unpushed
              </span>
            </div>
          )}
          {totalDirty === 0 && driftCount === 0 && aheadCount === 0 && (
            <span className="text-xs text-success">All clean & synced</span>
          )}
        </div>
        <div className="flex items-center gap-2">
          {driftCount > 0 && (
            <button
              onClick={handleDriftFix}
              disabled={driftFixing}
              className="flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium bg-warning/20 text-warning hover:bg-warning/30 disabled:opacity-50"
            >
              <ArrowDownUp className={`w-3 h-3 ${driftFixing ? 'animate-spin' : ''}`} />
              Fix Drift
            </button>
          )}
          <button
            onClick={handleSync}
            disabled={syncing}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded text-xs font-medium bg-accent/20 text-accent hover:bg-accent/30 disabled:opacity-50"
          >
            <RefreshCw className={`w-3 h-3 ${syncing ? 'animate-spin' : ''}`} />
            Sync All
          </button>
        </div>
      </div>

      {/* Dirty files summary (expandable) */}
      {showDirtySummary && totalDirty > 0 && (
        <div className="bg-card border border-border rounded-lg px-4 py-3 mb-6">
          {sessions
            .filter((s) => s.gitDetail && (s.gitDetail.modified > 0 || s.gitDetail.untracked > 0))
            .map((s) => (
              <div key={s.name} className="mb-2 last:mb-0">
                <div className="text-xs font-medium text-gray-300 mb-1">
                  {s.name}
                  <span className="text-muted ml-2">
                    {s.gitDetail!.modified}M {s.gitDetail!.untracked}U
                  </span>
                </div>
                {s.gitDetail!.dirtyFiles?.map((f, i) => {
                  const status = f.substring(0, 2).trim()
                  const name = f.substring(2).trimStart()
                  const isUntracked = status === '??'
                  return (
                    <div key={i} className="text-[10px] font-mono flex gap-1.5 pl-3 leading-relaxed">
                      <span style={{ color: isUntracked ? '#6b7280' : '#eab308' }} className="shrink-0 w-5">{status}</span>
                      <span className="text-gray-400 truncate">{name}</span>
                    </div>
                  )
                })}
              </div>
            ))}
        </div>
      )}

      {/* Local sessions */}
      {local.length > 0 && (
        <>
          <h2 className="text-sm font-semibold text-muted uppercase tracking-wider mb-3 flex items-center gap-2">
            <Monitor className="w-4 h-4" /> Local
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3 mb-6">
            {local.map((s) => (
              <SessionCard key={s.name} session={s} onRefresh={onRefresh} />
            ))}
          </div>
        </>
      )}

      {/* Remote sessions */}
      {remote.length > 0 && (
        <>
          <h2 className="text-sm font-semibold text-muted uppercase tracking-wider mb-3 flex items-center gap-2">
            <Server className="w-4 h-4" /> VPS
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
            {remote.map((s) => (
              <SessionCard key={s.name} session={s} onRefresh={onRefresh} />
            ))}
          </div>
        </>
      )}
    </div>
  )
}
