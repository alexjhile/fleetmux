#!/usr/bin/env bash
# fleetmux one-command setup.
#
#   ./setup.sh
#
# Installs the CLI on your PATH, seeds sessions.json, registers a "homebase"
# controller session, builds the web GUI, starts it on :9035, and opens it in
# your browser. Safe to re-run (idempotent).
#
# Prereqs it can't install for you: Claude Code (authenticated), tmux, jq, git,
# and Node/npm (for the GUI). It checks and tells you what's missing.

set -eo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

say()  { printf '\033[36m▶ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$1"; }

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
say "Checking prerequisites"
core_missing=""
for c in bash tmux jq git; do
  command -v "$c" >/dev/null 2>&1 || core_missing="$core_missing $c"
done
command -v claude >/dev/null 2>&1 || core_missing="$core_missing claude"
if [ -n "$core_missing" ]; then
  warn "Missing:$core_missing"
  echo "   Install them first. Claude Code: https://www.anthropic.com/claude-code"
  echo "   (then run 'claude' once and sign in so fleetmux can launch sessions)."
  exit 1
fi
ok "core tools present"

have_npm=1
command -v npm >/dev/null 2>&1 || have_npm=0
[ "$have_npm" -eq 0 ] && warn "npm not found — will set up the CLI but skip the GUI"

# ── 2. CLI on PATH ───────────────────────────────────────────────────────────
say "Linking the fleetmux CLI into ~/bin"
mkdir -p "$HOME/bin"
ln -sf "$REPO_DIR/fleetmux" "$HOME/bin/fleetmux"
ok "$HOME/bin/fleetmux -> $REPO_DIR/fleetmux"
case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) warn "$HOME/bin is not on your PATH — add: export PATH=\"\$HOME/bin:\$PATH\"" ;;
esac

# ── 3. Session registry + homebase controller ───────────────────────────────
say "Seeding sessions.json"
[ -f sessions.json ] || cp sessions.example.json sessions.json
if jq -e '.[] | select(.name=="homebase")' sessions.json >/dev/null 2>&1; then
  ok "homebase controller session already registered"
else
  "$REPO_DIR/fleetmux" add homebase local "$REPO_DIR" "Fleet controller — reads HOMEBASE.md" >/dev/null
  ok "registered 'homebase' controller session"
fi

# ── 4. GUI: install + build ──────────────────────────────────────────────────
if [ "$have_npm" -eq 1 ]; then
  say "Installing GUI dependencies (this can take a minute)"
  ( cd gui && npm install --no-fund --no-audit --silent )
  ( cd gui/server && npm install --no-fund --no-audit --silent )
  say "Building the web frontend"
  ( cd gui && npm run build --silent )
  ok "GUI built"

  # ── 5. Start server + open browser ─────────────────────────────────────────
  say "Starting the GUI server on http://localhost:9035"
  if curl -sf "http://localhost:9035" >/dev/null 2>&1; then
    ok "a server is already listening on :9035"
  else
    ( cd gui/server && AIOS_DIR="$REPO_DIR" nohup npx tsx index.ts >"$REPO_DIR/gui/server.log" 2>&1 & )
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      curl -sf "http://localhost:9035" >/dev/null 2>&1 && break
      sleep 0.5
    done
    if curl -sf "http://localhost:9035" >/dev/null 2>&1; then
      ok "server up (log: gui/server.log — stop with: pkill -f 'tsx index.ts')"
    else
      warn "server didn't answer yet — check gui/server.log; start manually with: cd gui && npm start"
    fi
  fi

  say "Opening the dashboard in your browser"
  if command -v open >/dev/null 2>&1; then
    open -a "Google Chrome" "http://localhost:9035" 2>/dev/null || open "http://localhost:9035" 2>/dev/null || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "http://localhost:9035" >/dev/null 2>&1 || true
  else
    warn "couldn't auto-open a browser — go to http://localhost:9035"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo
ok "Setup complete."
echo "  • CLI:       fleetmux list"
echo "  • Dashboard: http://localhost:9035"
echo "  • Drive it in English: make HOMEBASE.md the CLAUDE.md of your controller session"
echo "    (the 'homebase' session is registered; see HOMEBASE.md for the 2-minute setup)."
