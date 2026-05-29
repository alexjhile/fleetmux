import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Eye, Boxes, RefreshCw } from 'lucide-react'
import { api } from '../services/api'
import { LogStream } from '../components/afk/LogStream'

interface AfkSession {
  name: string
  path: string
  description?: string
  logsDir: string
  totalLogs: number
  recentLogs: number
  lastModifiedMs: number | null
}

interface LogFile {
  name: string
  size: number
  modifiedMs: number
  isRecent: boolean
}

interface AfkRun {
  container: string
  image: string
  status: string
  startedAt: string
}

function fmtAgo(ms: number | null): string {
  if (!ms) return '—'
  const sec = Math.max(0, Math.floor((Date.now() - ms) / 1000))
  if (sec < 60) return `${sec}s ago`
  if (sec < 3600) return `${Math.floor(sec / 60)}m ago`
  if (sec < 86400) return `${Math.floor(sec / 3600)}h ago`
  return `${Math.floor(sec / 86400)}d ago`
}

export function AfkWatchPage() {
  const [params, setParams] = useSearchParams()
  const [sessions, setSessions] = useState<AfkSession[]>([])
  const [logs, setLogs] = useState<LogFile[]>([])
  const [runs, setRuns] = useState<AfkRun[]>([])
  const [zoomed, setZoomed] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  const selected = params.get('session') || ''

  const refresh = async () => {
    setLoading(true)
    try {
      const [s, r] = await Promise.all([api.afk.sessions(), api.afk.runs()])
      setSessions(s)
      setRuns(r)
      // Auto-select first session if none chosen
      if (!selected && s.length > 0) {
        setParams({ session: s[0].name }, { replace: true })
      }
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    refresh()
    const t = setInterval(refresh, 5000)
    return () => clearInterval(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (!selected) {
      setLogs([])
      return
    }
    let cancelled = false
    const tick = async () => {
      try {
        const l = await api.afk.logs(selected)
        if (!cancelled) setLogs(l)
      } catch { /* noop */ }
    }
    tick()
    const t = setInterval(tick, 3000)
    return () => { cancelled = true; clearInterval(t) }
  }, [selected])

  const selectedSession = sessions.find((s) => s.name === selected)
  const matchingRuns = selectedSession
    ? runs.filter((r) => r.image === `sandcastle:${selectedSession.name}`)
    : []

  const recentLogs = logs.filter((l) => l.isRecent)
  const olderLogs = logs.filter((l) => !l.isRecent)

  if (loading && sessions.length === 0) {
    return <div className="text-muted text-sm">Loading AFK sessions…</div>
  }

  if (sessions.length === 0) {
    return (
      <div className="max-w-2xl">
        <div className="flex items-center gap-2 mb-2">
          <Eye className="w-5 h-5 text-accent" />
          <h1 className="text-xl font-bold">AFK Monitoring</h1>
        </div>
        <p className="text-muted text-sm mb-4">
          No sessions have an autonomous run harness yet. To enable AFK monitoring on a project:
        </p>
        <pre className="text-xs bg-card border border-border rounded p-3 font-mono text-gray-300 overflow-auto">
          {`# In the project's repo root, add an autonomous run harness under
# .sandcastle/ that writes logs to .sandcastle/logs/.
# Once those logs exist, this page will auto-discover the session.`}
        </pre>
      </div>
    )
  }

  return (
    <div className="space-y-3 h-full flex flex-col">
      {/* Header */}
      <div className="flex items-center gap-2">
        <Eye className="w-5 h-5 text-accent" />
        <h1 className="text-xl font-bold">AFK Monitoring</h1>
        <button
          onClick={refresh}
          className="ml-auto p-1.5 rounded hover:bg-white/10 text-muted hover:text-white transition-colors"
          title="Refresh"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
        </button>
      </div>

      {/* Session selector */}
      <div className="flex flex-wrap gap-2 items-center text-sm">
        <span className="text-muted text-xs uppercase tracking-wider">Project:</span>
        {sessions.map((s) => (
          <button
            key={s.name}
            onClick={() => { setParams({ session: s.name }); setZoomed(null) }}
            className={`flex items-center gap-1.5 px-2.5 py-1 rounded text-xs ${
              selected === s.name
                ? 'bg-accent/20 text-accent border border-accent/40'
                : 'bg-card text-muted hover:text-white border border-border hover:bg-white/5'
            }`}
            title={s.description || s.path}
          >
            <span className="font-medium">{s.name}</span>
            <span className="text-[10px] opacity-60">
              {s.recentLogs > 0 ? `${s.recentLogs} live` : `${s.totalLogs} log${s.totalLogs === 1 ? '' : 's'}`}
            </span>
            {s.recentLogs > 0 ? (
              <span className="w-1.5 h-1.5 rounded-full bg-success animate-pulse-dot" />
            ) : null}
          </button>
        ))}
      </div>

      {/* Containers strip */}
      {matchingRuns.length > 0 ? (
        <div className="flex flex-wrap gap-2 items-center text-xs bg-card border border-border rounded px-3 py-2">
          <Boxes className="w-3.5 h-3.5 text-accent" />
          <span className="text-muted">{matchingRuns.length} sandbox{matchingRuns.length === 1 ? '' : 'es'} running:</span>
          {matchingRuns.map((r) => (
            <span key={r.container} className="font-mono text-[10px] text-gray-300 bg-black/30 px-2 py-0.5 rounded">
              {r.container.slice(0, 24)} · {r.startedAt}
            </span>
          ))}
        </div>
      ) : null}

      {/* Logs grid */}
      <div className="flex-1 overflow-auto">
        {logs.length === 0 ? (
          <div className="text-muted text-sm py-8 text-center">No log files yet for this session.</div>
        ) : zoomed ? (
          <div className="h-[calc(100vh-220px)]">
            <LogStream
              key={zoomed}
              sessionName={selected}
              logFile={zoomed}
              isRecent={logs.find((l) => l.name === zoomed)?.isRecent ?? false}
              isZoomed
              onZoom={() => setZoomed(null)}
            />
          </div>
        ) : (
          <>
            {recentLogs.length > 0 ? (
              <>
                <h2 className="text-xs uppercase tracking-wider text-success mb-2">
                  Live ({recentLogs.length})
                </h2>
                <div className="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-3 mb-6">
                  {recentLogs.map((l) => (
                    <LogStream
                      key={l.name}
                      sessionName={selected}
                      logFile={l.name}
                      isRecent
                      onZoom={() => setZoomed(l.name)}
                    />
                  ))}
                </div>
              </>
            ) : null}
            {olderLogs.length > 0 ? (
              <>
                <h2 className="text-xs uppercase tracking-wider text-muted mb-2">
                  Recent ({olderLogs.length}) — click to view
                </h2>
                <div className="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-4 gap-2">
                  {olderLogs.map((l) => (
                    <button
                      key={l.name}
                      onClick={() => setZoomed(l.name)}
                      className="text-left p-2 bg-card border border-border rounded hover:bg-white/5 hover:border-accent/40 transition-colors"
                    >
                      <div className="font-mono text-[10px] text-gray-300 truncate" title={l.name}>
                        {l.name.replace(/^feat-/, '').replace(/\.log$/, '')}
                      </div>
                      <div className="text-[10px] text-muted mt-0.5">
                        {fmtAgo(l.modifiedMs)} · {(l.size / 1024).toFixed(1)}KB
                      </div>
                    </button>
                  ))}
                </div>
              </>
            ) : null}
          </>
        )}
      </div>
    </div>
  )
}
