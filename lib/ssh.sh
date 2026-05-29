#!/usr/bin/env bash
# shellcheck disable=SC1091
# SSH — direct command execution on any session's machine
# No Claude session needed — just runs a shell command and returns output
[[ -n "${_AIOS_SSH_LOADED:-}" ]] && return 0; _AIOS_SSH_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

# Execute a command in a session's directory
# Local: cd to path and run
# Remote: SSH and run
direct_exec() {
    local name="$1"
    shift
    local command="$*"

    if ! registry_session_exists "$name"; then
        echo "Error: Session '$name' not found in registry" >&2
        return 1
    fi

    if [[ -z "$command" ]]; then
        echo "Error: No command specified" >&2
        return 1
    fi

    local type path host
    type=$(registry_get_field "$name" "type")
    path=$(registry_get_field "$name" "path")
    host=$(registry_get_field "$name" "host")

    record_task "$name" "$command" "ssh" "dispatched"
    local start_time exit_code=0 output
    start_time=$(date +%s)

    case "$type" in
        local|utility)
            output=$( (cd "$path" && eval "$command") 2>&1) || exit_code=$?
            ;;
        remote)
            # shellcheck disable=SC2029
            output=$(ssh "$host" "cd '${path}' && ${command}" 2>&1) || exit_code=$?
            ;;
    esac

    echo "$output"

    local end_time duration_s status
    end_time=$(date +%s)
    duration_s=$((end_time - start_time))
    if [[ $exit_code -eq 0 ]]; then
        status="completed"
    else
        status="failed"
    fi
    update_last_task "$name" "$status" "$duration_s" "$output"

    return $exit_code
}

# Interactive SSH shell into a session's directory
direct_shell() {
    local name="$1"

    if ! registry_session_exists "$name"; then
        echo "Error: Session '$name' not found in registry" >&2
        return 1
    fi

    local type path host
    type=$(registry_get_field "$name" "type")
    path=$(registry_get_field "$name" "path")
    host=$(registry_get_field "$name" "host")

    case "$type" in
        local|utility)
            echo "Session '$name' is local. Path: $path"
            ;;
        remote)
            echo "Connecting to $host..."
            ssh -t "$host" "cd '${path}' && exec bash -l"
            ;;
    esac
}
