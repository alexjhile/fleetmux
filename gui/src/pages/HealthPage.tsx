import { useCallback, useState } from 'react'
import { RefreshCw, Server, Monitor } from 'lucide-react'
import { api } from '../services/api'
import { usePolling } from '../hooks/usePolling'
import type { HealthData } from '../types/aios'

export function HealthPage() {
  const [refreshing, setRefreshing] = useState(false)
  const fetchHealth = useCallback(() => api.health.get(), [])
  const { data: health, refresh } = usePolling(fetchHealth, 30000)

  const handleForceRefresh = async () => {
    setRefreshing(true)
    try {
      await api.health.get(true)
      refresh()
    } finally {
      setRefreshing(false)
    }
  }

  return (
    <div className="max-w-5xl">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-xl font-bold">System Health</h1>
        <button
          onClick={handleForceRefresh}
          disabled={refreshing}
          className="flex items-center gap-2 px-3 py-1.5 rounded bg-accent/20 text-accent text-sm hover:bg-accent/30 disabled:opacity-50"
        >
          <RefreshCw className={`w-4 h-4 ${refreshing ? 'animate-spin' : ''}`} />
          Refresh
        </button>
      </div>

      {health && <HealthTables health={health} />}
      {!health && <p className="text-muted">Loading health data...</p>}
    </div>
  )
}

function HealthTables({ health }: { health: HealthData }) {
  return (
    <div className="space-y-6">
      {/* VPS */}
      <div>
        <h2 className="text-sm font-semibold text-muted uppercase tracking-wider mb-3 flex items-center gap-2">
          <Server className="w-4 h-4" /> VPS Servers
        </h2>
        <div className="bg-card border border-border rounded-lg overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border text-left text-xs text-muted uppercase">
                <th className="px-4 py-2">Name</th>
                <th className="px-4 py-2">Host</th>
                <th className="px-4 py-2">Status</th>
                <th className="px-4 py-2">Uptime</th>
                <th className="px-4 py-2">Disk</th>
                <th className="px-4 py-2">Memory</th>
                <th className="px-4 py-2">PM2</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {health.vps.map((v) => (
                <tr key={v.name} className="hover:bg-white/5">
                  <td className="px-4 py-2 font-medium text-gray-300">{v.name}</td>
                  <td className="px-4 py-2 text-muted">{v.host}</td>
                  <td className="px-4 py-2">
                    <span className={`inline-block w-2 h-2 rounded-full mr-1 ${v.status === 'ok' ? 'bg-success' : 'bg-danger'}`} />
                    <span className={v.status === 'ok' ? 'text-success' : 'text-danger'}>{v.status}</span>
                  </td>
                  <td className="px-4 py-2 text-muted">{v.uptime || '-'}</td>
                  <td className="px-4 py-2 text-muted">{v.disk || '-'}</td>
                  <td className="px-4 py-2 text-muted">{v.memory || '-'}</td>
                  <td className="px-4 py-2 text-muted">{v.pm2 || '-'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Local */}
      <div>
        <h2 className="text-sm font-semibold text-muted uppercase tracking-wider mb-3 flex items-center gap-2">
          <Monitor className="w-4 h-4" /> Local Projects
        </h2>
        <div className="bg-card border border-border rounded-lg overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-border text-left text-xs text-muted uppercase">
                <th className="px-4 py-2">Name</th>
                <th className="px-4 py-2">Branch</th>
                <th className="px-4 py-2">Dirty Files</th>
                <th className="px-4 py-2">Status</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              {health.local.map((l) => (
                <tr key={l.name} className="hover:bg-white/5">
                  <td className="px-4 py-2 font-medium text-gray-300">{l.name}</td>
                  <td className="px-4 py-2 text-muted">{l.branch}</td>
                  <td className="px-4 py-2">
                    <span className={l.dirty > 0 ? 'text-warning' : 'text-muted'}>{l.dirty}</span>
                  </td>
                  <td className="px-4 py-2">
                    <span className={l.status === 'ok' ? 'text-success' : 'text-danger'}>{l.status}</span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}
