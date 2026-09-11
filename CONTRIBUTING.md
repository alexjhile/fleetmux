# Contributing

Thanks for your interest in fleetmux!

## Development setup

```bash
git clone https://github.com/alexjhile/fleetmux.git
cd fleetmux
cp sessions.example.json sessions.json   # required for many tests/commands
make check                               # shellcheck + bats
```

You'll need `bash`, `tmux`, `jq`, `git`, `shellcheck`, and `bats-core`.

## Guidelines

- **Keep it bash 3.2 compatible.** macOS ships bash 3.2. No `mapfile`, no `wait -n`; guard empty-array expansion with `"${arr[@]+"${arr[@]}"}"`.
- **Keep it GNU + BSD portable.** Linux/WSL use GNU `date`/`stat`, macOS uses BSD. Go through the helpers in `lib/platform.sh` rather than calling platform-specific flags.
- **One concern per module.** New commands generally get a `lib/<thing>.sh` with an include guard, sourced from the `fleetmux` entry point.
- **Lint + test must pass.** `make check` runs in CI on every push and PR.
- **No secrets, no machine-specific paths.** Configuration goes through `sessions.json` and `FLEETMUX_*` env vars, never hardcoded paths or tokens.
- **Add tests.** New logic should come with `bats` coverage in `test/`.

## Pull requests

1. Fork and branch from `main`.
2. Make your change with tests.
3. Run `make check`.
4. Open a PR describing the change and why.
