import express from 'express'
import cors from 'cors'
import path from 'path'
import { createServer } from 'http'
import { writeFileSync } from 'fs'
import { exec as execCb, execFile } from 'child_process'
import {
  readSessions,
  detectSessionInfo,
  getGitInfo,
  getGitDetail,
  getSessionUptime,
  backgroundGitFetch,
  readTasks,
  getLastTaskForSession,
  getCachedVpsHealth,
  captureLogs,
  startSession,
  stopSession,
  dispatchTask,
  sshCommand,
  getHealth,
  getCachedEnrichedSessions,
  refreshEnrichedSessions,
  getAccountsList,
  readUsageCache,
  readAccountsManifest,
  setSessionAccount,
  refreshUsage,
  readLimitsCache,
  refreshLimits,
  readModelGuardState,
  readModelGuardConfig,
  modelGuardToggle,
  modelGuardClear,
} from './aios.js'
import { setupTerminalWs } from './terminal.js'
import { setupAfkWs, listAfkSessions, listLogFiles, listAfkRuns } from './afk.js'
import { listDir, readFile as readFsFile, openInVscode, filesRoot } from './files.js'

const app = express()
const server = createServer(app)
const PORT = Number(process.env.PORT) || 9035
const TMUX_BIN = process.env.TMUX_BIN || 'tmux'

// WebSocket terminal handler
setupTerminalWs(server)

// WebSocket afk-log live tail handler
setupAfkWs(server)

app.use(cors())
app.use(express.json())

// Request logging
app.use((req, _res, next) => {
  if (req.path.startsWith('/api')) {
    console.log(`${new Date().toISOString()} ${req.method} ${req.path}`)
  }
  next()
})

// ── AFK monitoring ────────────────────────────────────────────────
// Sessions that have adopted afk-workflow (.sandcastle/logs/ exists)
// + live tail of their sandcastle Docker run logs.

app.get('/api/afk/sessions', (_req, res) => {
  res.json(listAfkSessions())
})

app.get('/api/afk/sessions/:name/logs', (req, res) => {
  res.json(listLogFiles(req.params.name))
})

app.get('/api/afk/runs', async (_req, res) => {
  res.json(await listAfkRuns())
})

// ── Filesystem explorer (~/Claude_Code/) ─────────────────────────

app.get('/api/fs/root', (_req, res) => {
  res.json({ root: filesRoot })
})

app.get('/api/fs/list', (req, res) => {
  const rel = (req.query.path as string) ?? ''
  res.json({ path: rel, entries: listDir(rel) })
})

app.get('/api/fs/read', (req, res) => {
  const rel = (req.query.path as string) ?? ''
  const file = readFsFile(rel)
  if (!file) return res.status(404).json({ error: 'not found or invalid path' })
  res.json(file)
})

app.post('/api/fs/open', (req, res) => {
  const rel = (req.body?.path as string) ?? ''
  const result = openInVscode(rel)
  if (!result.ok) return res.status(400).json(result)
  res.json(result)
})

// ── Sessions ──────────────────────────────────────────────────────

// Returns cached data instantly — background refresh runs every 3s
app.get('/api/sessions', (_req, res) => {
  res.json(getCachedEnrichedSessions())
})

app.get('/api/sessions/:name', (req, res) => {
  const sessions = readSessions()
  const s = sessions.find((s) => s.name === req.params.name)
  if (!s) return res.status(404).json({ error: 'Session not found' })

  const info = detectSessionInfo(s.name)
  const tasks = readTasks(s.name, 5)
  const lastTask = tasks.length > 0 ? tasks[0] : null
  const gitPath = s.type === 'local' ? s.path : s.local_path
  const gitDetail = gitPath ? getGitDetail(gitPath) : null
  res.json({
    ...s,
    state: info.state,
    activity: info.activity,
    gitInfo: s.type === 'local' ? getGitInfo(s.path) : (s.local_path ? getGitInfo(s.local_path) : undefined),
    gitDetail: gitDetail || undefined,
    uptime: info.state !== 'stopped' ? getSessionUptime(s.name) : undefined,
    lastTask: lastTask ? {
      task: lastTask.task as string,
      status: lastTask.status as string,
      dispatched_at: lastTask.dispatched_at as string,
      completed_at: lastTask.completed_at as string | undefined,
    } : undefined,
    vpsHealth: s.type === 'remote' ? getCachedVpsHealth(s.name) : undefined,
    recentTasks: tasks,
  })
})

app.post('/api/sessions/:name/start', async (req, res) => {
  try {
    await startSession(req.params.name)
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Failed to start' })
  }
})

app.post('/api/sessions/:name/stop', async (req, res) => {
  try {
    await stopSession(req.params.name)
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Failed to stop' })
  }
})

app.post('/api/sessions/:name/attach', (req, res) => {
  const { name } = req.params
  const socket = `/tmp/tmux-${process.getuid!()}/default`
  // Fire and forget — tmux select-window is instant, don't block on callback
  execFile(TMUX_BIN, ['-S', socket, 'select-window', '-t', `aios:${name}`])
  res.json({ ok: true })
})

// ── Tasks ─────────────────────────────────────────────────────────

app.get('/api/tasks', (req, res) => {
  const session = req.query.session as string | undefined
  const limit = parseInt(req.query.limit as string) || 50
  res.json(readTasks(session, limit))
})

app.post('/api/tasks/dispatch', async (req, res) => {
  const { session, task } = req.body
  if (!session || !task) return res.status(400).json({ error: 'session and task required' })
  try {
    const output = await dispatchTask(session, task)
    res.json({ ok: true, output })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Dispatch failed' })
  }
})

app.post('/api/tasks/ssh', async (req, res) => {
  const { session, command } = req.body
  if (!session || !command) return res.status(400).json({ error: 'session and command required' })
  try {
    const output = await sshCommand(session, command)
    res.json({ ok: true, output })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'SSH failed' })
  }
})

// ── Quick Actions ────────────────────────────────────────────────

app.post('/api/actions/sync', async (_req, res) => {
  try {
    const { aiosExec } = await import('./aios.js')
    const output = await aiosExec('sync')
    res.json({ ok: true, output })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Sync failed' })
  }
})

app.post('/api/actions/drift-fix', async (_req, res) => {
  try {
    const { aiosExec } = await import('./aios.js')
    const output = await aiosExec('drift --fix')
    res.json({ ok: true, output })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Drift fix failed' })
  }
})

// ── Launch Homebase Terminal ─────────────────────────────────────

app.post('/api/launch-homebase', (_req, res) => {
  try {
    const commandFile = process.env.FLEETMUX_LAUNCHER || path.resolve(import.meta.dirname, '..', '..', 'fleetmux.command')
    execCb(`open "${commandFile}"`)
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Failed to launch' })
  }
})

// ── Native Terminal Popout ────────────────────────────────────────

app.post('/api/sessions/:name/popout', (req, res) => {
  const { name } = req.params
  const sessions = readSessions()
  const session = sessions.find((s) => s.name === name)
  if (!session) return res.status(404).json({ error: 'Session not found' })

  const tmux = TMUX_BIN
  const socket = `/tmp/tmux-${process.getuid!()}/default`

  // Write a .command file — Terminal.app runs these natively in a new window
  const scriptPath = `/tmp/fleetmux-terminal-${name}.command`
  const script = [
    '#!/bin/zsh',
    `# fleetmux — ${name}`,
    `printf "\\e]0;fleetmux — ${name}\\a"`,  // set window title
    'clear',
    `exec ${tmux} -S "${socket}" new-session -t aios \\; select-window -t "${name}"`,
  ].join('\n')

  try {
    writeFileSync(scriptPath, script, { mode: 0o755 })
    execCb(`open "${scriptPath}"`)
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Failed to open terminal' })
  }
})

// ── Accounts ──────────────────────────────────────────────────────

app.get('/api/accounts', (_req, res) => {
  res.json(getAccountsList())
})

app.post('/api/sessions/:name/account', async (req, res) => {
  const account = (req.body?.account ?? '') as string
  try {
    await setSessionAccount(req.params.name, account)
    // Refresh enriched cache so frontend sees change immediately
    refreshEnrichedSessions().catch(() => {})
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Failed to set account' })
  }
})

// ── Usage ─────────────────────────────────────────────────────────

app.get('/api/usage', (_req, res) => {
  const cache = readUsageCache()
  if (!cache) return res.json({ refreshed_at: null, sessions: [] })
  res.json(cache)
})

app.post('/api/usage/refresh', async (_req, res) => {
  try {
    await refreshUsage()
    refreshEnrichedSessions().catch(() => {})
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Usage refresh failed' })
  }
})

// ── Subscription limits (live from Anthropic response headers) ───

app.get('/api/limits', (_req, res) => {
  const cache = readLimitsCache()
  if (!cache) return res.json({ refreshed_at: null, accounts: [] })
  res.json(cache)
})

app.post('/api/limits/refresh', async (_req, res) => {
  try {
    await refreshLimits()
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Limits refresh failed' })
  }
})

// ── Model Guard ─────────────────────────────────────────────────

app.get('/api/model-guard', (_req, res) => {
  res.json({
    config: readModelGuardConfig(),
    state: readModelGuardState(),
  })
})

app.post('/api/model-guard/toggle', async (req, res) => {
  const enable = req.body?.enabled !== false
  try {
    await modelGuardToggle(enable)
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Toggle failed' })
  }
})

app.post('/api/model-guard/clear', async (_req, res) => {
  try {
    await modelGuardClear()
    res.json({ ok: true })
  } catch (err: unknown) {
    res.status(500).json({ error: err instanceof Error ? err.message : 'Clear failed' })
  }
})

// ── Logs ──────────────────────────────────────────────────────────

app.get('/api/logs/:name', (req, res) => {
  const lines = parseInt(req.query.lines as string) || 80
  const content = captureLogs(req.params.name, lines)
  res.json({ content })
})

// ── Health ─────────────────────────────────────────────────────────

app.get('/api/health', async (_req, res) => {
  const sessions = readSessions()
  const force = _req.query.force === 'true'
  const health = await getHealth(sessions, force)
  res.json(health)
})

// ── Serve frontend (built files from dist/) ──────────────────────

const distPath = path.join(import.meta.dirname, '..', 'dist')
app.use(express.static(distPath))
app.get('*', (_req, res) => {
  res.sendFile(path.join(distPath, 'index.html'))
})

// ── Start ─────────────────────────────────────────────────────────

server.listen(PORT, () => {
  console.log(`AIOS GUI server running on http://localhost:${PORT}`)

  // Clean up orphaned grouped tmux sessions from previous server instances
  // These are aios-N sessions created by browser/popout terminals that weren't cleaned up
  try {
    const socket = `/tmp/tmux-${process.getuid!()}/default`
    execCb(
      `${TMUX_BIN} -S "${socket}" list-sessions -F "#{session_name} #{session_attached}" 2>/dev/null`,
      (err, stdout) => {
        if (err || !stdout) return
        const orphans = stdout.trim().split('\n')
          .filter((line) => /^aios-\d+ 0$/.test(line))
          .map((line) => line.split(' ')[0])
        for (const name of orphans) {
          console.log(`[startup] killing orphaned grouped session: ${name}`)
          execCb(`${TMUX_BIN} -S "${socket}" kill-session -t "${name}" 2>/dev/null`)
        }
      },
    )
  } catch { /* tmux not available */ }

  // Prime session cache immediately, then refresh every 3s (async, non-blocking)
  refreshEnrichedSessions().catch(() => {})
  setInterval(() => refreshEnrichedSessions().catch(() => {}), 3000)

  // Prime VPS health cache on startup (non-blocking) and refresh every 60s
  const sessions = readSessions()
  getHealth(sessions).catch(() => {})
  setInterval(() => {
    getHealth(readSessions(), true).catch(() => {})
  }, 60000)

  // Background usage refresh every 10 minutes (JSONL parsing is I/O heavy
  // but tokens_24h only shifts slowly, so 10min is plenty).
  refreshUsage().catch(() => {})
  setInterval(() => {
    refreshUsage().catch(() => {})
  }, 10 * 60 * 1000)

  // Background subscription-limits refresh every 5 minutes.
  // Probes each account via a Haiku API call (~9 tokens, ~$0.00005 each).
  refreshLimits().catch(() => {})
  setInterval(() => {
    refreshLimits().catch(() => {})
  }, 5 * 60 * 1000)
})
