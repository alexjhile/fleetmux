# fleetmux — guidance for Claude Code

> **Working _on_ fleetmux (editing this codebase)?** You're in the right place.
> **Operating a fleet _with_ fleetmux (driving sessions in English)?** See [`HOMEBASE.md`](HOMEBASE.md) instead.

A dependency-light Bash CLI that orchestrates many Claude Code sessions (local + remote) over `tmux` + `ssh`. No daemon, no database — state is JSON files in the repo dir.

## Stack
Bash (3.2+) · tmux · ssh · jq · bats-core · shellcheck

## Layout
- `fleetmux` — entry point; sources `lib/*.sh` and dispatches commands
- `lib/*.sh` — one module per concern, each with an include guard
- `bin/` — launch wrapper + usage/limits helpers deployed to managed machines
- `test/` — bats suite
- `sessions.json` — the session registry (gitignored; copy from `sessions.example.json`)

## Working in this repo
- **Bash 3.2 compatibility is mandatory** (macOS stock bash). No `mapfile`, no `wait -n`; guard empty-array expansion with `"${arr[@]+"${arr[@]}"}"`.
- **GNU + BSD userlands.** Never call `date -j`/`date -d`/`stat -f`/`stat -c` directly — use `iso_to_epoch`, `local_datetime_to_epoch`, `epoch_fmt`, `file_mtime` from `lib/platform.sh`. macOS is BSD; Linux and WSL (the Windows story, see `WINDOWS.md`) are GNU.
- **`make check` must stay green** — `shellcheck -x` + `bats`. CI runs it on every push/PR.
- **No hardcoded paths or secrets.** Everything machine-specific goes through `sessions.json` or `AIOS_*` env vars (`AIOS_DIR`, `AIOS_SECRETS_DIR`, `AIOS_CLAUDE_CODE_ROOT`, `AIOS_REMOTE_WRAPPER`).
- New commands: add `lib/<name>.sh` with an include guard, source it from `fleetmux`, add bats tests, update the help text and README.

## Note on naming
Internal env vars and the tmux session name use the `AIOS_`/`aios` prefix — fleetmux began as a personal tool called "AIOS". This is intentional and load-bearing in places (wrapper filenames `~/.aios-claude`, account dirs `~/.aios-accounts`); don't rename internals without updating every reference and re-running the suite.
