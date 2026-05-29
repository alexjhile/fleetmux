/**
 * AFK monitoring — surfaces sandcastle Docker runs from any aios session that
 * has adopted afk-workflow. Reads `<session-path>/.sandcastle/logs/*.log`
 * from sessions.json + streams them live to the GUI via WebSocket.
 *
 * REST:
 *   GET  /api/afk/sessions              — list sessions with .sandcastle/logs/
 *   GET  /api/afk/sessions/:name/logs   — list active log files for one session
 *   GET  /api/afk/sessions/:name/runs   — list running Docker containers for one session
 *
 * WebSocket:
 *   /ws/afk-log/:session/:logfile       — tail -f stream of a specific log
 *
 * Used by AfkWatchPage in the GUI.
 */
import { Server } from 'http'
import { WebSocket, WebSocketServer } from 'ws'
import { spawn } from 'child_process'
import { readFileSync, statSync, readdirSync, existsSync } from 'fs'
import path from 'path'

const AIOS_DIR = process.env.AIOS_DIR || path.resolve(import.meta.dirname, '..', '..')
const SESSIONS_FILE = path.join(AIOS_DIR, 'sessions.json')

interface SessionRecord {
  name: string
  path: string
  type: string
  description?: string
}

function readSessionsRaw(): SessionRecord[] {
  try {
    return JSON.parse(readFileSync(SESSIONS_FILE, 'utf-8'))
  } catch {
    return []
  }
}

function getSessionByName(name: string): SessionRecord | null {
  return readSessionsRaw().find((s) => s.name === name) ?? null
}

function logsDirFor(session: SessionRecord): string {
  return path.join(session.path, '.sandcastle', 'logs')
}

function isAfkAdopted(session: SessionRecord): boolean {
  return session.type === 'local' && existsSync(logsDirFor(session))
}

export interface AfkSessionSummary {
  name: string
  path: string
  description?: string
  logsDir: string
  totalLogs: number
  recentLogs: number  // modified within last hour
  lastModifiedMs: number | null
}

export function listAfkSessions(): AfkSessionSummary[] {
  const sessions = readSessionsRaw().filter(isAfkAdopted)
  const summaries: AfkSessionSummary[] = []
  const recentCutoff = Date.now() - 60 * 60 * 1000
  for (const s of sessions) {
    const logs = listLogFiles(s.name)
    if (logs.length === 0) continue
    const lastMs = logs[0]?.modifiedMs ?? null
    summaries.push({
      name: s.name,
      path: s.path,
      description: s.description,
      logsDir: logsDirFor(s),
      totalLogs: logs.length,
      recentLogs: logs.filter((l) => l.modifiedMs >= recentCutoff).length,
      lastModifiedMs: lastMs,
    })
  }
  summaries.sort((a, b) => (b.lastModifiedMs ?? 0) - (a.lastModifiedMs ?? 0))
  return summaries
}

export interface LogFileInfo {
  name: string             // basename, e.g. feat-phase3-stream10-hide-redeem-zero.log
  size: number             // bytes
  modifiedMs: number       // mtime
  isRecent: boolean        // modified in last 5 minutes (likely actively running)
}

export function listLogFiles(sessionName: string): LogFileInfo[] {
  const session = getSessionByName(sessionName)
  if (!session || !isAfkAdopted(session)) return []
  const dir = logsDirFor(session)
  const recentCutoff = Date.now() - 5 * 60 * 1000
  try {
    return readdirSync(dir)
      .filter((f) => f.endsWith('.log'))
      .map((name) => {
        const st = statSync(path.join(dir, name))
        const modifiedMs = st.mtimeMs
        return {
          name,
          size: st.size,
          modifiedMs,
          isRecent: modifiedMs >= recentCutoff,
        }
      })
      .sort((a, b) => b.modifiedMs - a.modifiedMs)
  } catch {
    return []
  }
}

export interface AfkRunInfo {
  container: string
  image: string
  status: string
  startedAt: string
}

export async function listAfkRuns(): Promise<AfkRunInfo[]> {
  return new Promise((resolve) => {
    const proc = spawn('docker', [
      'ps',
      '--format',
      '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.RunningFor}}',
    ])
    let buf = ''
    proc.stdout.on('data', (d) => (buf += d.toString()))
    proc.on('error', () => resolve([]))
    proc.on('close', () => {
      const runs: AfkRunInfo[] = []
      for (const line of buf.split('\n')) {
        if (!line.trim()) continue
        const [container, image, status, startedAt] = line.split('\t')
        if (!image || !image.startsWith('sandcastle:')) continue
        runs.push({ container, image, status, startedAt })
      }
      resolve(runs)
    })
  })
}

// --- WebSocket: live tail -f for a single log file ---

const SAFE_LOGNAME = /^[a-zA-Z0-9._-]+\.log$/

export function setupAfkWs(server: Server): WebSocketServer {
  const wss = new WebSocketServer({ noServer: true })

  server.on('upgrade', (req, socket, head) => {
    const m = req.url?.match(/^\/ws\/afk-log\/([a-zA-Z0-9_-]+)\/([a-zA-Z0-9._-]+)$/)
    if (!m) return  // Other handlers (terminal) can claim it
    const [, session, logfile] = m
    if (!SAFE_LOGNAME.test(logfile)) {
      socket.destroy()
      return
    }
    const sess = getSessionByName(session)
    if (!sess || !isAfkAdopted(sess)) {
      socket.destroy()
      return
    }
    const fullPath = path.join(logsDirFor(sess), logfile)
    if (!existsSync(fullPath)) {
      socket.destroy()
      return
    }
    wss.handleUpgrade(req, socket, head, (ws) => handleConnection(ws, fullPath))
  })

  return wss
}

function handleConnection(ws: WebSocket, fullPath: string) {
  // Send last 200 lines, then follow.
  const tail = spawn('tail', ['-n', '200', '-F', fullPath])

  const send = (data: Buffer | string) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(typeof data === 'string' ? data : data.toString('utf-8'))
    }
  }

  tail.stdout.on('data', send)
  tail.stderr.on('data', send)
  tail.on('error', () => {
    if (ws.readyState === WebSocket.OPEN) ws.close()
  })
  tail.on('close', () => {
    if (ws.readyState === WebSocket.OPEN) ws.close()
  })

  ws.on('close', () => {
    try { tail.kill('SIGTERM') } catch { /* noop */ }
  })
  ws.on('error', () => {
    try { tail.kill('SIGTERM') } catch { /* noop */ }
  })
}
