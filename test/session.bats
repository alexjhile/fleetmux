#!/usr/bin/env bats
# Tests for session.sh — the claude launch command session_start builds

load test_helper

setup() {
    common_setup
    unset _AIOS_STATUS_LOADED _AIOS_SESSION_LOADED
    source "${LIB_DIR}/session.sh"

    # Record the tmux command instead of touching a real server.
    TMUX_CALLS="${TEST_DIR}/tmux_calls"
    tmux_stub() { printf '%s\n' "$*" >> "$TMUX_CALLS"; }
    TMUX_CMD=tmux_stub
    tmux_window_exists() { return 1; }
    ensure_tmux_session() { :; }
}

teardown() {
    common_teardown
}

@test "session_start resumes the pinned conversation, creating it on first start" {
    session_start "testlocal"

    local id
    id=$(registry_get_field "testlocal" "conversation_id")
    [[ -n "$id" ]]
    grep -q -- "--resume ${id} --dangerously-skip-permissions || .*--session-id ${id} --dangerously-skip-permissions" "$TMUX_CALLS"
}

@test "session_start reuses the same conversation on every start" {
    session_start "testlocal"
    local id
    id=$(registry_get_field "testlocal" "conversation_id")

    : > "$TMUX_CALLS"
    session_start "testlocal"
    grep -q -- "--resume ${id} " "$TMUX_CALLS"
}

@test "session_start drops --continue from older registries" {
    registry_set_field "testlocal" "claude_flags" "--continue --dangerously-skip-permissions"
    session_start "testlocal"

    run grep -q -- "--continue" "$TMUX_CALLS"
    [[ "$status" -ne 0 ]]
}

@test "session_start pins remote sessions too" {
    session_start "testremote"

    local id
    id=$(registry_get_field "testremote" "conversation_id")
    grep -q -- "--resume ${id} .*--session-id ${id}" "$TMUX_CALLS"
}
