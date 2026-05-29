#!/usr/bin/env bash
# shellcheck disable=SC1091
# Status detection — check tmux pane state + git info
[[ -n "${_AIOS_STATUS_LOADED:-}" ]] && return 0; _AIOS_STATUS_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# Check if the fleetmux tmux session exists
tmux_session_exists() {
    $TMUX_CMD has-session -t "$AIOS_TMUX_SESSION" 2>/dev/null
}

# Check if a specific window exists in the fleetmux session
tmux_window_exists() {
    local name="$1"
    $TMUX_CMD list-windows -t "$AIOS_TMUX_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$name"
}

# Get the state of a session by reading tmux pane content
# Returns: running, idle, stopped
detect_session_state() {
    local name="$1"

    if ! tmux_window_exists "$name"; then
        echo "stopped"
        return
    fi

    # Capture last 15 lines of the pane
    local pane_content
    pane_content=$($TMUX_CMD capture-pane -t "${AIOS_TMUX_SESSION}:${name}" -p -S -15 2>/dev/null)

    if [[ -z "$pane_content" ]]; then
        echo "stopped"
        return
    fi

    # Check for processing/running patterns (spinners, active operations)
    if echo "$pane_content" | grep -qE '⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏|Running|Thinking|Reading|Writing|Searching|Executing'; then
        echo "running"
        return
    fi

    # Check for Claude Code input prompt (idle) — the > prompt or bash $
    if echo "$pane_content" | grep -qE '^\s*>\s*$|waiting for input|^\$\s*$'; then
        echo "idle"
        return
    fi

    # Default to idle if window exists but state unclear
    echo "idle"
}

# Get git status for a local session
get_git_info() {
    local path="$1"

    if [[ ! -d "${path}/.git" ]]; then
        echo "-"
        return
    fi

    local branch dirty
    branch=$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)
    dirty=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$dirty" -gt 0 ]]; then
        echo "${branch} (${dirty} dirty)"
    else
        echo "${branch}"
    fi
}

# Get last task for a session from tasks.json
# Returns: "task description (Xm ago)" or "-"
get_last_task() {
    local session="$1"

    if [[ ! -f "$TASKS_FILE" ]]; then
        echo "-"
        return
    fi

    local result
    result=$(jq -r --arg s "$session" \
        'first(.[] | select(.session == $s)) | "\(.task)|\(.dispatched_at)"' \
        "$TASKS_FILE" 2>/dev/null)

    if [[ -z "$result" || "$result" == "null" ]]; then
        echo "-"
        return
    fi

    local task dispatched_at
    task=$(echo "$result" | cut -d'|' -f1)
    dispatched_at=$(echo "$result" | cut -d'|' -f2)

    # Truncate task to 25 chars
    if [[ ${#task} -gt 25 ]]; then
        task="${task:0:22}..."
    fi

    # Calculate time ago
    local task_ts now_ts diff_s ago
    task_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$dispatched_at" "+%s" 2>/dev/null || echo "0")
    now_ts=$(date +%s)

    if [[ "$task_ts" -gt 0 ]]; then
        diff_s=$((now_ts - task_ts))
        if [[ $diff_s -lt 60 ]]; then
            ago="just now"
        elif [[ $diff_s -lt 3600 ]]; then
            ago="$((diff_s / 60))m ago"
        elif [[ $diff_s -lt 86400 ]]; then
            ago="$((diff_s / 3600))h ago"
        else
            ago="$((diff_s / 86400))d ago"
        fi
    else
        ago=""
    fi

    if [[ -n "$ago" ]]; then
        echo "${task} (${ago})"
    else
        echo "${task}"
    fi
}

# Check if a session has unsynced direct work
# Compares Claude memory mtime to last AIOS task time
# Returns: "fresh" (direct work detected), "synced", or "unknown"
check_direct_work() {
    local session="$1"
    local type="$2"
    local path="$3"
    local host="${4:-}"

    # Get last AIOS task time for this session
    local last_task_ts=0
    if [[ -f "$TASKS_FILE" ]]; then
        local last_task_at
        last_task_at=$(jq -r --arg s "$session" \
            'first(.[] | select(.session == $s)).dispatched_at // empty' \
            "$TASKS_FILE" 2>/dev/null)
        if [[ -n "$last_task_at" ]]; then
            last_task_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_task_at" "+%s" 2>/dev/null || echo "0")
        fi
    fi

    # Get memory file mtime
    local memory_ts=0
    case "$type" in
        local|utility)
            local encoded
            encoded=$(echo "$path" | sed 's|/$||' | sed 's|/|-|g' | sed 's|_|-|g')
            local memory_file="$HOME/.claude/projects/${encoded}/memory/MEMORY.md"
            if [[ -f "$memory_file" ]]; then
                memory_ts=$(stat -f "%m" "$memory_file" 2>/dev/null || echo "0")
            fi
            ;;
        remote)
            # Skip VPS check here — too slow for status. Handled by fleetmux sync.
            echo "unknown"
            return
            ;;
    esac

    if [[ "$memory_ts" -gt "$last_task_ts" && "$memory_ts" -gt 0 ]]; then
        echo "fresh"
    elif [[ "$memory_ts" -gt 0 ]]; then
        echo "synced"
    else
        echo "unknown"
    fi
}

# Get display target — short path or host IP
get_display_target() {
    local type="$1"
    local path="$2"
    local host="$3"

    case "$type" in
        remote)
            local ip
            ip="${host##*@}"
            echo "remote ${ip}"
            ;;
        local|utility)
            if [[ "$path" == "$CLAUDE_CODE_ROOT" ]]; then
                echo "(home)"
            else
                echo "${path#"${CLAUDE_CODE_ROOT}/"}"
            fi
            ;;
    esac
}
