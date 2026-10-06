#!/usr/bin/env bash
# shellcheck disable=SC1091
# Web GUI lifecycle — start/stop/status for the dashboard server, plus
# autostart at login/boot (systemd user unit on Linux/WSL, LaunchAgent on macOS).
[[ -n "${_FLEETMUX_GUI_LOADED:-}" ]] && return 0; _FLEETMUX_GUI_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"

GUI_PORT="${FLEETMUX_GUI_PORT:-9035}"
GUI_URL="http://localhost:${GUI_PORT}"
GUI_DIR="${FLEETMUX_DIR}/gui"
GUI_LOG="${GUI_DIR}/server.log"
# Bracket class keeps the pattern from matching a shell that merely has this
# file's text on its command line.
GUI_PATTERN='tsx index[.]ts'
GUI_UNIT_NAME="fleetmux-gui"
GUI_PLIST_LABEL="com.fleetmux.gui"

# Is the server answering?
gui_is_up() {
    curl -sf --max-time 3 -o /dev/null "$GUI_URL" 2>/dev/null
}

# PIDs of the server processes (npm wrapper + node), newest last.
gui_pids() {
    pgrep -f "$GUI_PATTERN" 2>/dev/null || true
}

# Wait up to $1 deciseconds (default 200 = 20s) for the server to answer.
_gui_wait_up() {
    local tries="${1:-40}"
    while [[ "$tries" -gt 0 ]]; do
        gui_is_up && return 0
        sleep 0.5
        tries=$((tries - 1))
    done
    return 1
}

# Launch the server detached, so it outlives the terminal that started it.
_gui_spawn() {
    local npx_bin setsid_bin
    npx_bin=$(command -v npx 2>/dev/null || true)
    if [[ -z "$npx_bin" ]]; then
        print_error "npx not found — install Node 20.11+ (the GUI needs it)"
        return 1
    fi
    if [[ ! -d "${GUI_DIR}/server/node_modules" ]]; then
        print_error "GUI dependencies missing — run ./setup.sh first"
        return 1
    fi
    setsid_bin=$(command -v setsid || true)
    ( cd "${GUI_DIR}/server" && FLEETMUX_DIR="$FLEETMUX_DIR" \
        ${setsid_bin:+"$setsid_bin"} nohup "$npx_bin" tsx index.ts \
        >"$GUI_LOG" 2>&1 </dev/null & ) >/dev/null 2>&1 </dev/null
}

# Start the server unless it is already answering.
gui_start() {
    if gui_is_up; then
        print_info "GUI already running at ${GUI_URL}"
        return 0
    fi
    _gui_spawn || return 1
    if _gui_wait_up; then
        print_success "GUI started at ${GUI_URL} (log: ${GUI_LOG})"
    else
        print_error "GUI did not answer on ${GUI_URL} — check ${GUI_LOG}"
        return 1
    fi
}

# Start only if down, and stay quiet when nothing needs doing. Used by the
# homebase launcher so opening the controller also brings the dashboard up.
gui_ensure() {
    gui_is_up && return 0
    [[ -d "${GUI_DIR}/server/node_modules" ]] || return 0
    command -v npx >/dev/null 2>&1 || return 0
    _gui_spawn >/dev/null 2>&1 || return 0
    _gui_wait_up 20 >/dev/null 2>&1 || return 0
}

gui_stop() {
    local pids
    pids=$(gui_pids)
    if [[ -z "$pids" ]]; then
        print_info "GUI is not running"
        return 0
    fi
    # shellcheck disable=SC2086  # deliberate word splitting: one kill per pid
    kill $pids 2>/dev/null || true
    local tries=20
    while [[ "$tries" -gt 0 ]] && [[ -n "$(gui_pids)" ]]; do
        sleep 0.5
        tries=$((tries - 1))
    done
    pids=$(gui_pids)
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
    fi
    print_success "GUI stopped"
}

gui_restart() {
    gui_stop
    gui_start
}

gui_status() {
    local pids
    pids=$(gui_pids | tr '\n' ' ')
    if gui_is_up; then
        print_success "GUI up at ${GUI_URL}${pids:+ (pid:${pids% })}"
    elif [[ -n "$pids" ]]; then
        print_warning "GUI process running (pid:${pids% }) but ${GUI_URL} is not answering — check ${GUI_LOG}"
    else
        print_info "GUI stopped. Start it with: fleetmux gui start"
    fi
    gui_autostart_status
}

# ─── Autostart ──────────────────────────────────────────────────────────────

_gui_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

_gui_unit_path() {
    printf '%s\n' "${HOME}/.config/systemd/user/${GUI_UNIT_NAME}.service"
}

_gui_plist_path() {
    printf '%s\n' "${HOME}/Library/LaunchAgents/${GUI_PLIST_LABEL}.plist"
}

# Write the systemd user unit. nvm's node is not on a login shell's default
# PATH, so pin the resolved bin dir into the unit.
_gui_write_unit() {
    local npx_bin node_dir unit
    npx_bin=$(command -v npx 2>/dev/null || true)
    [[ -z "$npx_bin" ]] && { print_error "npx not found — install Node 20.11+"; return 1; }
    node_dir=$(dirname "$npx_bin")
    unit=$(_gui_unit_path)
    mkdir -p "$(dirname "$unit")"
    cat > "$unit" <<UNIT
[Unit]
Description=fleetmux web GUI (dashboard on :${GUI_PORT})
After=network.target

[Service]
Type=simple
WorkingDirectory=${GUI_DIR}/server
Environment=FLEETMUX_DIR=${FLEETMUX_DIR}
Environment=PATH=${node_dir}:/usr/local/bin:/usr/bin:/bin
Environment=PORT=${GUI_PORT}
ExecStart=${npx_bin} tsx index.ts
Restart=on-failure
RestartSec=5
StandardOutput=append:${GUI_LOG}
StandardError=append:${GUI_LOG}

[Install]
WantedBy=default.target
UNIT
}

_gui_write_plist() {
    local npx_bin node_dir plist
    npx_bin=$(command -v npx 2>/dev/null || true)
    [[ -z "$npx_bin" ]] && { print_error "npx not found — install Node 20.11+"; return 1; }
    node_dir=$(dirname "$npx_bin")
    plist=$(_gui_plist_path)
    mkdir -p "$(dirname "$plist")"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${GUI_PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${npx_bin}</string><string>tsx</string><string>index.ts</string></array>
  <key>WorkingDirectory</key><string>${GUI_DIR}/server</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FLEETMUX_DIR</key><string>${FLEETMUX_DIR}</string>
    <key>PATH</key><string>${node_dir}:/usr/local/bin:/usr/bin:/bin</string>
    <key>PORT</key><string>${GUI_PORT}</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${GUI_LOG}</string>
  <key>StandardErrorPath</key><string>${GUI_LOG}</string>
</dict>
</plist>
PLIST
}

# Start the GUI at login/boot. Prints what it did; never fails the caller.
gui_autostart_enable() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        _gui_write_plist || return 1
        launchctl unload "$(_gui_plist_path)" 2>/dev/null || true
        if launchctl load "$(_gui_plist_path)" 2>/dev/null; then
            print_success "GUI autostart enabled (LaunchAgent ${GUI_PLIST_LABEL})"
        else
            print_warning "wrote $(_gui_plist_path) but launchctl load failed — load it manually"
        fi
        return 0
    fi
    if ! _gui_systemd_available; then
        print_warning "no systemd user session — can't install an autostart unit"
        print_info "WSL: enable systemd by putting 'systemd=true' under [boot] in /etc/wsl.conf, then 'wsl --shutdown'"
        print_info "Meanwhile the homebase launcher starts the GUI whenever you open it"
        return 0
    fi
    _gui_write_unit || return 1
    systemctl --user daemon-reload 2>/dev/null || true
    if systemctl --user enable --now "${GUI_UNIT_NAME}.service" 2>/dev/null; then
        print_success "GUI autostart enabled (systemd user unit ${GUI_UNIT_NAME})"
    else
        print_warning "wrote $(_gui_unit_path) but 'systemctl --user enable --now' failed"
        return 0
    fi
    # Without lingering, a user unit only runs while a login session exists.
    if command -v loginctl >/dev/null 2>&1; then
        if loginctl show-user "$(id -un)" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
            print_info "user lingering already on — the GUI comes up at boot"
        elif loginctl enable-linger "$(id -un)" 2>/dev/null; then
            print_success "user lingering enabled — the GUI comes up at boot without a login"
        else
            print_info "run 'sudo loginctl enable-linger $(id -un)' so the GUI starts at boot, not just at login"
        fi
    fi
}

gui_autostart_disable() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        launchctl unload "$(_gui_plist_path)" 2>/dev/null || true
        rm -f "$(_gui_plist_path)"
        print_success "GUI autostart disabled"
        return 0
    fi
    if _gui_systemd_available; then
        systemctl --user disable --now "${GUI_UNIT_NAME}.service" 2>/dev/null || true
    fi
    rm -f "$(_gui_unit_path)"
    _gui_systemd_available && systemctl --user daemon-reload 2>/dev/null || true
    print_success "GUI autostart disabled"
}

gui_autostart_status() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if [[ -f "$(_gui_plist_path)" ]]; then
            print_info "autostart: LaunchAgent installed"
        else
            print_info "autostart: off (enable with: fleetmux gui autostart)"
        fi
        return 0
    fi
    if [[ -f "$(_gui_unit_path)" ]]; then
        local state="installed"
        if _gui_systemd_available; then
            state=$(systemctl --user is-enabled "${GUI_UNIT_NAME}.service" 2>/dev/null || echo "installed")
        fi
        print_info "autostart: systemd user unit ${state}"
    else
        print_info "autostart: off (enable with: fleetmux gui autostart)"
    fi
}
