#!/usr/bin/env bats
# Tests for brain.sh — persistent memory backup system

load test_helper

setup() {
    common_setup

    # Create fake Claude memory directories for local session
    export CLAUDE_PROJECTS_DIR="${TEST_DIR}/claude-projects"
    mkdir -p "${CLAUDE_PROJECTS_DIR}/-tmp-fleetmux-test-local/memory"

    # Create some memory files
    echo "# Test Memory" > "${CLAUDE_PROJECTS_DIR}/-tmp-fleetmux-test-local/memory/MEMORY.md"
    echo "# Patterns" > "${CLAUDE_PROJECTS_DIR}/-tmp-fleetmux-test-local/memory/patterns.md"

    # Source brain module
    source "${LIB_DIR}/brain.sh"
}

teardown() {
    common_teardown
}

@test "brain_dir is created under FLEETMUX_DIR" {
    [[ "$BRAIN_DIR" == "${FLEETMUX_DIR}/brain" ]]
}

@test "brain_sync_local copies memory files for local session" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"

    [[ -d "${BRAIN_DIR}/testlocal" ]]
    [[ -f "${BRAIN_DIR}/testlocal/MEMORY.md" ]]
    [[ -f "${BRAIN_DIR}/testlocal/patterns.md" ]]
    [[ "$(cat "${BRAIN_DIR}/testlocal/MEMORY.md")" == "# Test Memory" ]]
}

@test "brain_sync_local handles missing memory directory gracefully" {
    brain_sync_local "testlocal" "/nonexistent/path"
    [[ ! -d "${BRAIN_DIR}/testlocal" ]] || [[ -z "$(ls -A "${BRAIN_DIR}/testlocal" 2>/dev/null)" ]]
}

@test "brain_sync_local updates existing files" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"
    [[ "$(cat "${BRAIN_DIR}/testlocal/MEMORY.md")" == "# Test Memory" ]]

    echo "# Updated Memory" > "${CLAUDE_PROJECTS_DIR}/-tmp-fleetmux-test-local/memory/MEMORY.md"
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"
    [[ "$(cat "${BRAIN_DIR}/testlocal/MEMORY.md")" == "# Updated Memory" ]]
}

@test "brain_sync_local removes files deleted from source" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"
    [[ -f "${BRAIN_DIR}/testlocal/patterns.md" ]]

    rm "${CLAUDE_PROJECTS_DIR}/-tmp-fleetmux-test-local/memory/patterns.md"
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"
    [[ ! -f "${BRAIN_DIR}/testlocal/patterns.md" ]]
}

@test "brain_sync_tasks copies tasks.json snapshot" {
    echo '[{"id":"t_1","session":"test"}]' > "$TASKS_FILE"
    brain_sync_tasks

    [[ -f "${BRAIN_DIR}/_tasks.json" ]]
    [[ "$(jq -r '.[0].id' "${BRAIN_DIR}/_tasks.json")" == "t_1" ]]
}

@test "brain_diff detects changes when brain has modified files" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"

    (cd "$FLEETMUX_DIR" && git init -q && git add -A && git commit -q -m "init")

    echo "# Changed" > "${BRAIN_DIR}/testlocal/MEMORY.md"

    run brain_diff
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testlocal/MEMORY.md"* ]]
}

@test "brain_diff shows nothing when clean" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"

    (cd "$FLEETMUX_DIR" && git init -q && git add -A && git commit -q -m "init")

    run brain_diff
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"no changes"* ]]
}

@test "brain_commit creates a git commit with brain changes" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"
    (cd "$FLEETMUX_DIR" && git init -q && git add -A && git commit -q -m "init")

    echo "# New content" >> "${BRAIN_DIR}/testlocal/MEMORY.md"

    run brain_commit
    [[ "$status" -eq 0 ]]

    local last_msg
    last_msg=$(cd "$FLEETMUX_DIR" && git log --oneline -1)
    [[ "$last_msg" == *"brain:"* ]]
}

@test "brain_commit skips when nothing to commit" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"
    (cd "$FLEETMUX_DIR" && git init -q && git add -A && git commit -q -m "init")

    run brain_commit
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"nothing"* ]] || [[ "$output" == *"clean"* ]]
}

@test "brain_session_count returns correct count" {
    brain_sync_local "testlocal" "/tmp/fleetmux-test-local"

    local count
    count=$(brain_session_count)
    [[ "$count" -eq 1 ]]
}
