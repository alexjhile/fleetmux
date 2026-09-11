#!/usr/bin/env bash
# fleetmux one-command setup.
#
#   ./setup.sh
#
# Installs the CLI on your PATH, seeds sessions.json, registers a "homebase"
# controller session, builds the web GUI, starts it on :9035, and opens it in
# your browser. Safe to re-run (idempotent).
#
# Runs on macOS, Linux, and Windows via WSL2 — on Windows, run it *inside* your
# WSL distro (see WINDOWS.md). Under WSL it also installs a `fleetmux` command
# for PowerShell/cmd and a "fleetmux" Windows Terminal profile.
#
# Prereqs it can't install for you: Claude Code (authenticated), tmux, jq, git,
# and Node/npm (for the GUI). It checks and tells you what's missing.

set -eo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"
# shellcheck source=lib/platform.sh
source "$REPO_DIR/lib/platform.sh"

say()  { printf '\033[36m▶ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m!  %s\033[0m\n' "$1"; }
ok()   { printf '\033[32m✓ %s\033[0m\n' "$1"; }

IS_MAC=0; [ "$(uname -s)" = "Darwin" ] && IS_MAC=1
IS_WSL=0; platform_is_wsl && IS_WSL=1

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
say "Checking prerequisites"
core_missing=""
for c in bash tmux jq git; do
  command -v "$c" >/dev/null 2>&1 || core_missing="$core_missing $c"
done
command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ] || core_missing="$core_missing claude"
if [ -n "$core_missing" ]; then
  warn "Missing:$core_missing"
  if [ "$IS_MAC" -eq 1 ]; then
    echo "   brew install tmux jq git"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "   sudo apt-get update && sudo apt-get install -y tmux jq git curl"
  fi
  echo "   Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
  echo "   (then run 'claude' once and sign in so fleetmux can launch sessions)."
  [ "$IS_WSL" -eq 1 ] && echo "   Under WSL, install Claude Code *inside* the distro — the Windows claude.exe can't drive tmux sessions."
  exit 1
fi
ok "core tools present"

if [ "$IS_WSL" -eq 1 ]; then
  case "$REPO_DIR" in
    /mnt/*) warn "repo is on the Windows filesystem ($REPO_DIR) — it works, but git, npm and the GUI are much faster from the WSL home dir (e.g. git clone into ~/fleetmux)." ;;
  esac
fi

# The GUI server needs Node 20.11+ (import.meta.dirname); on Linux/WSL,
# node-pty also compiles from source and needs a C++ toolchain + python3.
have_npm=1
if ! command -v npm >/dev/null 2>&1; then
  have_npm=0
  warn "npm not found — will set up the CLI but skip the GUI (install Node 20.11+, e.g. via nvm)"
else
  node_ver=$(node -p 'process.versions.node' 2>/dev/null || echo 0)
  node_major=${node_ver%%.*}; node_rest=${node_ver#*.}; node_minor=${node_rest%%.*}
  if [ "$node_major" -lt 20 ] || { [ "$node_major" -eq 20 ] && [ "$node_minor" -lt 11 ]; }; then
    have_npm=0
    warn "Node $node_ver is too old for the GUI (needs 20.11+) — skipping it. Install a newer Node (e.g. nvm install --lts) and re-run."
  fi
  if [ "$have_npm" -eq 1 ] && [ "$IS_MAC" -eq 0 ]; then
    for c in make g++ python3; do
      if ! command -v "$c" >/dev/null 2>&1; then
        have_npm=0
        warn "$c not found — node-pty can't compile, skipping the GUI. Install: sudo apt-get install -y build-essential python3"
        break
      fi
    done
  fi
fi

# ── 2. CLI on PATH ───────────────────────────────────────────────────────────
say "Linking the fleetmux CLI into ~/bin"
mkdir -p "$HOME/bin"
ln -sf "$REPO_DIR/fleetmux" "$HOME/bin/fleetmux"
ok "$HOME/bin/fleetmux -> $REPO_DIR/fleetmux"
case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) warn "$HOME/bin is not on your PATH — add: export PATH=\"\$HOME/bin:\$PATH\"" ;;
esac

# `fleetmux start` launches Claude through ~/.aios-claude (the account-aware
# wrapper). Install it — plus the usage parser — locally, or every session
# opens to "~/.aios-claude: No such file or directory". Idempotent; with no
# named accounts the wrapper just uses Claude Code's own login.
"$REPO_DIR/fleetmux" account sync local >/dev/null
ok "Claude launch wrapper installed at ~/.aios-claude"

# ── 2b. Windows integration (WSL only) ──────────────────────────────────────
# Read a Windows environment variable from inside WSL.
win_env() {
  local v
  v=$(cmd.exe /c "echo %$1%" 2>/dev/null | tr -d '\r')
  [ "$v" = "%$1%" ] && v=""
  printf '%s' "$v"
}

# Single-quoted PowerShell literal. Double quotes don't survive the
# WSL→Windows argv hop reliably, so everything passed to PowerShell uses these.
ps_quote() {
  local q="'"
  printf "'%s'" "${1//$q/$q$q}"
}

# PowerShell that creates Desktop\<name>.lnk (target, args, icon) and prints
# the shortcut's full path.
ps_desktop_shortcut() {
  printf '%s' "\$s = (New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop') + '\\$1.lnk'); \$s.TargetPath = $(ps_quote "$2"); \$s.Arguments = $(ps_quote "$3"); \$s.IconLocation = $(ps_quote "$4"); \$s.Description = 'fleetmux homebase: Claude Code + the fleet dashboard'; \$s.Save(); \$s.FullName"
}

install_windows_integration() {
  if ! command -v cmd.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
    warn "Windows interop unavailable (cmd.exe/wslpath not found) — skipping the Windows shim and terminal profile"
    return 0
  fi
  local distro="${WSL_DISTRO_NAME:-}" distro_arg=""
  # No quotes anywhere on these wsl.exe command lines: wsl.exe keeps them as
  # part of the value (-d "Ubuntu" → WSL_E_DISTRO_NOT_FOUND). Distro names
  # can't contain spaces; a repo path with one can't be supported here.
  [ -n "$distro" ] && distro_arg="-d $distro "
  case "$REPO_DIR" in
    *" "*) warn "repo path contains a space ($REPO_DIR) — the Windows command, profile and shortcut won't work; move the repo" ;;
  esac

  local userprofile localappdata winpath
  userprofile=$(win_env USERPROFILE)
  localappdata=$(win_env LOCALAPPDATA)
  winpath=$(win_env PATH | tr '[:upper:]' '[:lower:]')
  if [ -z "$userprofile" ]; then
    warn "couldn't read %USERPROFILE% from Windows — skipping the Windows shim and terminal profile"
    return 0
  fi

  # fleetmux.cmd — lets PowerShell/cmd run `fleetmux ...` (forwards into WSL).
  # Prefer a dir already on the Windows PATH; FLEETMUX_WIN_BIN overrides.
  local bin_win="${FLEETMUX_WIN_BIN:-}" on_path=1
  if [ -z "$bin_win" ]; then
    local lower_local
    lower_local=$(printf '%s' "${userprofile}\\.local\\bin" | tr '[:upper:]' '[:lower:]')
    case ";$winpath;" in
      *";$lower_local;"*|*";$lower_local\\;"*) bin_win="${userprofile}\\.local\\bin" ;;
      *) bin_win="${userprofile}\\bin" ;;
    esac
  fi
  local lower_bin
  lower_bin=$(printf '%s' "$bin_win" | tr '[:upper:]' '[:lower:]')
  case ";$winpath;" in
    *";$lower_bin;"*|*";$lower_bin\\;"*) ;;
    *) on_path=0 ;;
  esac

  local bin_dir
  bin_dir=$(wslpath -u "$bin_win")
  mkdir -p "$bin_dir"
  {
    echo '@echo off'
    echo 'rem Generated by fleetmux setup.sh - runs the fleetmux CLI inside WSL.'
    echo "wsl.exe ${distro_arg}-e bash -l $REPO_DIR/fleetmux %*"
  } | sed 's/$/\r/' > "$bin_dir/fleetmux.cmd"
  ok "Windows command: $bin_win\\fleetmux.cmd"
  if [ "$on_path" -eq 0 ]; then
    warn "$bin_win is not on your Windows PATH. In PowerShell run:"
    echo "   [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';$bin_win', 'User')"
    echo "   then open a new terminal."
  fi

  # Windows Terminal profile — the Windows equivalent of double-clicking
  # fleetmux.command: Claude Code + the docked dashboard in one tab.
  if [ -n "$localappdata" ]; then
    local frag_dir
    frag_dir="$(wslpath -u "$localappdata")/Microsoft/Windows Terminal/Fragments/fleetmux"
    mkdir -p "$frag_dir"
    jq -n \
      --arg cmd "wsl.exe ${distro_arg}-e bash -l $REPO_DIR/fleetmux.command" \
      --arg icon "$(wslpath -w "$REPO_DIR/gui/src-tauri/icons/32x32.png")" \
      '{profiles: [{name: "fleetmux", commandline: $cmd, icon: $icon, tabTitle: "fleetmux"}]}' \
      > "$frag_dir/fleetmux.json"
    ok "Windows Terminal profile 'fleetmux' installed (restart Windows Terminal to see it)"
  fi

  # Desktop shortcut "fleetmux homebase" → the controller (Claude Code + the
  # docked dashboard): through the Windows Terminal profile when WT is
  # installed, else straight into wsl.exe. The icon is copied to the Windows
  # side so it still renders while WSL is stopped.
  if [ -n "$localappdata" ] && command -v powershell.exe >/dev/null 2>&1; then
    local ico_dir target args lnk
    ico_dir="$(wslpath -u "$localappdata")/fleetmux"
    mkdir -p "$ico_dir"
    cp "$REPO_DIR/gui/src-tauri/icons/icon.ico" "$ico_dir/fleetmux.ico"
    if command -v wt.exe >/dev/null 2>&1; then
      target=$(wslpath -w "$(command -v wt.exe)")
      # Spell the command out instead of `-p fleetmux`: a Windows Terminal
      # that's already running only picks up fragment profiles at its next
      # start, and an unknown -p silently opens the default shell.
      args="new-tab --title fleetmux -- wsl.exe ${distro:+-d $distro }-e bash -l $REPO_DIR/fleetmux.command"
    else
      target='C:\Windows\System32\wsl.exe'
      args="${distro:+-d $distro }-e bash -l $REPO_DIR/fleetmux.command"
    fi
    lnk=$(powershell.exe -NoProfile -NonInteractive -Command \
      "$(ps_desktop_shortcut "fleetmux homebase" "$target" "$args" "$(wslpath -w "$ico_dir/fleetmux.ico")")" \
      2>/dev/null | tr -d '\r')
    if [ -n "$lnk" ]; then
      ok "Desktop shortcut: $lnk"
    else
      warn "couldn't create the desktop shortcut — use the 'fleetmux' Windows Terminal profile instead"
    fi
  fi

  # Keep Ubuntu running after the last terminal closes. By default WSL stops a
  # distro seconds after its last wsl.exe client exits, which kills tmux,
  # every session and the GUI server. instanceIdleTimeout=-1 turns that off.
  # Never clobbers an existing setting; other .wslconfig content is kept.
  local wslcfg
  wslcfg="$(wslpath -u "$userprofile")/.wslconfig"
  if grep -qiE '^[[:space:]]*instanceIdleTimeout[[:space:]]*=' "$wslcfg" 2>/dev/null; then
    ok "WSL idle timeout already set in ${userprofile}\\.wslconfig — left as is"
  else
    if grep -qiE '^[[:space:]]*\[general\]' "$wslcfg" 2>/dev/null; then
      awk '{ print } !done && tolower($0) ~ /^[ \t]*\[general\]/ { print "instanceIdleTimeout=-1\r"; done = 1 }' \
        "$wslcfg" > "$wslcfg.fleetmux-tmp" && cat "$wslcfg.fleetmux-tmp" > "$wslcfg" && rm -f "$wslcfg.fleetmux-tmp"
    else
      printf '\r\n# Added by fleetmux setup.sh: keep Ubuntu (tmux sessions, GUI server)\r\n# running after the last terminal closes.\r\n[general]\r\ninstanceIdleTimeout=-1\r\n' >> "$wslcfg"
    fi
    ok "WSL set to keep Ubuntu running after the last terminal closes (${userprofile}\\.wslconfig)"
    warn "takes effect after WSL restarts. From PowerShell: wsl --shutdown (this ends every WSL session)"
  fi
}

if [ "$IS_WSL" -eq 1 ]; then
  say "Installing Windows integration"
  install_windows_integration
fi

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
open_url() {
  local url="$1"
  if [ "$IS_MAC" -eq 1 ]; then
    open -a "Google Chrome" "$url" 2>/dev/null || open "$url" 2>/dev/null || true
  elif [ "$IS_WSL" -eq 1 ]; then
    # Opens in the default Windows browser; WSL2 forwards localhost to Windows.
    if command -v wslview >/dev/null 2>&1; then
      wslview "$url" >/dev/null 2>&1 || true
    else
      explorer.exe "$url" >/dev/null 2>&1 || true   # exits 1 even on success
    fi
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 || true
  else
    warn "couldn't auto-open a browser — go to $url"
  fi
}

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
    # setsid (Linux) gives the server its own session, so it outlives the
    # terminal that ran setup: WSL kills whatever is left of a wsl.exe
    # session when that session ends. macOS has no setsid; nohup suffices.
    # Detach every stdio of the whole subtree too: anything left holding
    # setup's stdout would keep `./setup.sh | tee log` waiting forever.
    setsid_bin=$(command -v setsid || true)
    ( cd gui/server && AIOS_DIR="$REPO_DIR" ${setsid_bin:+"$setsid_bin"} nohup npx tsx index.ts >"$REPO_DIR/gui/server.log" 2>&1 </dev/null & ) >/dev/null 2>&1 </dev/null
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
  open_url "http://localhost:9035"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo
ok "Setup complete."
echo "  • CLI:       fleetmux list"
[ "$IS_WSL" -eq 1 ] && echo "               (also works from PowerShell/cmd, and the 'fleetmux' Windows Terminal profile)"
echo "  • Dashboard: http://localhost:9035"
echo "  • Drive it in English: make HOMEBASE.md the CLAUDE.md of your controller session"
echo "    (the 'homebase' session is registered; see HOMEBASE.md for the 2-minute setup)."
