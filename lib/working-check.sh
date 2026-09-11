#!/usr/bin/env bash
# WORKING.md freshness check
#
# Each session maintains a WORKING.md at the root of its working directory
# with current focus, in-flight streams, blockers, and state proof. This
# replaces auto-/compact as the durability mechanism — sessions /clear and
# rehydrate from WORKING.md instead of ballooning context.
#
# This script:
#   - reports staleness of WORKING.md per session
#   - blocks /clear if WORKING.md is stale (must touch within last N min while active)
#   - prints the bootstrap-after-clear text for a session
#
# Usage:
#   fleetmux working-check <session>      — check freshness, exit 1 if stale
#   fleetmux working-check --all          — check all running sessions
#   fleetmux working-bootstrap <session>  — print bootstrap text to paste after /clear

[[ -n "${_AIOS_WORKING_CHECK_LOADED:-}" ]] && return 0
_AIOS_WORKING_CHECK_LOADED=1

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/platform.sh"

AIOS_ROOT="${AIOS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SESSIONS_JSON="${SESSIONS_FILE:-${AIOS_ROOT}/sessions.json}"

# Max minutes WORKING.md can be untouched before /clear is blocked.
WORKING_STALE_MIN="${WORKING_STALE_MIN:-30}"

# Resolve WORKING.md path for a session by reading sessions.json target.
working_path_for() {
    local session="$1"
    local sess_type sess_path
    sess_type=$(jq -r --arg n "$session" '.[] | select(.name==$n) | .type // empty' "$SESSIONS_JSON" 2>/dev/null)
    sess_path=$(jq -r --arg n "$session" '.[] | select(.name==$n) | .path // empty' "$SESSIONS_JSON" 2>/dev/null)

    [[ "$sess_type" != "local" ]] && return 2  # remote not yet supported
    [[ -z "$sess_path" || "$sess_path" == "null" ]] && {
        # The controller session (AIOS_CONTROLLER_SESSION) may have a null
        # path — fall back to the projects root (CLAUDE_CODE_ROOT) for its
        # WORKING.md.
        if [[ -n "${AIOS_CONTROLLER_SESSION:-}" && "$session" == "${AIOS_CONTROLLER_SESSION}" ]]; then
            echo "${CLAUDE_CODE_ROOT:-$HOME}/WORKING.md"
            return 0
        fi
        return 1
    }

    # Path is absolute already.
    if [[ -d "$sess_path" ]]; then
        echo "$sess_path/WORKING.md"
        return 0
    fi
    return 1
}

working_check() {
    local session="$1"
    local path
    path=$(working_path_for "$session") || {
        echo "no WORKING.md path for session: $session" >&2
        return 2
    }

    if [[ ! -f "$path" ]]; then
        echo "MISSING $session — $path"
        return 1
    fi

    local now mtime age_min
    now=$(date +%s)
    mtime=$(file_mtime "$path")
    age_min=$(( (now - mtime) / 60 ))

    if [[ "$age_min" -gt "$WORKING_STALE_MIN" ]]; then
        echo "STALE $session — ${age_min}m since update (limit: ${WORKING_STALE_MIN}m) — $path"
        return 1
    fi

    echo "FRESH $session — ${age_min}m ago — $path"
    return 0
}

working_check_all() {
    local sessions
    sessions=$(jq -r '.[] | select(.type=="local") | .name' "$SESSIONS_JSON" 2>/dev/null)
    local rc=0
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        # Only check sessions with WORKING.md created.
        local path
        path=$(working_path_for "$name") || continue
        [[ -f "$path" ]] || continue
        working_check "$name" || rc=1
    done <<< "$sessions"
    return $rc
}

# Print the bootstrap prompt to paste into a session immediately after /clear.
working_bootstrap() {
    local session="$1"
    local path
    path=$(working_path_for "$session") || {
        echo "no WORKING.md path for session: $session" >&2
        return 2
    }

    cat <<EOF
You just /cleared. Rehydrate context now:

1. Read CLAUDE.md (your role + rules)
2. Read $path (current state — what was in flight, blockers, decisions)
3. Read MEMORY.md index in your memory dir, then any topic file referenced by WORKING.md
4. Run \`git status\` and \`git log --oneline -10\` in your cwd
5. Run \`tmux capture-pane -t aios:<dependent-session> -p | tail -20\` for any dependent sessions named in WORKING.md "in flight"

Then continue from WORKING.md "CURRENT FOCUS" + "IN FLIGHT". Update WORKING.md after each meaningful action — that's the durability contract.

Do NOT ask "what was I doing?" — WORKING.md tells you.
EOF
}

# CLI surface
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        check)
            shift
            if [[ "${1:-}" == "--all" ]]; then
                working_check_all
            elif [[ -n "${1:-}" ]]; then
                working_check "$1"
            else
                echo "Usage: $0 check {<session>|--all}"
                exit 2
            fi
            ;;
        bootstrap)
            shift
            [[ -z "${1:-}" ]] && { echo "Usage: $0 bootstrap <session>"; exit 2; }
            working_bootstrap "$1"
            ;;
        *)
            echo "Usage: $0 {check <session>|check --all|bootstrap <session>}"
            exit 2
            ;;
    esac
fi
