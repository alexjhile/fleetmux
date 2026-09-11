# fleetmux

**Multiplex a whole fleet of coding-agent sessions onto two tabs: a terminal and a browser.**

`fleetmux` is a small, dependency-light Bash CLI for commanding many [Claude Code](https://www.anthropic.com/claude-code) sessions at once — some on your laptop, some on remote hosts — from a single control point. It wraps `tmux` + `ssh` so every session is persistent and reattachable, and adds dispatch, monitoring, git-drift detection, memory backup, multi-account routing, and overnight autonomous queue draining on top.

It is a **control plane for agents you already have**, not an agent framework. Claude Code is the runtime; fleetmux is the bridge from which you steer the fleet.

```
   terminal tab ─┐                              ┌──── local sessions ───┐
                 ├─▶ ┌────────────┐ ──tmux─────▶ │  web   api   worker … │
   browser tab ──┘   │  fleetmux  │              └───────────────────────┘
   (gui/ dash)       │  CLI + GUI │ ──ssh─tmux─▶ ┌──── remote hosts ─────┐
                     └────────────┘              │  host-a  host-b …      │
                                                 └───────────────────────┘
```

Two tabs run the whole fleet: a **terminal** (the `fleetmux` CLI + a tmux dashboard) and a **browser** (the optional [web GUI](gui/) on `localhost:9035`).

---

## Why

If you run more than two or three Claude Code sessions, you lose the plot fast: which ones are alive, what they're working on, whether a remote checkout has drifted from `origin`, which task you dispatched where. fleetmux collapses all of that into one control plane you drive from a single terminal tab — with a live tmux dashboard a keystroke away, and an optional browser dashboard for clicking around.

## Features

- **One registry, many sessions** — declare every session (local or remote) in `sessions.json`; start/stop/attach by name.
- **Shortest-path dispatch** — `ssh` for one-off shell commands, `run` to send a task to a live Claude session, `exec` for headless `claude -p`, `each` to fan a command across the whole fleet in parallel.
- **Remote over tmux+SSH** — remote sessions live in a `tmux` session *on the host*, so they survive disconnects; fleetmux reattaches.
- **Monitoring** — `status`, `health` (disk/mem/uptime + git), `alerts`, `history`, and a live `watch` dashboard.
- **Drift detection** — `drift` compares local checkout vs remote vs `origin` and (`--fix`) reconciles.
- **Brain backup** — `brain` snapshots every session's Claude Code memory into `brain/` and commits it, giving you a git audit trail of what each agent "knows".
- **Multi-account OAuth routing** — assign different Claude accounts to different sessions; a launch wrapper exports the right token per session.
- **Model guard** — auto-downgrade Opus→Sonnet under subscription-limit pressure, auto-restore when pressure clears.
- **AFK queue drain** — drain a project's "ready" issue queue overnight via an autonomous run harness (see [AFK](#afk-overnight-autonomous-runs)).

## Requirements

- macOS, Linux, or **Windows via WSL2** — see **[WINDOWS.md](WINDOWS.md)** for the Windows walkthrough
- `bash` (3.2+ — macOS stock bash works), `tmux`, `ssh`, `jq`, `git`
- [Claude Code](https://www.anthropic.com/claude-code) installed (`claude` on `PATH`) **and authenticated** — run `claude` once and sign in before pointing fleetmux at it (on Windows: inside WSL)
- Optional: `glab`/`gh` for issue-queue probing, `npx`/`tsx` for the AFK harness, `shellcheck` + `bats` for development; Node 20.11+ for the web GUI

## Quickest start: one command

```bash
git clone https://github.com/alexjhile/fleetmux.git
cd fleetmux
./setup.sh
```

`setup.sh` checks prerequisites, links the CLI onto your PATH, seeds `sessions.json`, registers a `homebase` controller session, builds the web GUI, starts it on **http://localhost:9035**, and opens it in your browser. Safe to re-run.

**On Windows**, run it inside WSL2. It also installs a `fleetmux` command for PowerShell/cmd and a "fleetmux" Windows Terminal profile. See [WINDOWS.md](WINDOWS.md).

> **Hand it to Claude Code:** open Claude Code in the cloned repo and say *"read README.md, then run ./setup.sh."* With permissions granted it'll do the whole bootstrap — provided the prerequisites below are already installed and you're signed in to Claude Code.

## Install (manual)

```bash
git clone https://github.com/alexjhile/fleetmux.git
cd fleetmux

# Put the CLI on your PATH (creates ~/bin if needed):
mkdir -p ~/bin
ln -s "$PWD/fleetmux" ~/bin/fleetmux
# If ~/bin isn't already on PATH, add it (zsh shown):
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc

# Create your session registry from the template:
cp sessions.example.json sessions.json

fleetmux list   # should print the three example sessions
```

For the GUI: `cd gui && npm install && (cd server && npm install) && npm start` → http://localhost:9035.

## How it works (mental model)

- A **session** is one Claude Code instance with a name, a working dir, and (for remote) an SSH host. You declare them all in `sessions.json`.
- `fleetmux start <name>` opens a **tmux window** running `claude` in that session's dir (for remote sessions, it SSHes in and starts tmux *on the host*, so it survives disconnects).
- Once a session is running, you talk to it with:
  - **`run <name> "task"`** — type a task into the live Claude session (the normal way to delegate work)
  - **`exec <name> "task"`** — one-shot headless `claude -p` (no interactive session needed)
  - **`ssh <name> "cmd"`** — run a plain shell command in the session's dir/host (no Claude involved)
  - **`attach <name>`** — jump into the session's tmux window yourself
- Everything you dispatch is logged to `tasks.json` (`fleetmux history`).

## Your first session

```bash
# 1. Register a local project (or edit sessions.json by hand)
fleetmux add api local ~/code/my-api "Backend API"

# 2. Start it — opens a tmux window running Claude Code in that dir
fleetmux start api

# 3. Delegate a task to the running session
fleetmux run api "add a healthcheck endpoint and a test for it"

# 4. Watch the fleet live, or jump in
fleetmux watch          # live dashboard (Ctrl-C to exit)
fleetmux attach api     # drop into the session's terminal

# 5. See what you dispatched
fleetmux history
```

Run `fleetmux help` for the full command list.

## Driving the fleet in English

The commands above are great, but the way fleetmux is meant to be *lived in* is one level up: a dedicated Claude Code session — the **controller** (a.k.a. "homebase") — that you talk to in plain English while it runs `fleetmux` for you.

The real workflow is **AFK-first** — you don't babysit live sessions, you queue work and let it drain autonomously:

> *"Use afk-workflow to add rate-limiting to the billing repo."* → the controller stress-tests the idea (`grill-me`), writes a spec (`to-prd`), slices it into issues (`to-issues`), and queues them.
>
> *"Night shift."* → `fleetmux afk all` drains every ready queue overnight, in parallel.
>
> *"What happened overnight?"* → it reads the run sidecars and reports what shipped, what's stuck, what needs you.

Direct, hands-on dispatch (`start`/`run`/`ssh`) is still there for debugging and one-offs — it's just the exception, not the day job.

To set it up, make **[`HOMEBASE.md`](HOMEBASE.md)** the `CLAUDE.md` of that session (full instructions + the AFK loop inside). Then double-click `fleetmux.command` (macOS), open the "fleetmux" Windows Terminal profile (Windows), or run `claude` in your projects dir, and start talking.

## Dashboard & launcher

- **`fleetmux watch`** — full-screen live status (refreshes every N seconds).
- **`fleetmux dash`** — dock a compact status pane in your current tmux window; **`fleetmux dash keys`** installs `prefix+a` (toggle dash) and `prefix+g` (session picker).
- **`fleetmux.command`** — double-click in Finder (macOS), or open the "fleetmux" Windows Terminal profile (Windows), to open Claude Code + the dashboard in one move. Re-running reattaches.
- **Web GUI** — see [`gui/`](gui/): a browser/desktop dashboard on `localhost:9035` with live terminals, usage charts, and health.

## Configuration

fleetmux is configured by `sessions.json` (copy `sessions.example.json`) plus environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `AIOS_DIR` | repo dir | Where fleetmux looks for `sessions.json`, `tasks.json`, `brain/`, `logs/` |
| `AIOS_SECRETS_DIR` | `~/.config/fleetmux/secrets` | Optional `hosts.env` + account tokens live here |
| `AIOS_CLAUDE_CODE_ROOT` | `~/code` | Parent dir of your local checkouts (used to shorten paths in output) |
| `AIOS_REMOTE_WRAPPER` | `~/.aios-claude` | Path to the launch wrapper on remote hosts |
| `AIOS_TMUX_SOCKET` | auto | Explicit tmux socket (useful under launchd/cron) |

> Internal env vars and the tmux session name keep the `AIOS_`/`aios` prefix for historical reasons — fleetmux began life as a personal tool named "AIOS". They're functionally irrelevant to users.

### `sessions.json` schema

```jsonc
{
  "name": "api",                  // unique session id
  "type": "local",               // local | remote | utility
  "path": "/home/you/code/api",  // working dir (local path, or remote path for remote type)
  "host": "deploy@203.0.113.10", // remote type only: ssh target
  "description": "Backend API",
  "tags": ["backend"],
  "autostart": false,             // started by `startall` without --all
  "claude_flags": "--continue --dangerously-skip-permissions",
  "account": "",                  // optional: account profile (see Accounts). "" = ambient auth
  "afk_ready": true               // optional: opt-in to `afk` queue draining
}
```

Only `name`, `type`, and `path` are required. Leave `account` empty (or omit it) to use Claude Code's ambient auth — set it only once you've configured named accounts (see below), otherwise the launcher warns about a missing token.

## Accounts

fleetmux can route different sessions to different Claude accounts. Tokens (from `claude setup-token`) are stored under `$AIOS_SECRETS_DIR/claude-accounts/<name>.token`, deployed to each machine, and selected at launch by a wrapper that reads `$AIOS_ACCOUNT`. See `fleetmux account --help`.

## Model guard

`fleetmux model-guard` watches your 5-hour subscription utilization and downgrades sessions Opus→Sonnet when usage is high with significant time left on the window, restoring Opus when pressure clears. It never uses Haiku. Run `fleetmux model-guard status` for the curve and active overrides.

## AFK (overnight autonomous runs)

`fleetmux afk <session>` drains a project's `ready-for-agent` issue queue unattended. It expects the target repo to ship an autonomous run harness at `.sandcastle/loop.ts` (drain) / `.sandcastle/main.ts <issue#>` (single issue) and uses `glab` to probe the queue. Sessions must opt in with `"afk_ready": true`. `fleetmux afk all` broadcasts across all opted-in sessions (parallel-capped, default 3). Each run records a row in `tasks.json` and a JSON sidecar under `.aios/afk-runs/`.

The workflow and a ready-to-copy harness template are bundled in **[`afk-workflow/`](afk-workflow/)** — start with `afk-workflow/docs/adoption-checklist.md` and copy `afk-workflow/docs/sandcastle-template/` into your project's `.sandcastle/`.

## Repo layout

```
setup.sh              one-command bootstrap (CLI + GUI + browser)
fleetmux              CLI entry point (bash)
fleetmux.command      one-move launcher (Finder double-click / Windows Terminal profile)
HOMEBASE.md           operator playbook — drive the fleet in English
WINDOWS.md            running fleetmux on Windows via WSL2
lib/                  command modules (one concern each)
bin/                  launch wrapper + usage/limits helpers
test/                 bats suite
sessions.example.json template registry — copy to sessions.json
gui/                  optional web + desktop dashboard (React/Express/Tauri)
afk-workflow/         the AFK workflow docs + .sandcastle/ harness template
```

## Development

```bash
make check     # shellcheck + bats (the CLI)
make lint
make test
```

The CLI is pure Bash — each command lives in its own `lib/*.sh` module with an include guard; `fleetmux` is the entry point that sources them. The optional GUI has its own toolchain and tests under [`gui/`](gui/). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgements

fleetmux's AFK / autonomous-run workflow is built on the work of **[Matt Pocock](https://github.com/mattpocock)**:

- **[Sandcastle](https://www.npmjs.com/package/@ai-hero/sandcastle)** (`@ai-hero/sandcastle`) — the sandboxed autonomous-run harness that `fleetmux afk` drives. The template under [`afk-workflow/docs/sandcastle-template/`](afk-workflow/docs/sandcastle-template/) is adapted from Sandcastle's scaffold.
- **[mattpocock/skills](https://github.com/mattpocock/skills)** — the engineering skills (`grill-me`, `to-prd`, `to-issues`, `tdd`, `triage`, …) that drive the queue-and-drain pipeline.

fleetmux integrates and adapts these tools (installed per their own instructions) — it doesn't redistribute their source. See their repos for the canonical versions and licensing. And of course [Claude Code](https://www.anthropic.com/claude-code), the runtime every session runs on.

## License

[MIT](LICENSE) © Alex Hile
