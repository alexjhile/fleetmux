#!/bin/bash
# fleetmux — one-move launcher.
#
# Opens Claude Code inside a tmux window with the fleetmux dashboard docked
# below it, so you start your day in one move. Safe to re-run — it reattaches
# if already running.
#   macOS:   double-click this file in Finder (runs in Terminal.app).
#   Windows: pick the "fleetmux" profile in Windows Terminal (installed by
#            setup.sh; it runs this script inside WSL).
#   Any:     run it from a shell.
#
# Config (env overrides):
#   FLEETMUX_TMUX_SESSION   tmux session name      (default: aios)
#   FLEETMUX_WINDOW         control window name    (default: control)
#   FLEETMUX_WORKDIR        starting directory     (default: this repo's dir)
#   CLAUDE_BIN              claude binary           (default: claude on PATH)

set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TMUX_SESSION="${FLEETMUX_TMUX_SESSION:-aios}"
WINDOW_NAME="${FLEETMUX_WINDOW:-control}"
WORKDIR="${FLEETMUX_WORKDIR:-$REPO_DIR}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"
CLAUDE_CMD="$CLAUDE_BIN --continue --verbose --dangerously-skip-permissions"

launch_window() {
  tmux new-window -t "$TMUX_SESSION" -n "$WINDOW_NAME" \
    "cd '$WORKDIR' && $CLAUDE_CMD; bash"
}

# Already inside tmux — just focus/create the control window.
if [[ -n "${TMUX:-}" ]]; then
  tmux select-window -t "${TMUX_SESSION}:${WINDOW_NAME}" 2>/dev/null || launch_window
  exit 0
fi

# Session exists — attach (creating the control window if missing).
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  if ! tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' | grep -qx "$WINDOW_NAME"; then
    launch_window
  fi
  tmux select-window -t "${TMUX_SESSION}:${WINDOW_NAME}"
  exec tmux attach -t "$TMUX_SESSION"
fi

# Fresh start — create the session, launch Claude, dock the dashboard below.
tmux new-session -d -s "$TMUX_SESSION" -n "$WINDOW_NAME" -c "$WORKDIR"
tmux send-keys -t "${TMUX_SESSION}:${WINDOW_NAME}" "$CLAUDE_CMD" Enter
sleep 2
if [[ -f "${REPO_DIR}/lib/dashboard.sh" ]]; then
  tmux split-window -t "${TMUX_SESSION}:${WINDOW_NAME}" -b -v -l 12 \
    "exec bash -c 'source \"${REPO_DIR}/lib/dashboard.sh\" && dash_status_loop 30'"
  tmux select-pane -t "${TMUX_SESSION}:${WINDOW_NAME}.0" 2>/dev/null || true
fi
exec tmux attach -t "$TMUX_SESSION"
