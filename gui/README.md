# fleetmux-gui

Web + desktop dashboard for [fleetmux](../README.md) — real-time session status, terminal access, task dispatch, token-usage visibility, and remote-host health, all in the browser (or as a Tauri desktop app).

It's an optional companion to the `fleetmux` CLI: the CLI is the engine, this is a window onto it.

```
   browser / desktop app  ──HTTP+WebSocket──▶  Express server  ──shells out──▶  fleetmux CLI
        (React UI)                              (port 9035)                      (tmux + ssh)
```

> **Verified** — frontend builds (`vite build` ✓), server typechecks (`tsc --noEmit` ✓), and the server test suite passes (33/33 vitest). Re-run any time with the commands below.

## Stack

- **Frontend**: React 19 + Vite + Tailwind + xterm.js
- **Backend**: Express + node-pty (WebSocket terminal multiplexer)
- **Desktop**: Tauri v2 (optional)

## Prerequisites

The GUI drives the `fleetmux` CLI, so it expects the CLI repo alongside it. By default it resolves the repo root two levels up (`gui/server` → repo root) and looks for `fleetmux` + `sessions.json` there. Override with env vars if your layout differs:

| Variable | Default | Purpose |
|---|---|---|
| `AIOS_DIR` | repo root (`../..`) | Where `sessions.json` / `tasks.json` / caches live |
| `AIOS_CLI` | `$AIOS_DIR/fleetmux` | Path to the CLI binary |
| `PORT` | `9035` | Server port (serves API + built frontend + WebSocket) |
| `TMUX_BIN` | `tmux` | tmux binary (set if not on PATH) |
| `FS_ROOT` | `$AIOS_CLAUDE_CODE_ROOT` or `$HOME` | Root for the file browser |

## Develop

```bash
cd gui
npm install
cd server && npm install && cd ..
npm run dev          # Vite on :9036 + Express on :9035 (concurrently)
```

## Build

```bash
npm run build        # frontend → dist/ (served by the Express server in production)
npm run tauri:build  # optional: macOS desktop app
```

## Tests

```bash
cd server && npm install && npm test   # vitest
```

## Layout

- `server/` — Express API, WebSocket terminals (`terminal.ts`), CLI integration (`aios.ts`), AFK log streaming (`afk.ts`), file browser (`files.ts`)
- `src/` — React app (pages, components, hooks, typed API client)
- `src-tauri/` — Tauri v2 desktop wrapper

> Internal env vars keep the `AIOS_` prefix for parity with the CLI (fleetmux began as a personal tool called "AIOS"). They're functionally irrelevant to users.
