#!/usr/bin/env bats
# CLI smoke tests: run the real `fleetmux` entry point (set -euo pipefail)
# against the two-session test registry. Library-level tests don't catch
# errexit traps like `((count++))` returning 1 when count is 0.

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "fleetmux list prints every session and exits 0" {
    run "${BATS_TEST_DIRNAME}/../fleetmux" list
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testlocal"* ]]
    [[ "$output" == *"testremote"* ]]
}

@test "fleetmux status covers every session and exits 0" {
    run "${BATS_TEST_DIRNAME}/../fleetmux" status
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testlocal"* ]]
    [[ "$output" == *"testremote"* ]]
}
