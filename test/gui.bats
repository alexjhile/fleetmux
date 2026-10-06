#!/usr/bin/env bats
# Tests for gui.sh — dashboard server lifecycle + autostart unit generation

load test_helper

setup() {
    common_setup
    # A port nothing is listening on, so gui_is_up is a definite "no".
    export FLEETMUX_GUI_PORT=9999
    export HOME="$TEST_DIR"
    unset _FLEETMUX_GUI_LOADED _FLEETMUX_DISPLAY_LOADED
    source "${LIB_DIR}/gui.sh"
}

teardown() {
    common_teardown
}

# Fake systemctl/loginctl on PATH: record calls instead of touching the real
# user manager, which a test must never do.
stub_systemd() {
    mkdir -p "${TEST_DIR}/stubs"
    for tool in systemctl loginctl; do
        cat > "${TEST_DIR}/stubs/${tool}" <<STUB
#!/usr/bin/env bash
echo "${tool} \$*" >> "${TEST_DIR}/systemd_calls"
exit 0
STUB
        chmod +x "${TEST_DIR}/stubs/${tool}"
    done
    export PATH="${TEST_DIR}/stubs:$PATH"
}

@test "gui_is_up is false when nothing listens on the port" {
    run gui_is_up
    [[ "$status" -ne 0 ]]
}

@test "gui_start fails clearly when GUI dependencies are missing" {
    run gui_start
    [[ "$status" -ne 0 ]]
    [[ "$output" == *"setup.sh"* ]]
}

@test "gui_ensure stays silent and succeeds when the GUI can't run" {
    run gui_ensure
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "gui_stop reports when nothing is running" {
    # No pids match in the test environment, so this must not try to kill.
    gui_pids() { printf ''; }
    run gui_stop
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"not running"* ]]
}

@test "gui_autostart_status reports off before anything is installed" {
    run gui_autostart_status
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"off"* ]]
}

@test "autostart writes a systemd unit pointing at this repo and port" {
    [[ "$(uname -s)" == "Darwin" ]] && skip "systemd path is Linux/WSL only"
    [[ -d /run/systemd/system ]] || skip "no systemd on this host"
    stub_systemd

    run gui_autostart_enable
    [[ "$status" -eq 0 ]]

    local unit="${TEST_DIR}/.config/systemd/user/fleetmux-gui.service"
    [[ -f "$unit" ]]
    grep -q "FLEETMUX_DIR=${TEST_DIR}" "$unit"
    grep -q "PORT=9999" "$unit"
    grep -q "^ExecStart=.*tsx index.ts" "$unit"
    grep -q "WantedBy=default.target" "$unit"
    # It must enable the unit, not just write it.
    grep -q "systemctl --user enable --now fleetmux-gui.service" "${TEST_DIR}/systemd_calls"
}

@test "autostart disable removes the unit file" {
    [[ "$(uname -s)" == "Darwin" ]] && skip "systemd path is Linux/WSL only"
    [[ -d /run/systemd/system ]] || skip "no systemd on this host"
    stub_systemd
    gui_autostart_enable

    local unit="${TEST_DIR}/.config/systemd/user/fleetmux-gui.service"
    [[ -f "$unit" ]]
    run gui_autostart_disable
    [[ "$status" -eq 0 ]]
    [[ ! -f "$unit" ]]
}
