import { useState, useCallback } from 'react'
import { useParams, Link } from 'react-router-dom'
import { ArrowLeft, Play, Square, Server, Monitor } from 'lucide-react'
import { api } from '../services/api'
import { usePolling } from '../hooks/usePolling'
import { TerminalView } from '../components/terminal/TerminalView'
import type { FleetmuxTask } from '../types/fleetmux'

const stateStyles: Record<string, string> = {
  running: 'bg-success/20 text-success',
  idle: 'bg-warning/20 text-warning',
  stopped: 'bg-gray-500/20 text-gray-400',
}

export function SessionPage() {
  const { name } = useParams<{ name: string }>()

  const fetchSession = useCallback(() => api.sessions.get(name!), [name])
  const fetchTasks = useCallback(() => api.tasks.list(name, 10), [name])
  const { data: session, refresh } = usePolling(fetchSession, 3000)
  const { data: tasks } = usePolling(fetchTasks, 5000)

  const [actionError, setActionError] = useState<string | null>(null)

  if (!session) return <div className="text-muted">Loading...</div>

  const handleStartStop = async () => {
    setActionError(null)
    try {
      if (session.state === 'stopped') await api.sessions.start(name!)
      else await api.sessions.stop(name!)
      setTimeout(refresh, 1000)
    } catch (err) {
      setActionError(err instanceof Error ? err.message : 'Action failed')
    }
  }

  const isActive = session.state !== 'stopped'

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="flex items-center gap-3 mb-3 shrink-0">
        <Link to="/" className="text-muted hover:text-white">
          <ArrowLeft className="w-5 h-5" />
        </Link>
        {session.type === 'remote' ? (
          <Server className="w-5 h-5 text-purple-400" />
        ) : (
          <Monitor className="w-5 h-5 text-cyan-400" />
        )}
        <h1 className="text-xl font-bold">{name}</h1>
        <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${stateStyles[session.state] || ''}`}>
          {session.state}
        </span>
        {session.activity && (
          <span className="text-xs font-medium animate-pulse-dot" style={{ color: '#22c55e' }}>
            {session.activity}...
          </span>
        )}
        {session.state === 'idle' && (
          <span className="text-xs font-medium" style={{ color: '#eab308' }}>
            <span className="animate-blink">▍</span> Ready
          </span>
        )}
        <span className="text-sm text-muted hidden sm:inline">{session.description}</span>
        <button
          onClick={handleStartStop}
          className={`ml-auto flex items-center gap-1 px-3 py-1.5 rounded text-xs font-medium ${
            session.state === 'stopped'
              ? 'bg-success/20 text-success hover:bg-success/30'
              : 'bg-danger/20 text-danger hover:bg-danger/30'
          }`}
        >
          {session.state === 'stopped' ? <Play className="w-3 h-3" /> : <Square className="w-3 h-3" />}
          {session.state === 'stopped' ? 'Start' : 'Stop'}
        </button>
        {actionError && (
          <span className="text-xs text-danger ml-3">{actionError}</span>
        )}
      </div>

      {/* Terminal or Start prompt */}
      {isActive ? (
        <div className="flex-1 min-h-0">
          <TerminalView sessionName={name!} />
        </div>
      ) : (
        <div className="flex-1 flex items-center justify-center">
          <div className="text-center">
            <p className="text-muted mb-4">Session is stopped</p>
            <button
              onClick={handleStartStop}
              className="flex items-center gap-2 px-6 py-3 rounded-lg bg-success/20 text-success hover:bg-success/30 text-sm font-medium mx-auto"
            >
              <Play className="w-4 h-4" />
              Start Session
            </button>
          </div>
        </div>
      )}

      {/* Recent tasks - collapsed below terminal */}
      {tasks && tasks.length > 0 && (
        <div className="mt-3 shrink-0">
          <details>
            <summary className="text-xs font-semibold text-muted uppercase tracking-wider cursor-pointer hover:text-gray-300">
              Recent Tasks ({tasks.length})
            </summary>
            <div className="bg-card border border-border rounded-lg divide-y divide-border mt-2 max-h-40 overflow-y-auto">
              {(tasks as FleetmuxTask[]).map((t) => (
                <div key={t.id} className="px-4 py-2 flex items-center gap-3">
                  <span
                    className={`w-2 h-2 rounded-full shrink-0 ${
                      t.status === 'completed' ? 'bg-success' : t.status === 'failed' ? 'bg-danger' : 'bg-warning'
                    }`}
                  />
                  <span className="text-sm text-gray-300 truncate flex-1">{t.task}</span>
                  <span className="text-xs text-muted">{t.mode}</span>
                  {t.duration_s && <span className="text-xs text-muted">{t.duration_s}s</span>}
                </div>
              ))}
            </div>
          </details>
        </div>
      )}
    </div>
  )
}
