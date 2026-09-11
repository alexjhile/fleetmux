#!/usr/bin/env bats
# Tests for platform.sh — GNU/BSD date+stat shims and WSL helpers.
# TZ values are POSIX strings (UTC0, JST-9) so no zoneinfo database is needed.

load test_helper

setup() {
    common_setup
    unset _AIOS_PLATFORM_LOADED
    source "${LIB_DIR}/platform.sh"
}

teardown() {
    common_teardown
}

# ─── iso_to_epoch ───────────────────────────────────────────────────────────

@test "iso_to_epoch parses a UTC ISO-8601 timestamp" {
    [[ "$(iso_to_epoch 2026-01-01T00:00:00Z)" == "1767225600" ]]
}

@test "iso_to_epoch treats the input as UTC whatever the local TZ" {
    export TZ=JST-9
    [[ "$(iso_to_epoch 2026-01-01T00:00:00Z)" == "1767225600" ]]
}

@test "iso_to_epoch prints 0 for empty, null and malformed input" {
    [[ "$(iso_to_epoch "")" == "0" ]]
    [[ "$(iso_to_epoch null)" == "0" ]]
    [[ "$(iso_to_epoch "2026-01-01 00:00:00")" == "0" ]]
    [[ "$(iso_to_epoch "not a date")" == "0" ]]
}

# ─── local_datetime_to_epoch / epoch_fmt ────────────────────────────────────

@test "local_datetime_to_epoch interprets the time in the local TZ" {
    export TZ=UTC0
    [[ "$(local_datetime_to_epoch "2026-01-01 00:00:00")" == "1767225600" ]]
    export TZ=JST-9
    [[ "$(local_datetime_to_epoch "2026-01-01 00:00:00")" == "1767193200" ]]
}

@test "local_datetime_to_epoch prints 0 for malformed input" {
    [[ "$(local_datetime_to_epoch "")" == "0" ]]
    [[ "$(local_datetime_to_epoch "3 days")" == "0" ]]
}

@test "epoch_fmt formats epoch seconds in local time" {
    export TZ=UTC0
    [[ "$(epoch_fmt 1767225600 "+%Y-%m-%d %H:%M")" == "2026-01-01 00:00" ]]
    export TZ=JST-9
    [[ "$(epoch_fmt 1767225600 "+%H:%M")" == "09:00" ]]
}

# ─── file_mtime ─────────────────────────────────────────────────────────────

@test "file_mtime returns the modification time in epoch seconds" {
    export TZ=UTC0
    touch -t 202601010000 "${TEST_DIR}/f"
    [[ "$(file_mtime "${TEST_DIR}/f")" == "1767225600" ]]
}

@test "file_mtime prints 0 for a missing file" {
    [[ "$(file_mtime "${TEST_DIR}/does-not-exist")" == "0" ]]
}

# ─── WSL helpers ────────────────────────────────────────────────────────────

@test "platform_is_wsl honours AIOS_PLATFORM" {
    AIOS_PLATFORM=wsl platform_is_wsl
    export AIOS_PLATFORM=linux
    run platform_is_wsl
    [[ "$status" -ne 0 ]]
}

@test "platform_normalize_path converts Windows paths via wslpath" {
    stub_wslpath
    [[ "$(platform_normalize_path 'C:\Users\me\code')" == "/mnt/c/Users/me/code" ]]
    [[ "$(platform_normalize_path 'D:/work/api')" == "/mnt/d/work/api" ]]
}

@test "platform_normalize_path leaves POSIX and relative paths alone" {
    stub_wslpath
    [[ "$(platform_normalize_path /home/me/code)" == "/home/me/code" ]]
    [[ "$(platform_normalize_path code/api)" == "code/api" ]]
}
