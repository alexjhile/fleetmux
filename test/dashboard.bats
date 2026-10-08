#!/usr/bin/env bats
# Tests for dashboard.sh — reading a session's model from its conversation log

load test_helper

setup() {
    common_setup
    unset _FLEETMUX_DASHBOARD_LOADED _FLEETMUX_STATUS_LOADED
    source "${LIB_DIR}/dashboard.sh"

    export CLAUDE_CODE_PROJECTS="${TEST_DIR}/claude-projects"
    CONV="11111111-2222-4333-8444-555555555555"
    registry_set_field "testlocal" "conversation_id" "$CONV"
    # testlocal's path is /tmp/fleetmux-test-local; "/", "_" and "." become "-".
    LOG_DIR="${CLAUDE_CODE_PROJECTS}/-tmp-fleetmux-test-local"
    mkdir -p "$LOG_DIR"
    LOG="${LOG_DIR}/${CONV}.jsonl"
}

teardown() {
    common_teardown
}

turn()      { printf '{"type":"assistant","message":{"model":"%s","content":[]}}\n' "$1" >> "$LOG"; }
sidechain() { printf '{"type":"assistant","isSidechain":true,"message":{"model":"%s","content":[]}}\n' "$1" >> "$LOG"; }
switch_to() { printf '{"type":"user","message":{"content":"<local-command-stdout>Set model to `%s` and saved as your default for new sessions</local-command-stdout>"}}\n' "$1" >> "$LOG"; }

@test "model comes from the last turn in the conversation log" {
    turn "claude-opus-5"
    [[ "$(_dash_session_model_log testlocal)" == "Opus 5" ]]
}

@test "minor versions and trailing dates are normalised" {
    turn "claude-haiku-4-5-20251001"
    [[ "$(_dash_session_model_log testlocal)" == "Haiku 4.5" ]]
}

@test "a /model switch shows immediately, before any turn runs on it" {
    turn "claude-opus-5"
    switch_to "Opus 5.5"
    [[ "$(_dash_session_model_log testlocal)" == "Opus 5.5" ]]
}

@test "a later turn overrides an earlier /model switch" {
    switch_to "Opus 5.5"
    turn "claude-sonnet-5"
    [[ "$(_dash_session_model_log testlocal)" == "Sonnet 5" ]]
}

@test "text that merely quotes a model switch is not a switch" {
    turn "claude-opus-5"
    # A tool result echoing the phrase: array content, not a local command.
    printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"<local-command-stdout>Set model to `Opus 5.5` and saved"}]}}\n' >> "$LOG"
    [[ "$(_dash_session_model_log testlocal)" == "Opus 5" ]]
}

@test "subagent turns do not change the reported model" {
    turn "claude-opus-5"
    sidechain "claude-haiku-4-5-20251001"
    [[ "$(_dash_session_model_log testlocal)" == "Opus 5" ]]
}

@test "no log means no answer rather than a guess" {
    rm -rf "$LOG_DIR"
    [[ -z "$(_dash_session_model_log testlocal)" ]]
}
