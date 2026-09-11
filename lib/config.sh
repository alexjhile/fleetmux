#!/usr/bin/env bash
# AIOS Configuration — constants, paths, env loading
[[ -n "${_AIOS_CONFIG_LOADED:-}" ]] && return 0; _AIOS_CONFIG_LOADED=1

AIOS_DIR="${AIOS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck disable=SC2034
AIOS_TMUX_SESSION="aios"

# Use explicit tmux socket when AIOS_TMUX_SOCKET is set (LaunchAgent compatibility)
if [[ -z "${AIOS_TMUX_SOCKET:-}" ]]; then
    _tmux_socket="/tmp/tmux-$(id -u)/default"
    [[ -S "$_tmux_socket" ]] && AIOS_TMUX_SOCKET="$_tmux_socket"
fi
# shellcheck disable=SC2034
TMUX_CMD="${AIOS_TMUX_SOCKET:+tmux -S "$AIOS_TMUX_SOCKET"}"
TMUX_CMD="${TMUX_CMD:-tmux}"
SESSIONS_FILE="${SESSIONS_FILE:-${AIOS_DIR}/sessions.json}"
TASKS_FILE="${TASKS_FILE:-${AIOS_DIR}/tasks.json}"
TASKS_MAX=500
# Directory holding optional env files (e.g. hosts.env) and account tokens.
SECRETS_DIR="${AIOS_SECRETS_DIR:-${HOME}/.config/fleetmux/secrets}"
# Claude binary — ~/.local/bin may not be in tmux PATH
# shellcheck disable=SC2034
CLAUDE_BIN="${CLAUDE_BIN:-${HOME}/.local/bin/claude}"
LOGS_DIR="${LOGS_DIR:-${AIOS_DIR}/logs}"
# Parent directory that holds your local project checkouts. Used only to
# shorten paths in status/health output and to detect the "home base" dir.
# shellcheck disable=SC2034
CLAUDE_CODE_ROOT="${AIOS_CLAUDE_CODE_ROOT:-${HOME}/code}"

# Ensure logs directory exists
mkdir -p "$LOGS_DIR" 2>/dev/null

# Ensure tasks file exists
[[ -f "$TASKS_FILE" ]] || echo '[]' > "$TASKS_FILE"

# Optionally load host/env vars (e.g. VPS IPs) from hosts.env if present.
if [[ -f "${SECRETS_DIR}/hosts.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${SECRETS_DIR}/hosts.env"
    set +a
fi

# ─── File Locking ──────────────────────────────────────────────────────────

TASKS_LOCK="${TASKS_FILE}.lock"

# Acquire a file lock (mkdir-based, works on NFS and is atomic)
# Usage: acquire_lock <timeout_seconds>
acquire_lock() {
    local timeout="${1:-5}"
    local waited=0
    while ! mkdir "$TASKS_LOCK" 2>/dev/null; do
        if [[ $waited -ge $timeout ]]; then
            # Stale lock — force remove
            rm -rf "$TASKS_LOCK"
            mkdir "$TASKS_LOCK" 2>/dev/null || return 1
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
}

# Release the file lock
release_lock() {
    rm -rf "$TASKS_LOCK" 2>/dev/null
}

# ─── Task Recording ─────────────────────────────────────────────────────────

# Record a task to tasks.json
# Usage: record_task <session> <task> <mode> <status> [output_preview]
record_task() {
    local session="$1"
    local task="$2"
    local mode="$3"       # run|ssh|exec
    local status="$4"     # dispatched|completed|failed
    local output_preview="${5:-}"
    local dispatched_at completed_at duration_s

    dispatched_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    completed_at=""
    duration_s=""

    if [[ "$status" == "completed" || "$status" == "failed" ]]; then
        completed_at="$dispatched_at"
    fi

    local task_id
    task_id="t_$(date +%s)_${session}"

    # Truncate output preview to 200 chars
    if [[ ${#output_preview} -gt 200 ]]; then
        output_preview="${output_preview:0:200}..."
    fi

    local new_task
    new_task=$(jq -n \
        --arg id "$task_id" \
        --arg session "$session" \
        --arg task "$task" \
        --arg mode "$mode" \
        --arg status "$status" \
        --arg dispatched_at "$dispatched_at" \
        --arg completed_at "$completed_at" \
        --arg duration_s "$duration_s" \
        --arg output_preview "$output_preview" \
        --arg source "cli" \
        '{id: $id, session: $session, task: $task, mode: $mode, status: $status, dispatched_at: $dispatched_at, completed_at: $completed_at, duration_s: $duration_s, output_preview: $output_preview, source: $source}')

    # Prepend to tasks.json and cap at TASKS_MAX (atomic with lock)
    acquire_lock 5
    local tmp_file="${TASKS_FILE}.tmp"
    jq --argjson new_task "$new_task" --argjson max "$TASKS_MAX" \
        '[$new_task] + . | .[:$max]' "$TASKS_FILE" > "$tmp_file" && mv "$tmp_file" "$TASKS_FILE"
    release_lock
}

# Update the most recent task for a session with completion info
# Usage: update_last_task <session> <status> <duration_s> [output_preview]
update_last_task() {
    local session="$1"
    local status="$2"
    local duration_s="$3"
    local output_preview="${4:-}"
    local completed_at

    completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Truncate output preview
    if [[ ${#output_preview} -gt 200 ]]; then
        output_preview="${output_preview:0:200}..."
    fi

    acquire_lock 5
    local tmp_file="${TASKS_FILE}.tmp"
    jq --arg session "$session" \
       --arg status "$status" \
       --arg completed_at "$completed_at" \
       --arg duration_s "$duration_s" \
       --arg output_preview "$output_preview" \
       '(first(to_entries[] | select(.value.session == $session)).key) as $idx |
        if $idx != null then
            .[$idx].status = $status |
            .[$idx].completed_at = $completed_at |
            .[$idx].duration_s = $duration_s |
            .[$idx].output_preview = $output_preview
        else . end' "$TASKS_FILE" > "$tmp_file" && mv "$tmp_file" "$TASKS_FILE"
    release_lock

    # Auto-sync this session's brain state (lightweight — local only, no SSH)
    if type brain_sync_local &>/dev/null; then
        local session_type session_path
        session_type=$(jq -r --arg s "$session" '.[] | select(.name == $s) | .type' "$SESSIONS_FILE" 2>/dev/null)
        session_path=$(jq -r --arg s "$session" '.[] | select(.name == $s) | .path' "$SESSIONS_FILE" 2>/dev/null)
        if [[ "$session_type" == "local" || "$session_type" == "utility" ]]; then
            brain_sync_local "$session" "$session_path" 2>/dev/null || true
        fi
    fi
}
