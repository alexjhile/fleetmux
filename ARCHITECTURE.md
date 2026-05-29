# Architecture

fleetmux is a thin orchestration layer over `tmux`, `ssh`, `git`, and `jq`. There is no daemon and no database — state is plain JSON files in the repo dir, and every session is just a `tmux` window (local) or a `tmux` session on a remote host reached over SSH.

## Components

```
fleetmux                 entry point — arg parsing + command dispatch
lib/
  config.sh              constants, paths, env loading, file locking, task recording
  registry.sh            read/write sessions.json
  session.sh             start/stop/attach via tmux (local) or ssh→tmux (remote)
  dispatch.sh            run / run --wait / exec — send tasks into a session
  ssh.sh                 direct shell command + interactive shell on remote hosts
  status.sh / display.sh session-state detection + table rendering
  watch.sh / dashboard.sh  live dashboard + tmux popup/keybindings
  health.sh              remote disk/mem/uptime + local git status
  alerts.sh              stuck-task / resource-warning detection
  context.sh / conversation.sh  read a session's Claude memory, git, task history, chat
  sync.sh                detect direct work since last run + trigger brain backup
  brain.sh               snapshot all sessions' Claude memory into brain/ and commit
  drift.sh               compare local vs remote vs origin, optionally reconcile
  account.sh             multi-account OAuth token CRUD + deploy
  usage.sh / limits.sh   per-session token burn + live subscription limits
  model-guard.sh         auto Opus→Sonnet under limit pressure
  working-check.sh       WORKING.md freshness checks
  afk.sh                 overnight queue drain (wraps an autonomous run harness)
bin/
  aios-claude            launch wrapper: reads $AIOS_ACCOUNT, exports the OAuth token, execs claude
  aios-usage-parser      aggregates ~/.claude/projects/*/*.jsonl into per-session usage
  aios-limits-probe      minimal API call that reads rate-limit response headers
```

## Data flow

```
                sessions.json  ──read──▶  registry.sh  ──▶  every command
                                                │
  fleetmux start <name> ───────────────────────┤
        │ local:  tmux new-window → cd path → ~/.aios-claude <flags>
        │ remote: tmux new-window → ssh -t host → tmux (on host) → wrapper <flags>
        ▼
  fleetmux run/exec <name> "task"  ──tmux send-keys / claude -p──▶  the session
        │
        └─▶ record_task() ──append──▶ tasks.json   (capped, file-locked)

  fleetmux sync ──▶ detect direct work ──▶ brain.sh ──snapshot──▶ brain/ ──git commit──▶ remote
```

## State files (all gitignored)

| File | Contents |
|---|---|
| `sessions.json` | the session registry (you edit this) |
| `tasks.json` | append-only dispatch history, capped, file-locked |
| `brain/` | snapshots of each session's Claude Code memory |
| `usage-cache.json` / `limits-cache.json` | cached token-burn + subscription limits |
| `model-guard-state.json` | active model overrides |
| `logs/`, `.aios/` | per-command logs and AFK run sidecars/locks |

## Design principles

- **No daemon.** Every command is a short-lived process. Persistence is tmux + JSON files.
- **Shortest path.** Local work uses direct tmux/filesystem; remote work uses `ssh`; a full remote Claude session is launched only when a task genuinely needs one.
- **Bash 3.2 compatible.** macOS ships bash 3.2; the code avoids `mapfile`, `wait -n`, and unguarded empty-array expansion (`"${arr[@]+...}"` idiom throughout).
- **Atomic writes.** Task-history writes take a mkdir-based lock and write-then-rename.
- **Include guards.** Every `lib/*.sh` is safe to source multiple times.
