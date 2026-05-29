import type { AiosSession, AiosTask, HealthData, AccountInfo, UsageCache, LimitsCache } from '../types/aios'

// In Tauri or production build, use absolute URL to the Express backend
// In Vite dev, the proxy handles /api -> localhost:9035
const isTauri = !!(window as Record<string, unknown>).__TAURI_INTERNALS__
const BASE = isTauri ? 'http://localhost:9035/api' : '/api'

async function get<T>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`)
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json()
}

async function post<T>(path: string, body?: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json()
}

export const api = {
  sessions: {
    list: () => get<AiosSession[]>('/sessions'),
    get: (name: string) => get<AiosSession & { recentTasks: AiosTask[] }>(`/sessions/${name}`),
    start: (name: string) => post<{ ok: boolean }>(`/sessions/${name}/start`),
    stop: (name: string) => post<{ ok: boolean }>(`/sessions/${name}/stop`),
    popout: (name: string) => post<{ ok: boolean }>(`/sessions/${name}/popout`),
    attach: (name: string) => post<{ ok: boolean }>(`/sessions/${name}/attach`),
  },
  tasks: {
    list: (session?: string, limit = 50) =>
      get<AiosTask[]>(`/tasks?${session ? `session=${session}&` : ''}limit=${limit}`),
    dispatch: (session: string, task: string) =>
      post<{ ok: boolean; output: string }>('/tasks/dispatch', { session, task }),
    ssh: (session: string, command: string) =>
      post<{ ok: boolean; output: string }>('/tasks/ssh', { session, command }),
  },
  logs: {
    get: (name: string, lines = 80) => get<{ content: string }>(`/logs/${name}?lines=${lines}`),
  },
  health: {
    get: (force = false) => get<HealthData>(`/health${force ? '?force=true' : ''}`),
  },
  actions: {
    sync: () => post<{ ok: boolean; output: string }>('/actions/sync'),
    driftFix: () => post<{ ok: boolean; output: string }>('/actions/drift-fix'),
    launchHomebase: () => post<{ ok: boolean }>('/launch-homebase'),
  },
  accounts: {
    list: () => get<AccountInfo[]>('/accounts'),
    setForSession: (session: string, account: string) =>
      post<{ ok: boolean }>(`/sessions/${session}/account`, { account }),
  },
  usage: {
    get: () => get<UsageCache>('/usage'),
    refresh: () => post<{ ok: boolean }>('/usage/refresh'),
  },
  limits: {
    get: () => get<LimitsCache>('/limits'),
    refresh: () => post<{ ok: boolean }>('/limits/refresh'),
  },
  fs: {
    root: () => get<{ root: string }>('/fs/root'),
    list: (relPath: string) =>
      get<{ path: string; entries: Array<{ name: string; type: 'dir' | 'file' | 'symlink' | 'other'; size?: number; modifiedMs?: number; isHidden: boolean }> }>(
        `/fs/list?path=${encodeURIComponent(relPath)}`,
      ),
    read: (relPath: string) =>
      get<{ path: string; size: number; truncated: boolean; encoding: 'utf-8' | 'binary'; content: string; language?: string }>(
        `/fs/read?path=${encodeURIComponent(relPath)}`,
      ),
    open: (relPath: string) => post<{ ok: boolean }>('/fs/open', { path: relPath }),
  },
  afk: {
    sessions: () =>
      get<Array<{
        name: string
        path: string
        description?: string
        logsDir: string
        totalLogs: number
        recentLogs: number
        lastModifiedMs: number | null
      }>>('/afk/sessions'),
    logs: (sessionName: string) =>
      get<Array<{ name: string; size: number; modifiedMs: number; isRecent: boolean }>>(
        `/afk/sessions/${sessionName}/logs`,
      ),
    runs: () =>
      get<Array<{ container: string; image: string; status: string; startedAt: string }>>(
        '/afk/runs',
      ),
  },
}
