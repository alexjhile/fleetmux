#!/usr/bin/env bash
# Test helper — shared setup/teardown for all AIOS bats tests

common_setup() {
    export TEST_DIR
    TEST_DIR="$(mktemp -d)"

    # Scoped git identity so brain tests can commit on machines/CI runners
    # that have no global git config (avoids "Author identity unknown").
    export GIT_AUTHOR_NAME="fleetmux-test" GIT_AUTHOR_EMAIL="test@fleetmux.local"
    export GIT_COMMITTER_NAME="fleetmux-test" GIT_COMMITTER_EMAIL="test@fleetmux.local"

    LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../lib" && pwd)"
    export LIB_DIR

    # Source config.sh first (it sets AIOS_DIR from its own location)
    unset _AIOS_CONFIG_LOADED _AIOS_REGISTRY_LOADED _AIOS_DISPLAY_LOADED _AIOS_BRAIN_LOADED
    source "${LIB_DIR}/config.sh"

    # NOW override all paths to use test directory
    export AIOS_DIR="$TEST_DIR"
    export SESSIONS_FILE="${TEST_DIR}/sessions.json"
    export TASKS_FILE="${TEST_DIR}/tasks.json"
    export TASKS_MAX=500
    export LOGS_DIR="${TEST_DIR}/logs"
    export BRAIN_DIR="${TEST_DIR}/brain"
    export CLAUDE_CODE_ROOT="${TEST_DIR}/projects"
    export SECRETS_DIR="${TEST_DIR}/secrets"

    # Create minimal fixtures
    mkdir -p "$LOGS_DIR" "$CLAUDE_CODE_ROOT" "$SECRETS_DIR"
    echo '[]' > "$TASKS_FILE"

    # Minimal sessions.json with 2 sessions (1 local, 1 remote)
    cat > "$SESSIONS_FILE" <<'SESSIONS'
[
  {
    "name": "testlocal",
    "type": "local",
    "path": "/tmp/aios-test-local",
    "description": "Test local session",
    "host": "",
    "tags": ["python", "local"],
    "autostart": false,
    "claude_flags": "--dangerously-skip-permissions"
  },
  {
    "name": "testremote",
    "type": "remote",
    "path": "/home/claude/test",
    "description": "Test remote session",
    "host": "claude@192.168.1.100",
    "tags": ["vps", "nextjs"],
    "autostart": true,
    "claude_flags": "--dangerously-skip-permissions"
  }
]
SESSIONS

    # Source remaining modules (they use the overridden paths now)
    unset _AIOS_REGISTRY_LOADED _AIOS_DISPLAY_LOADED
    source "${LIB_DIR}/registry.sh"
    source "${LIB_DIR}/display.sh"
}

common_teardown() {
    rm -rf "$TEST_DIR"
}

# Put a fake `wslpath` first on PATH: `wslpath -u 'C:\Users\me'` → /mnt/c/Users/me.
# Lets the Windows-path handling be tested on any host, WSL or not.
stub_wslpath() {
    mkdir -p "${TEST_DIR}/stubs"
    cat > "${TEST_DIR}/stubs/wslpath" <<'STUB'
#!/usr/bin/env bash
p="${2//\\//}"
drive=$(printf '%s' "${p:0:1}" | tr '[:upper:]' '[:lower:]')
printf '/mnt/%s%s\n' "$drive" "${p:2}"
STUB
    chmod +x "${TEST_DIR}/stubs/wslpath"
    PATH="${TEST_DIR}/stubs:${PATH}"
    export PATH
}
