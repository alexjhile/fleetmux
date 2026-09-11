import { WebSocketServer, WebSocket } from 'ws'
import { Server } from 'http'
import * as pty from 'node-pty'
import { execSync } from 'child_process'
import { readFileSync } from 'fs'
import path from 'path'

const activePtys = new Map<WebSocket, pty.IPty>()
const TMUX_SOCKET = `/tmp/tmux-${process.getuid!()}/default`
// tmux binary + login shell are configurable so this works beyond macOS/Homebrew.
const TMUX_BIN = process.env.TMUX_BIN || 'tmux'
const SHELL_BIN = process.env.SHELL || '/bin/bash'
const PTY_ENV = {
  ...process.env,
  TERM: 'xterm-256color',
  PATH: `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${process.env.PATH || ''}`,
  TMUX_TMPDIR: `/tmp/tmux-${process.getuid!()}`,
} as Record<string, string>

export function setupTerminalWs(server: Server) {
  const wss = new WebSocketServer({ noServer: true })

  server.on('upgrade', (req, socket, head) => {
    const match = req.url?.match(/^\/ws\/terminal\/([a-zA-Z0-9_-]+)$/)
    if (!match) return  // Let other handlers (afk-log) claim it
    wss.handleUpgrade(req, socket, head, (ws) => {
      handleConnection(ws, match[1])
    })
  })

  return wss
}

// Look up a session's path from sessions.json
function getSessionPath(sessionName: string): string | null {
  try {
    const fleetmuxDir = process.env.FLEETMUX_DIR || path.resolve(import.meta.dirname, '..', '..')
    const raw = readFileSync(path.join(fleetmuxDir, 'sessions.json'), 'utf-8')
    const sessions = JSON.parse(raw) as Array<{ name: string; path: string; type: string }>
    const session = sessions.find((s) => s.name === sessionName)
    return session?.path || null
  } catch {
    return null
  }
}

// Ensure tmux window exists for a session, creating it if needed
function ensureTmuxWindow(sessionName: string): void {
  try {
    // Check if window already exists
    execSync(
      `${TMUX_BIN} -S "${TMUX_SOCKET}" list-windows -t fleetmux -F "#{window_name}" 2>/dev/null | grep -qx "${sessionName}"`,
      { env: PTY_ENV },
    )
  } catch {
    // Window doesn't exist — create it
    const sessionPath = getSessionPath(sessionName)
    const cwd = sessionPath || process.env.HOME || '/tmp'
    console.log(`[terminal] creating tmux window '${sessionName}' at ${cwd}`)
    try {
      execSync(
        `${TMUX_BIN} -S "${TMUX_SOCKET}" new-window -t fleetmux -n "${sessionName}" -c "${cwd}" ${SHELL_BIN}`,
        { env: PTY_ENV },
      )
    } catch (e) {
      console.error(`[terminal] failed to create window: ${e}`)
    }
  }
}

function handleConnection(ws: WebSocket, sessionName: string) {
  console.log(`[terminal] connecting to session: ${sessionName}`)

  // Auto-create tmux window if it doesn't exist
  ensureTmuxWindow(sessionName)

  // Send tmux scrollback history before attaching (so user can scroll up)
  try {
    const history = execSync(
      `${TMUX_BIN} -S "${TMUX_SOCKET}" capture-pane -t "fleetmux:${sessionName}" -p -S -5000 2>/dev/null`,
      { env: PTY_ENV, maxBuffer: 10 * 1024 * 1024, encoding: 'utf-8' },
    )
    if (history && ws.readyState === WebSocket.OPEN) {
      // Send history with newlines converted to \r\n for xterm
      ws.send(history.replace(/\n/g, '\r\n'))
      ws.send('\r\n\x1b[90m--- live session below ---\x1b[0m\r\n\r\n')
    }
  } catch {
    // Session may not exist yet or capture failed — continue without history
  }

  // Use new-session -t (grouped session) instead of attach-session
  // attach-session resizes ALL windows to the smallest client, which can crash
  // running Claude Code sessions. Grouped sessions have independent sizing.
  // destroy-unattached (set on the new grouped session only) makes tmux drop
  // it when this client goes away, instead of leaving fleetmux-N sessions behind.
  const ptyProcess = pty.spawn(SHELL_BIN, [
    '-c',
    `exec ${TMUX_BIN} -S "${TMUX_SOCKET}" new-session -t fleetmux \\; set-option destroy-unattached on \\; select-window -t "${sessionName}"`,
  ], {
    name: 'xterm-256color',
    cols: 80,
    rows: 24,
    cwd: process.env.HOME || '/tmp',
    env: PTY_ENV,
  })

  activePtys.set(ws, ptyProcess)

  // PTY stdout → WebSocket
  // Strip mouse tracking escape sequences so xterm.js handles scroll/click/select locally
  // Without this, tmux mouse mode hijacks wheel (no scroll), click (jumps to bottom),
  // and selection (broken copy). Stripping lets xterm.js handle all mouse interactions natively.
  const MOUSE_MODE_RE = /\x1b\[\?(1000|1002|1003|1006|1015)[hl]/g
  ptyProcess.onData((data) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(data.replace(MOUSE_MODE_RE, ''))
    }
  })

  // WebSocket → PTY stdin
  ws.on('message', (msg) => {
    const str = msg.toString()
    // Check for control messages (resize)
    try {
      const parsed = JSON.parse(str)
      if (parsed.type === 'resize' && parsed.cols && parsed.rows) {
        ptyProcess.resize(
          Math.max(1, Math.min(parsed.cols, 500)),
          Math.max(1, Math.min(parsed.rows, 200)),
        )
        return
      }
    } catch {
      // Not JSON — treat as terminal input
    }
    ptyProcess.write(str)
  })

  // Cleanup on WebSocket close
  ws.on('close', () => {
    console.log(`[terminal] disconnected from session: ${sessionName}`)
    activePtys.delete(ws)
    ptyProcess.kill()
  })

  // Cleanup on PTY exit (tmux detached or session ended)
  ptyProcess.onExit(({ exitCode }) => {
    console.log(`[terminal] PTY exited for ${sessionName} (code ${exitCode})`)
    activePtys.delete(ws)
    if (ws.readyState === WebSocket.OPEN) {
      ws.close()
    }
  })
}
