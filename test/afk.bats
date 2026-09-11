#!/usr/bin/env bats
# Tests for afk.sh — `aios afk` verb (slice 2: live dispatch)

load test_helper

setup() {
    common_setup

    # Add an afk-ready session for dry-run/positive tests
    local tmp="${SESSIONS_FILE}.tmp"
    jq '.[0].afk_ready = true' "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
    # testlocal now has afk_ready: true; testremote has the field absent.

    source "${LIB_DIR}/afk.sh"
}

teardown() {
    common_teardown
}

# ─── Live-dispatch test scaffolding ──────────────────────────────────────────
#
# Stubs caffeinate + npx onto PATH and points testlocal's session path at a
# fake repo containing .sandcastle/{loop,main}.ts. Each stub records its
# argv (one per line) under $STUB_LOG_DIR for assertion. The npx stub also
# writes a fake AFK sidecar to $AIOS_AFK_LOG when set, simulating loop.ts.

afk_setup_live_session() {
    local mode="${1:-drain}"  # drain|missing-loop|missing-main

    # Fake session repo with the .sandcastle scripts present
    FAKE_REPO="${TEST_DIR}/fake-repo"
    mkdir -p "${FAKE_REPO}/.sandcastle"
    case "$mode" in
        drain)
            touch "${FAKE_REPO}/.sandcastle/loop.ts"
            touch "${FAKE_REPO}/.sandcastle/main.ts"
            ;;
        missing-loop)
            touch "${FAKE_REPO}/.sandcastle/main.ts"
            ;;
        missing-main)
            touch "${FAKE_REPO}/.sandcastle/loop.ts"
            ;;
    esac

    # Repoint testlocal's path
    local tmp="${SESSIONS_FILE}.tmp"
    jq --arg p "$FAKE_REPO" '.[0].path = $p' "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"

    # Stub directory + log dir for assertions
    STUB_DIR="${TEST_DIR}/stubs"
    STUB_LOG_DIR="${TEST_DIR}/stub-logs"
    mkdir -p "$STUB_DIR" "$STUB_LOG_DIR"
    export STUB_LOG_DIR

    cat > "${STUB_DIR}/caffeinate" <<'STUB'
#!/usr/bin/env bash
# Capture argv (one line per arg) and exec the command under it.
{ printf '%s\n' "$@"; } > "${STUB_LOG_DIR}/caffeinate.argv"
# caffeinate -i <cmd...>
shift  # drop -i
exec "$@"
STUB
    cat > "${STUB_DIR}/npx" <<'STUB'
#!/usr/bin/env bash
# Capture argv (one line per arg) and emit a fake AFK sidecar so the
# bash wrapper has something to summarise.
{ printf '%s\n' "$@"; } > "${STUB_LOG_DIR}/npx.argv"
{ printf '%s\n' "AIOS_AFK_LOG=${AIOS_AFK_LOG:-}"; printf '%s\n' "AIOS_AFK_SESSION=${AIOS_AFK_SESSION:-}"; } > "${STUB_LOG_DIR}/npx.env"
if [[ -n "${AIOS_AFK_LOG:-}" ]]; then
    cat > "$AIOS_AFK_LOG" <<JSON
{
  "session": "${AIOS_AFK_SESSION:-}",
  "mode": "drain",
  "started_at": "2026-05-08T12:00:00Z",
  "finished_at": "2026-05-08T12:30:00Z",
  "duration_s": 1800,
  "iterations": 2,
  "tickets_attempted": 5,
  "tickets_completed": 4,
  "tickets_stuck": 1,
  "halt_reason": "no-unblocked-issues",
  "per_ticket": []
}
JSON
fi
exit 0
STUB
    chmod +x "${STUB_DIR}/caffeinate" "${STUB_DIR}/npx"

    OLD_PATH="$PATH"
    PATH="${STUB_DIR}:${PATH}"
    export PATH
}

afk_teardown_live_session() {
    if [[ -n "${OLD_PATH:-}" ]]; then
        PATH="$OLD_PATH"
        export PATH
        unset OLD_PATH
    fi
}

# ─── --help (CLI smoke) ──────────────────────────────────────────────────────

@test "aios afk --help exits 0 and prints usage covering all three forms" {
    run "${BATS_TEST_DIRNAME}/../fleetmux" afk --help
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"<session>"* ]]
    [[ "$output" == *"<issue"* ]]
    [[ "$output" == *"all"* ]]
}

# ─── session_is_afk_ready ────────────────────────────────────────────────────

@test "session_is_afk_ready returns true when afk_ready: true" {
    session_is_afk_ready "testlocal"
}

@test "session_is_afk_ready returns false when field absent" {
    run session_is_afk_ready "testremote"
    [[ "$status" -ne 0 ]]
}

@test "session_is_afk_ready returns false for unknown session" {
    run session_is_afk_ready "nonexistent"
    [[ "$status" -ne 0 ]]
}

# ─── afk_run: error paths ────────────────────────────────────────────────────

@test "afk_run errors with 'session not found' on unknown session" {
    run afk_run "nonexistent"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"session not found"* ]]
}

@test "afk_run errors with 'afk_ready' message on session missing the flag" {
    run afk_run "testremote"
    [[ "$status" -eq 1 ]]
    [[ "$output" == *"afk_ready"* ]]
}

# ─── afk_run: --dry-run prints intended invocation ──────────────────────────

@test "afk_run --dry-run on afk-ready session prints loop.ts message and exits 0" {
    run afk_run --dry-run "testlocal"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"would run drain"* ]]
    [[ "$output" == *".sandcastle/loop.ts"* ]]
}

@test "afk_run --dry-run with issue number prints main.ts invocation and exits 0" {
    run afk_run --dry-run "testlocal" "42"
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"would run"* ]]
    [[ "$output" == *".sandcastle/main.ts"* ]]
    [[ "$output" == *"42"* ]]
}

# ─── afk_run: live drain dispatch ───────────────────────────────────────────

@test "afk_run live drain invokes 'caffeinate -i npx tsx .sandcastle/loop.ts' in session path" {
    afk_setup_live_session drain

    run afk_run "testlocal"
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]

    # caffeinate received: -i npx tsx .sandcastle/loop.ts
    local caf_args
    caf_args=$(<"${STUB_LOG_DIR}/caffeinate.argv")
    [[ "$(echo "$caf_args" | sed -n 1p)" == "-i" ]]
    [[ "$(echo "$caf_args" | sed -n 2p)" == */npx ]]
    [[ "$(echo "$caf_args" | sed -n 3p)" == "tsx" ]]
    [[ "$(echo "$caf_args" | sed -n 4p)" == ".sandcastle/loop.ts" ]]

    # npx was exec'd with tsx + .sandcastle/loop.ts (no extra args)
    local npx_args
    npx_args=$(<"${STUB_LOG_DIR}/npx.argv")
    [[ "$(echo "$npx_args" | sed -n 1p)" == "tsx" ]]
    [[ "$(echo "$npx_args" | sed -n 2p)" == ".sandcastle/loop.ts" ]]

    # npx ran with AIOS_AFK_LOG + AIOS_AFK_SESSION exported
    local npx_env
    npx_env=$(<"${STUB_LOG_DIR}/npx.env")
    [[ "$npx_env" == *"AIOS_AFK_LOG="*"/.aios/afk-runs/testlocal-"*".json"* ]]
    [[ "$npx_env" == *"AIOS_AFK_SESSION=testlocal"* ]]
}

@test "afk_run live one-shot invokes 'caffeinate -i npx tsx .sandcastle/main.ts <N>'" {
    afk_setup_live_session drain

    run afk_run "testlocal" "42"
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]

    local npx_args
    npx_args=$(<"${STUB_LOG_DIR}/npx.argv")
    [[ "$(echo "$npx_args" | sed -n 1p)" == "tsx" ]]
    [[ "$(echo "$npx_args" | sed -n 2p)" == ".sandcastle/main.ts" ]]
    [[ "$(echo "$npx_args" | sed -n 3p)" == "42" ]]
}

@test "afk_run under WSL (no caffeinate) holds a Windows keep-awake request for the drain" {
    afk_setup_live_session drain
    rm -f "${STUB_DIR}/caffeinate"
    if command -v caffeinate >/dev/null 2>&1; then
        afk_teardown_live_session
        skip "host has a real caffeinate (macOS) — WSL branch unreachable"
    fi
    # PowerShell stub: record argv, block until stdin closes, mark release.
    cat > "${STUB_DIR}/powershell.exe" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; } > "${STUB_LOG_DIR}/powershell.argv"
cat >/dev/null
touch "${STUB_LOG_DIR}/powershell.released"
STUB
    chmod +x "${STUB_DIR}/powershell.exe"

    export AIOS_PLATFORM=wsl
    run afk_run "testlocal"
    unset AIOS_PLATFORM
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]
    # The drain itself still ran, unwrapped
    [[ "$(sed -n 1p "${STUB_LOG_DIR}/npx.argv")" == "tsx" ]]
    [[ "$(sed -n 2p "${STUB_LOG_DIR}/npx.argv")" == ".sandcastle/loop.ts" ]]
    # PowerShell pinned the execution state, and had already been released
    # (saw EOF) by the time afk_run returned
    grep -q "SetThreadExecutionState" "${STUB_LOG_DIR}/powershell.argv"
    [[ -f "${STUB_LOG_DIR}/powershell.released" ]]
}

@test "run_keepawake under WSL returns the command's exit status, not PowerShell's" {
    STUB_DIR="${TEST_DIR}/stubs"
    mkdir -p "$STUB_DIR"
    PATH="${STUB_DIR}:${PATH}"
    if command -v caffeinate >/dev/null 2>&1; then
        skip "host has a real caffeinate (macOS) — WSL branch unreachable"
    fi
    printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "${STUB_DIR}/powershell.exe"
    chmod +x "${STUB_DIR}/powershell.exe"
    export AIOS_PLATFORM=wsl

    run run_keepawake bash -c 'echo drained; exit 7'
    [[ "$status" -eq 7 ]]
    [[ "$output" == "drained" ]]
}

@test "afk_run with neither caffeinate nor WSL runs the drain directly" {
    afk_setup_live_session drain
    rm -f "${STUB_DIR}/caffeinate"
    if command -v caffeinate >/dev/null 2>&1; then
        afk_teardown_live_session
        skip "host has a real caffeinate (macOS)"
    fi

    export AIOS_PLATFORM=linux
    run afk_run "testlocal"
    unset AIOS_PLATFORM
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]
    [[ "$(sed -n 2p "${STUB_LOG_DIR}/npx.argv")" == ".sandcastle/loop.ts" ]]
}

@test "afk_run live drain refuses when .sandcastle/loop.ts is missing" {
    afk_setup_live_session missing-loop

    run afk_run "testlocal"
    afk_teardown_live_session

    [[ "$status" -ne 0 ]]
    [[ "$output" == *".sandcastle/loop.ts"* ]]
    [[ "$output" == *"not found"* ]]
}

@test "afk_run live one-shot refuses when .sandcastle/main.ts is missing" {
    afk_setup_live_session missing-main

    run afk_run "testlocal" "42"
    afk_teardown_live_session

    [[ "$status" -ne 0 ]]
    [[ "$output" == *".sandcastle/main.ts"* ]]
    [[ "$output" == *"not found"* ]]
}

# ─── afk_run: tasks.json + sidecar log ──────────────────────────────────────

@test "afk_run live drain writes one tasks.json entry with mode=afk and afk metadata" {
    afk_setup_live_session drain

    run afk_run "testlocal"
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]

    # Exactly one new entry, at index 0 (most recent)
    local count
    count=$(jq 'length' "$TASKS_FILE")
    [[ "$count" -eq 1 ]]

    # mode + session + status + source
    [[ "$(jq -r '.[0].mode' "$TASKS_FILE")" == "afk" ]]
    [[ "$(jq -r '.[0].session' "$TASKS_FILE")" == "testlocal" ]]
    [[ "$(jq -r '.[0].status' "$TASKS_FILE")" == "completed" ]]
    [[ "$(jq -r '.[0].source' "$TASKS_FILE")" == "afk" ]]

    # AFK summary fields populated from the sidecar
    [[ "$(jq -r '.[0].afk.tickets_attempted' "$TASKS_FILE")" == "5" ]]
    [[ "$(jq -r '.[0].afk.tickets_completed' "$TASKS_FILE")" == "4" ]]
    [[ "$(jq -r '.[0].afk.tickets_stuck' "$TASKS_FILE")" == "1" ]]
    [[ "$(jq -r '.[0].afk.halt_reason' "$TASKS_FILE")" == "no-unblocked-issues" ]]

    # All required summary keys present (spec)
    local keys
    keys=$(jq -r '.[0].afk | keys | sort | join(",")' "$TASKS_FILE")
    [[ "$keys" == *"duration_s"* ]]
    [[ "$keys" == *"finished_at"* ]]
    [[ "$keys" == *"halt_reason"* ]]
    [[ "$keys" == *"sidecar"* ]]
    [[ "$keys" == *"started_at"* ]]
    [[ "$keys" == *"tickets_attempted"* ]]
    [[ "$keys" == *"tickets_completed"* ]]
    [[ "$keys" == *"tickets_stuck"* ]]
}

@test "afk_run live drain writes a sidecar log under .aios/afk-runs/<session>-<ts>.json" {
    afk_setup_live_session drain

    run afk_run "testlocal"
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]

    local sidecar_dir="${AIOS_DIR}/.aios/afk-runs"
    [[ -d "$sidecar_dir" ]]

    local count
    count=$(find "$sidecar_dir" -name 'testlocal-*.json' | wc -l | tr -d ' ')
    [[ "$count" -eq 1 ]]

    local sidecar
    sidecar=$(find "$sidecar_dir" -name 'testlocal-*.json' | head -1)
    [[ -f "$sidecar" ]]
    [[ "$(jq -r '.session' "$sidecar")" == "testlocal" ]]
    [[ "$(jq -r '.tickets_attempted' "$sidecar")" == "5" ]]
}

@test "afk_run live drain caps tasks.json at TASKS_MAX entries" {
    afk_setup_live_session drain

    # Pre-fill tasks.json with TASKS_MAX entries
    jq -n --argjson max "$TASKS_MAX" \
        '[range(0; $max) | {id: ("seed_" + tostring), session: "testlocal", task: "seed", mode: "run", status: "completed", dispatched_at: "2025-01-01T00:00:00Z"}]' \
        > "$TASKS_FILE"

    run afk_run "testlocal"
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]

    # Still capped — the new entry pushed off the oldest seed
    local count
    count=$(jq 'length' "$TASKS_FILE")
    [[ "$count" -eq "$TASKS_MAX" ]]
    # Most recent is the AFK row, not a seed
    [[ "$(jq -r '.[0].mode' "$TASKS_FILE")" == "afk" ]]
}

@test "afk_run live one-shot records tasks.json entry with tickets_attempted=1 and issue ref" {
    afk_setup_live_session drain

    run afk_run "testlocal" "42"
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]

    [[ "$(jq -r '.[0].mode' "$TASKS_FILE")" == "afk" ]]
    [[ "$(jq -r '.[0].session' "$TASKS_FILE")" == "testlocal" ]]
    [[ "$(jq -r '.[0].task' "$TASKS_FILE")" == *"#42"* ]]
}

# ─── aios history: AFK row rendering ────────────────────────────────────────

@test "aios history renders AFK drain rows from tasks.json (one row per drain)" {
    afk_setup_live_session drain
    run afk_run "testlocal"
    afk_teardown_live_session
    [[ "$status" -eq 0 ]]

    # AIOS_DIR / SESSIONS_FILE / TASKS_FILE flow into the subprocess via the
    # ${VAR:-default} pattern in config.sh.
    run env \
        AIOS_DIR="$AIOS_DIR" \
        SESSIONS_FILE="$SESSIONS_FILE" \
        TASKS_FILE="$TASKS_FILE" \
        LOGS_DIR="$LOGS_DIR" \
        "${BATS_TEST_DIRNAME}/../fleetmux" history
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"testlocal"* ]]
    [[ "$output" == *"afk"* ]]
    # Stats summary appears in the task description
    [[ "$output" == *"4/5"* ]]
}

# ─── afk_all: live broadcast scaffolding ────────────────────────────────────

# Replace the single-session fixture with N afk_ready sessions, each with a
# usable .sandcastle/loop.ts in its session path. Stubs caffeinate + npx
# onto PATH and stubs glab so queue-count probes return a configurable count
# per session via GLAB_QUEUE_<session>=<n>.
afk_setup_all_session() {
    local n="${1:-2}"
    local sleep_s="${AFK_STUB_SLEEP:-0}"

    local arr='[]'
    local i
    for i in $(seq 1 "$n"); do
        local name="sess${i}"
        local repo="${TEST_DIR}/repo-${i}"
        mkdir -p "${repo}/.sandcastle"
        touch "${repo}/.sandcastle/loop.ts"
        arr=$(jq -c --arg name "$name" --arg path "$repo" \
            '. + [{name: $name, type: "local", path: $path, description: "all-test", host: "", tags: [], autostart: false, claude_flags: "--dangerously-skip-permissions", afk_ready: true}]' \
            <<< "$arr")
    done
    echo "$arr" > "$SESSIONS_FILE"

    STUB_DIR="${TEST_DIR}/stubs"
    STUB_LOG_DIR="${TEST_DIR}/stub-logs"
    mkdir -p "$STUB_DIR" "$STUB_LOG_DIR" "${STUB_LOG_DIR}/concurrent"
    export STUB_LOG_DIR

    cat > "${STUB_DIR}/caffeinate" <<'STUB'
#!/usr/bin/env bash
shift  # drop -i
exec "$@"
STUB

    cat > "${STUB_DIR}/npx" <<STUB
#!/usr/bin/env bash
# Track concurrent invocations
marker="\${STUB_LOG_DIR}/concurrent/\$\$"
touch "\$marker"
running=\$(find "\${STUB_LOG_DIR}/concurrent" -type f | wc -l | tr -d ' ')
echo "\$running" >> "\${STUB_LOG_DIR}/concurrent.history"

if [[ -n "\${AIOS_AFK_LOG:-}" ]]; then
    cat > "\$AIOS_AFK_LOG" <<JSON
{
  "session": "\${AIOS_AFK_SESSION:-}",
  "mode": "drain",
  "started_at": "2026-05-08T12:00:00Z",
  "finished_at": "2026-05-08T12:30:00Z",
  "duration_s": 1800,
  "iterations": 1,
  "tickets_attempted": 2,
  "tickets_completed": 2,
  "tickets_stuck": 0,
  "halt_reason": "no-unblocked-issues",
  "per_ticket": []
}
JSON
fi

sleep ${sleep_s}
rm -f "\$marker"
exit 0
STUB

    # glab stub: returns JSON array of length GLAB_QUEUE_<session> for the
    # ready-for-agent label. Defaults to "[1]" so sessions aren't skipped.
    cat > "${STUB_DIR}/glab" <<'STUB'
#!/usr/bin/env bash
# Only handles `glab issue list --label ready-for-agent ... --output json`
if [[ "$1" == "issue" && "$2" == "list" ]]; then
    # Identify session by PWD basename → repo-<N> → look up sess<N>'s queue
    base=$(basename "$PWD")
    n="${base#repo-}"
    var="GLAB_QUEUE_sess${n}"
    count="${!var:-1}"
    out="["
    for i in $(seq 1 "$count"); do
        [[ "$i" -gt 1 ]] && out+=","
        out+='{"iid":'"$i"'}'
    done
    out+="]"
    echo "$out"
    exit 0
fi
echo "[]"
exit 0
STUB

    chmod +x "${STUB_DIR}/caffeinate" "${STUB_DIR}/npx" "${STUB_DIR}/glab"

    OLD_PATH="$PATH"
    PATH="${STUB_DIR}:${PATH}"
    export PATH
}

afk_teardown_all_session() {
    if [[ -n "${OLD_PATH:-}" ]]; then
        PATH="$OLD_PATH"
        export PATH
        unset OLD_PATH
    fi
}

# ─── afk_all: live broadcast ────────────────────────────────────────────────

@test "afk_all runs afk_run for each afk_ready session and writes a sidecar per session" {
    afk_setup_all_session 2

    run afk_all
    afk_teardown_all_session

    [[ "$status" -eq 0 ]]

    # Each session got one sidecar written under .aios/afk-runs/
    local s1_sidecars s2_sidecars
    s1_sidecars=$(find "${AIOS_DIR}/.aios/afk-runs" -name 'sess1-*.json' | wc -l | tr -d ' ')
    s2_sidecars=$(find "${AIOS_DIR}/.aios/afk-runs" -name 'sess2-*.json' | wc -l | tr -d ' ')
    [[ "$s1_sidecars" -eq 1 ]]
    [[ "$s2_sidecars" -eq 1 ]]
}

@test "afk_all stdout is one JSON object with a sessions[] array spanning every session" {
    afk_setup_all_session 2

    run afk_all
    afk_teardown_all_session

    [[ "$status" -eq 0 ]]

    # The JSON briefing is the last thing on stdout; isolate it.
    local json
    json=$(echo "$output" | awk '/^\{/{flag=1} flag{print}')
    [[ -n "$json" ]]

    local count
    count=$(echo "$json" | jq '.sessions | length')
    [[ "$count" -eq 2 ]]

    local names
    names=$(echo "$json" | jq -r '.sessions[].session' | sort | tr '\n' ',' )
    [[ "$names" == "sess1,sess2," ]]

    # Per-session entries carry the slice-2 summary shape
    [[ "$(echo "$json" | jq -r '.sessions[0].mode')" == "drain" ]]
    [[ "$(echo "$json" | jq -r '.sessions[0].halt_reason')" != "null" ]]
}

@test "afk_all skips sessions whose ready-for-agent queue is empty (no afk_run, no sidecar)" {
    afk_setup_all_session 2
    export GLAB_QUEUE_sess1=0
    export GLAB_QUEUE_sess2=3

    run afk_all
    afk_teardown_all_session
    unset GLAB_QUEUE_sess1 GLAB_QUEUE_sess2

    [[ "$status" -eq 0 ]]

    # sess1 was skipped — no sidecar in afk-runs, no concurrent marker fired
    local s1_sidecars
    s1_sidecars=$(find "${AIOS_DIR}/.aios/afk-runs" -name 'sess1-*.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$s1_sidecars" -eq 0 ]]

    # sess2 ran
    local s2_sidecars
    s2_sidecars=$(find "${AIOS_DIR}/.aios/afk-runs" -name 'sess2-*.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$s2_sidecars" -eq 1 ]]

    # Briefing reports both sessions: sess1 with halt_reason=queue-empty, sess2 ran
    local json
    json=$(echo "$output" | awk '/^\{/{flag=1} flag{print}')
    local s1_halt s2_halt
    s1_halt=$(echo "$json" | jq -r '.sessions[] | select(.session=="sess1") | .halt_reason')
    s2_halt=$(echo "$json" | jq -r '.sessions[] | select(.session=="sess2") | .halt_reason')
    [[ "$s1_halt" == "queue-empty" ]]
    [[ "$s2_halt" == "no-unblocked-issues" ]]
}

@test "afk_all --concurrency 1 serialises drains (max one npx in flight)" {
    AFK_STUB_SLEEP=0.4 afk_setup_all_session 3

    run afk_all --concurrency 1
    afk_teardown_all_session

    [[ "$status" -eq 0 ]]

    # concurrent.history records the running count seen at each npx start.
    # With cap=1 it should never exceed 1.
    local max_concurrent
    max_concurrent=$(awk 'BEGIN{m=0} {if($1>m)m=$1} END{print m}' \
        "${STUB_LOG_DIR}/concurrent.history")
    [[ "$max_concurrent" -le 1 ]]
}

@test "afk_all --dry-run lists ready sessions and exits 0 without invoking npx" {
    afk_setup_all_session 2

    run afk_all --dry-run
    afk_teardown_all_session

    [[ "$status" -eq 0 ]]
    [[ "$output" == *"sess1"* ]]
    [[ "$output" == *"sess2"* ]]

    # No sidecar files written (no real run)
    local sidecars
    sidecars=$(find "${AIOS_DIR}/.aios/afk-runs" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$sidecars" -eq 0 ]]
}

# ─── afk_run: per-session lockfile ──────────────────────────────────────────

@test "afk_run errors with 'another drain' when lockfile already held" {
    afk_setup_live_session drain

    local lock_dir="${AIOS_DIR}/.aios/locks"
    mkdir -p "${lock_dir}/afk-testlocal.lock"

    run afk_run "testlocal"
    afk_teardown_live_session

    [[ "$status" -eq 1 ]]
    [[ "$output" == *"another drain already running"* ]]
    [[ "$output" == *"testlocal"* ]]
}

@test "afk_run releases lockfile after a normal-exit drain" {
    afk_setup_live_session drain

    run afk_run "testlocal"
    afk_teardown_live_session

    [[ "$status" -eq 0 ]]

    local lock="${AIOS_DIR}/.aios/locks/afk-testlocal.lock"
    [[ ! -e "$lock" ]]
}

@test "afk_run releases lockfile when killed by SIGTERM" {
    afk_setup_live_session drain

    # Replace npx stub with one that sleeps so we can signal mid-run
    cat > "${STUB_DIR}/npx" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; } > "${STUB_LOG_DIR}/npx.argv"
sleep 30
STUB
    chmod +x "${STUB_DIR}/npx"

    local lock="${AIOS_DIR}/.aios/locks/afk-testlocal.lock"

    # Spawn afk_run in a subshell so we can signal it
    (
        # shellcheck disable=SC1091
        source "${LIB_DIR}/afk.sh"
        afk_run "testlocal"
    ) &
    local pid=$!

    # Wait up to ~3s for the lockfile to appear
    local waited=0
    while [[ ! -e "$lock" ]] && [[ $waited -lt 30 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    [[ -e "$lock" ]]

    # SIGTERM the whole process group so the sleeping npx + bash both die.
    # The bash EXIT trap should release the lockfile.
    kill -TERM "$pid" 2>/dev/null || true
    pkill -TERM -P "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    # Brief settle for trap-driven cleanup
    sleep 0.2
    afk_teardown_live_session

    [[ ! -e "$lock" ]]
}

# ─── sessions.example.json schema (smoke) ────────────────────────────────────

@test "sessions.example.json is valid JSON with the documented schema" {
    local example="${BATS_TEST_DIRNAME}/../sessions.example.json"
    [[ -f "$example" ]]
    # Valid JSON array, every entry has name + type, types are known
    run jq -e 'type == "array" and length > 0
        and all(.[]; has("name") and has("type")
        and (.type == "local" or .type == "remote" or .type == "utility"))' "$example"
    [ "$status" -eq 0 ]
}

@test "sessions.example.json: afk_ready, when present, is a boolean" {
    local example="${BATS_TEST_DIRNAME}/../sessions.example.json"
    run jq -e 'all(.[]; (has("afk_ready") | not) or (.afk_ready | type == "boolean"))' "$example"
    [ "$status" -eq 0 ]
}
