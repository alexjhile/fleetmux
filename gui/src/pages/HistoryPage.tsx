import { useState, useCallback } from 'react'
import { api } from '../services/api'
import { usePolling } from '../hooks/usePolling'
import type { FleetmuxTask } from '../types/fleetmux'

const statusColors = {
  completed: 'bg-success',
  failed: 'bg-danger',
  dispatched: 'bg-warning',
}

export function HistoryPage() {
  const [filter, setFilter] = useState('')
  const fetchTasks = useCallback(() => api.tasks.list(filter || undefined, 100), [filter])
  const { data: tasks } = usePolling(fetchTasks, 5000)

  return (
    <div className="max-w-5xl">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-xl font-bold">Task History</h1>
        <select
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          className="bg-card border border-border rounded px-3 py-1.5 text-sm text-white focus:outline-none focus:border-accent"
        >
          <option value="">All sessions</option>
          {[...new Set((tasks || []).map((t: FleetmuxTask) => t.session))].map((s) => (
            <option key={s} value={s}>{s}</option>
          ))}
        </select>
      </div>

      <div className="bg-card border border-border rounded-lg overflow-hidden">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border text-left text-xs text-muted uppercase">
              <th className="px-4 py-2">Status</th>
              <th className="px-4 py-2">Session</th>
              <th className="px-4 py-2">Task</th>
              <th className="px-4 py-2">Mode</th>
              <th className="px-4 py-2">Duration</th>
              <th className="px-4 py-2">Time</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {(tasks || []).map((t: FleetmuxTask) => (
              <tr key={t.id} className="hover:bg-white/5">
                <td className="px-4 py-2">
                  <span className={`inline-block w-2 h-2 rounded-full ${statusColors[t.status] || 'bg-gray-500'}`} />
                </td>
                <td className="px-4 py-2 text-gray-300">{t.session}</td>
                <td className="px-4 py-2 text-gray-300 max-w-md truncate">{t.task}</td>
                <td className="px-4 py-2 text-muted">{t.mode}</td>
                <td className="px-4 py-2 text-muted">{t.duration_s ? `${t.duration_s}s` : '-'}</td>
                <td className="px-4 py-2 text-muted whitespace-nowrap">
                  {t.dispatched_at ? new Date(t.dispatched_at).toLocaleString() : '-'}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        {(!tasks || tasks.length === 0) && (
          <p className="text-center text-muted py-8">No tasks yet</p>
        )}
      </div>
    </div>
  )
}
