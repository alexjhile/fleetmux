#!/usr/bin/env bash
# shellcheck disable=SC1091
# Session lifecycle — start/stop/attach via tmux
[[ -n "${_FLEETMUX_SESSION_LOADED:-}" ]] && return 0; _FLEETMUX_SESSION_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/status.sh"

# Ensure the fleetmux tmux session exists
ensure_tmux_session() {
    if ! tmux_session_exists; then
        $TMUX_CMD new-session -d -s "$FLEETMUX_TMUX_SESSION" -n "_control"
    fi
}

# Start a session
session_start() {
    local name="$1"

    if ! registry_session_exists "$name"; then
        echo "Error: Session '$name' not found in registry" >&2
        return 1
    fi

    if tmux_window_exists "$name"; then
        echo "Session '$name' is already running"
        return 0
    fi

    ensure_tmux_session

    local type path host flags account conv wrapper_local wrapper_remote
    type=$(registry_get_field "$name" "type")
    path=$(registry_get_field "$name" "path")
    host=$(registry_get_field "$name" "host")
    flags=$(registry_get_field "$name" "claude_flags")
    account=$(registry_get_field "$name" "account")
    # Every start resumes the session's own pinned conversation; the first
    # start (--resume finds nothing) creates it under that id instead.
    # --continue would clash with --resume, so drop it from older registries.
    conv=$(registry_conversation_id "$name") || {
        echo "Error: could not save a conversation id for '$name'" >&2
        return 1
    }
    flags="${flags//--continue/}"
    # Wrapper paths — local $HOME, and ~/.fleetmux-claude on remote hosts (the
    # remote shell expands ~ to the remote user's home). Override the remote
    # path with FLEETMUX_REMOTE_WRAPPER if your hosts install it elsewhere.
    wrapper_local="${HOME}/.fleetmux-claude"
    wrapper_remote="${FLEETMUX_REMOTE_WRAPPER:-~/.fleetmux-claude}"

    case "$type" in
        local|utility)
            # Launch claude via ~/.fleetmux-claude wrapper with FLEETMUX_ACCOUNT set
            # so the wrapper can export the right OAuth token. Empty account
            # falls through to Claude Code's own stored login.
            $TMUX_CMD new-window -t "${FLEETMUX_TMUX_SESSION}:" -n "$name" \
                "cd '${path}' && { FLEETMUX_ACCOUNT='${account}' '${wrapper_local}' --resume ${conv} ${flags} || FLEETMUX_ACCOUNT='${account}' '${wrapper_local}' --session-id ${conv} ${flags}; }; bash"
            ;;
        remote)
            # SSH to the host, reconnect to existing tmux session or create one.
            # Launches claude via the ~/.fleetmux-claude wrapper which reads
            # FLEETMUX_ACCOUNT and exports CLAUDE_CODE_OAUTH_TOKEN from the matching
            # ~/.fleetmux-accounts/<name>.token file.
            $TMUX_CMD new-window -t "${FLEETMUX_TMUX_SESSION}:" -n "$name" \
                "ssh -t ${host} \"tmux has-session -t ${name} 2>/dev/null && tmux attach -t ${name} || tmux new-session -s ${name} -c '${path}' 'FLEETMUX_ACCOUNT=${account} ${wrapper_remote} --resume ${conv} ${flags} || FLEETMUX_ACCOUNT=${account} ${wrapper_remote} --session-id ${conv} ${flags}; bash'\""
            ;;
    esac

    echo "Started session '$name'"
}

# Stop a session
session_stop() {
    local name="$1"

    if ! tmux_window_exists "$name"; then
        echo "Session '$name' is not running"
        return 0
    fi

    # For remote sessions, kill the remote tmux session first
    # Otherwise the stale remote session persists with a dead Claude process
    local type host
    type=$(registry_get_field "$name" "type")
    if [[ "$type" == "remote" ]]; then
        host=$(registry_get_field "$name" "host")
        ssh -o ConnectTimeout=5 "$host" "tmux kill-session -t '$name' 2>/dev/null" &>/dev/null &
    fi

    $TMUX_CMD kill-window -t "${FLEETMUX_TMUX_SESSION}:${name}" 2>/dev/null
    echo "Stopped session '$name'"
}

# Attach to (switch to) a session window
session_attach() {
    local name="$1"

    if ! tmux_window_exists "$name"; then
        echo "Error: Session '$name' is not running. Start it first with: fleetmux start $name" >&2
        return 1
    fi

    $TMUX_CMD select-window -t "${FLEETMUX_TMUX_SESSION}:${name}"
}

# Start all sessions with autostart=true (or all with --all flag)
session_start_all() {
    local all_flag=false
    [[ "${1:-}" == "--all" ]] && all_flag=true

    local names
    if $all_flag; then
        names=$(jq -r '.[].name' "$SESSIONS_FILE")
    else
        names=$(jq -r '.[] | select(.autostart == true) | .name' "$SESSIONS_FILE")
        if [[ -z "$names" ]]; then
            echo "No sessions have autostart enabled. Use 'fleetmux startall --all' to start everything."
            return 0
        fi
    fi

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        session_start "$name"
    done <<< "$names"
}

# Stop all running sessions
session_stop_all() {
    if ! tmux_session_exists; then
        echo "No fleetmux tmux session running"
        return 0
    fi

    local windows
    windows=$($TMUX_CMD list-windows -t "$FLEETMUX_TMUX_SESSION" -F '#{window_name}' 2>/dev/null)

    while IFS= read -r name; do
        [[ -z "$name" || "$name" == "_control" ]] && continue
        session_stop "$name"
    done <<< "$windows"

    # Kill the control window and session
    $TMUX_CMD kill-session -t "$FLEETMUX_TMUX_SESSION" 2>/dev/null
    echo "All sessions stopped"
}
