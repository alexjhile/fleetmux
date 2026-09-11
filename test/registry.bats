#!/usr/bin/env bats
# Tests for registry.sh — session CRUD operations

load test_helper

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "registry_count returns correct count" {
    run registry_count
    [[ "$output" == "2" ]]
}

@test "registry_session_exists returns true for existing session" {
    registry_session_exists "testlocal"
}

@test "registry_session_exists returns false for missing session" {
    run registry_session_exists "nonexistent"
    [[ "$status" -ne 0 ]]
}

@test "registry_get_field returns correct type" {
    local result
    result=$(registry_get_field "testlocal" "type")
    [[ "$result" == "local" ]]
}

@test "registry_get_field returns correct host for remote" {
    local result
    result=$(registry_get_field "testremote" "host")
    [[ "$result" == "claude@192.168.1.100" ]]
}

@test "registry_list_names returns all names" {
    local names
    names=$(registry_list_names)
    [[ "$names" == *"testlocal"* ]]
    [[ "$names" == *"testremote"* ]]
}

@test "registry_add_session adds new entry" {
    registry_add_session "newsession" "local" "/tmp/new" "A new session" ""

    registry_session_exists "newsession"
    local result
    result=$(registry_count)
    [[ "$result" == "3" ]]
}

@test "registry_add_session stores a Windows path as a WSL path for local sessions" {
    stub_wslpath
    registry_add_session "winsess" "local" 'C:\code\api' "" ""

    local result
    result=$(registry_get_field "winsess" "path")
    [[ "$result" == "/mnt/c/code/api" ]]
}

@test "registry_add_session leaves remote paths untouched" {
    stub_wslpath
    registry_add_session "remsess" "remote" '/srv/app' "" "deploy@203.0.113.10"

    local result
    result=$(registry_get_field "remsess" "path")
    [[ "$result" == "/srv/app" ]]
}

@test "registry_remove_session removes entry" {
    registry_remove_session "testlocal"

    run registry_session_exists "testlocal"
    [[ "$status" -ne 0 ]]

    local result
    result=$(registry_count)
    [[ "$result" == "1" ]]
}

@test "registry_get_field returns empty for null host on local" {
    local result
    result=$(registry_get_field "testlocal" "host")
    [[ -z "$result" || "$result" == "" ]]
}
