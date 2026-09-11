#!/usr/bin/env bats
# Tests for config.sh — task recording and configuration

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "tasks file exists and is valid JSON" {
    [[ -f "$TASKS_FILE" ]]
    jq empty "$TASKS_FILE"
}

@test "record_task adds entry to tasks.json" {
    record_task "testlocal" "run tests" "ssh" "dispatched"

    local count
    count=$(jq 'length' "$TASKS_FILE")
    [[ "$count" == "1" ]]
}

@test "record_task preserves session name" {
    record_task "testlocal" "run tests" "ssh" "dispatched"

    local session
    session=$(jq -r '.[0].session' "$TASKS_FILE")
    [[ "$session" == "testlocal" ]]
}

@test "record_task preserves task text" {
    record_task "testlocal" "run the full test suite" "exec" "dispatched"

    local task
    task=$(jq -r '.[0].task' "$TASKS_FILE")
    [[ "$task" == "run the full test suite" ]]
}

@test "record_task caps at TASKS_MAX" {
    export TASKS_MAX=3

    record_task "s1" "task1" "ssh" "completed"
    record_task "s2" "task2" "ssh" "completed"
    record_task "s3" "task3" "ssh" "completed"
    record_task "s4" "task4" "ssh" "completed"

    local count
    count=$(jq 'length' "$TASKS_FILE")
    [[ "$count" == "3" ]]

    # Most recent task should be first
    local first
    first=$(jq -r '.[0].task' "$TASKS_FILE")
    [[ "$first" == "task4" ]]
}

@test "update_last_task updates status and duration" {
    record_task "testlocal" "run tests" "ssh" "dispatched"
    update_last_task "testlocal" "completed" "5" "all tests passed"

    local status duration
    status=$(jq -r '.[0].status' "$TASKS_FILE")
    duration=$(jq -r '.[0].duration_s' "$TASKS_FILE")
    [[ "$status" == "completed" ]]
    [[ "$duration" == "5" ]]
}

@test "update_last_task sets completed_at" {
    record_task "testlocal" "run tests" "ssh" "dispatched"
    update_last_task "testlocal" "completed" "3" ""

    local completed_at
    completed_at=$(jq -r '.[0].completed_at' "$TASKS_FILE")
    [[ -n "$completed_at" ]]
    [[ "$completed_at" != "null" ]]
    [[ "$completed_at" != "" ]]
}

@test "record_task truncates long output preview" {
    local long_output
    long_output=$(printf 'x%.0s' {1..300})

    record_task "testlocal" "long output" "ssh" "completed" "$long_output"

    local preview_len
    preview_len=$(jq -r '.[0].output_preview | length' "$TASKS_FILE")
    [[ "$preview_len" -le 210 ]]
}

# Source config.sh in a clean shell with only the given env on top, and
# print the resolved FLEETMUX_DIR|SECRETS_DIR.
config_value() {
    env -u FLEETMUX_DIR -u FLEETMUX_SECRETS_DIR -u SESSIONS_FILE -u TASKS_FILE -u LOGS_DIR \
        -u _FLEETMUX_CONFIG_LOADED -u _FLEETMUX_PLATFORM_LOADED "$@" \
        bash -c 'source "$LIB/config.sh"; printf "%s|%s\n" "$FLEETMUX_DIR" "$SECRETS_DIR"'
}

@test "legacy AIOS_* overrides still apply when FLEETMUX_* is unset" {
    mkdir -p "${TEST_DIR}/legacy"
    run config_value LIB="$LIB_DIR" AIOS_DIR="${TEST_DIR}/legacy" AIOS_SECRETS_DIR="${TEST_DIR}/secrets"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "${TEST_DIR}/legacy|${TEST_DIR}/secrets" ]]
}

@test "FLEETMUX_* overrides win over legacy AIOS_* ones" {
    mkdir -p "${TEST_DIR}/legacy" "${TEST_DIR}/current"
    run config_value LIB="$LIB_DIR" AIOS_DIR="${TEST_DIR}/legacy" FLEETMUX_DIR="${TEST_DIR}/current"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "${TEST_DIR}/current|"* ]]
}
