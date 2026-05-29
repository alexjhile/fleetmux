#!/usr/bin/env bash
# shellcheck disable=SC1091
# Dispatch — send tasks to sessions (interactive or headless)
[[ -n "${_AIOS_DISPATCH_LOADED:-}" ]] && return 0; _AIOS_DISPATCH_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/status.sh"

# Interactive dispatch — send keystrokes to a running session
dispatch_interactive() {
    local name="$1"
    local task="$2"

    if ! tmux_window_exists "$name"; then
        echo "Error: Session '$name' is not running. Start it first with: fleetmux start $name" >&2
        return 1
    fi

    local state
    state=$(detect_session_state "$name")

    if [[ "$state" == "running" ]]; then
        echo "Warning: Session '$name' appears busy (state: running). Sending task anyway..." >&2
    fi

    # Send the task text followed by Enter
    $TMUX_CMD send-keys -t "${AIOS_TMUX_SESSION}:${name}" "$task" Enter

    record_task "$name" "$task" "run" "dispatched"
    echo "Dispatched to '$name': $task"
}

# Interactive dispatch with wait — sends task then polls until completion
# Returns the output that appeared after the task was sent
dispatch_interactive_wait() {
    local name="$1"
    local task="$2"
    local timeout="${3:-300}"  # Default 5 min timeout
    local poll_interval=3

    if ! tmux_window_exists "$name"; then
        echo "Error: Session '$name' is not running. Start it first with: fleetmux start $name" >&2
        return 1
    fi

    # Send the task
    $TMUX_CMD send-keys -t "${AIOS_TMUX_SESSION}:${name}" "$task" Enter
    record_task "$name" "$task" "run" "dispatched"
    echo "Dispatched to '$name': $task"
    echo "Waiting for completion (timeout: ${timeout}s)..."

    # Wait a moment for processing to start
    sleep 2

    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local state
        state=$(detect_session_state "$name")

        # If we see idle state after sending, task is complete
        if [[ "$state" == "idle" ]]; then
            echo ""
            echo "--- Output from '$name' ---"
            local output
            output=$($TMUX_CMD capture-pane -t "${AIOS_TMUX_SESSION}:${name}" -p -S -100 2>/dev/null)
            echo "$output"
            echo "--- End output ---"
            update_last_task "$name" "completed" "$elapsed" "$output"
            return 0
        fi

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
        printf "\r  Waiting... %ds / %ds (state: %s)" "$elapsed" "$timeout" "$state"
    done

    echo ""
    echo "Timeout after ${timeout}s. Session may still be working."
    echo "Check with: fleetmux logs $name"
    update_last_task "$name" "failed" "$timeout" "Timeout after ${timeout}s"
    return 1
}

# Headless dispatch — run claude -p in session directory
dispatch_headless() {
    local name="$1"
    local task="$2"

    if ! registry_session_exists "$name"; then
        echo "Error: Session '$name' not found in registry" >&2
        return 1
    fi

    local type path host flags log_file
    type=$(registry_get_field "$name" "type")
    path=$(registry_get_field "$name" "path")
    host=$(registry_get_field "$name" "host")
    flags=$(registry_get_field "$name" "claude_flags")
    log_file="${LOGS_DIR}/${name}_$(date +%Y%m%d_%H%M%S).log"

    echo "Executing headless task on '$name'..."
    echo "Log: $log_file"

    record_task "$name" "$task" "exec" "dispatched"
    local start_time
    start_time=$(date +%s)
    local exit_code=0

    case "$type" in
        local|utility)
            # shellcheck disable=SC2086
            (cd "$path" && claude -p "$task" --output-format json ${flags} 2>&1) | tee "$log_file" || exit_code=$?
            ;;
        remote)
            # shellcheck disable=SC2029,SC2001
            ssh "$host" "cd '${path}' && claude -p '$(echo "$task" | sed "s/'/'\\\\''/g")' --output-format json ${flags} 2>&1" | tee "$log_file" || exit_code=$?
            ;;
    esac

    local end_time duration_s output_preview status
    end_time=$(date +%s)
    duration_s=$((end_time - start_time))
    output_preview=$(head -c 200 "$log_file" 2>/dev/null || echo "")
    if [[ $exit_code -eq 0 ]]; then
        status="completed"
    else
        status="failed"
    fi
    update_last_task "$name" "$status" "$duration_s" "$output_preview"
}

# Get recent tmux output from a session
dispatch_logs() {
    local name="$1"
    local lines="${2:-50}"

    if tmux_window_exists "$name"; then
        $TMUX_CMD capture-pane -t "${AIOS_TMUX_SESSION}:${name}" -p -S "-${lines}"
        return
    fi

    # Session not running — try to show last headless log
    local last_log
    last_log=$(find "$LOGS_DIR" -maxdepth 1 -name "${name}_*.log" -print 2>/dev/null | sort -r | head -1)
    if [[ -n "$last_log" ]]; then
        echo "Session stopped. Last headless log:"
        cat "$last_log"
    else
        echo "Session '$name' is not running and no logs found."
    fi
}
