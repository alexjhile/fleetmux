#!/usr/bin/env bash
# shellcheck disable=SC1091
# Registry CRUD — jq-based operations on sessions.json
[[ -n "${_AIOS_REGISTRY_LOADED:-}" ]] && return 0; _AIOS_REGISTRY_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

registry_list_sessions() {
    jq -r '.' "$SESSIONS_FILE"
}

registry_get_session() {
    local name="$1"
    jq -r ".[] | select(.name == \"$name\")" "$SESSIONS_FILE"
}

registry_get_field() {
    local name="$1"
    local field="$2"
    jq -r ".[] | select(.name == \"$name\") | .${field} // empty" "$SESSIONS_FILE"
}

registry_session_exists() {
    local name="$1"
    local count
    count=$(jq "[.[] | select(.name == \"$name\")] | length" "$SESSIONS_FILE")
    [[ "$count" -gt 0 ]]
}

registry_list_names() {
    jq -r '.[].name' "$SESSIONS_FILE"
}

registry_count() {
    jq 'length' "$SESSIONS_FILE"
}

registry_add_session() {
    local name="$1"
    local type="$2"
    local path="$3"
    local description="${4:-}"
    local host="${5:-}"

    # Local sessions run inside WSL on Windows — accept C:\... paths too.
    [[ "$type" != "remote" ]] && path=$(platform_normalize_path "$path")

    if registry_session_exists "$name"; then
        echo "Error: Session '$name' already exists" >&2
        return 1
    fi

    local tmp="${SESSIONS_FILE}.tmp"
    if [[ -n "$host" ]]; then
        jq --arg name "$name" \
           --arg type "$type" \
           --arg path "$path" \
           --arg desc "$description" \
           --arg host "$host" \
           '. + [{name: $name, type: $type, host: $host, path: $path, description: $desc, tags: [], autostart: false, claude_flags: "--dangerously-skip-permissions"}]' \
           "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
    else
        jq --arg name "$name" \
           --arg type "$type" \
           --arg path "$path" \
           --arg desc "$description" \
           '. + [{name: $name, type: $type, path: $path, description: $desc, tags: [], autostart: false, claude_flags: "--dangerously-skip-permissions"}]' \
           "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
    fi

    echo "Added session '$name'"
}

registry_remove_session() {
    local name="$1"

    if ! registry_session_exists "$name"; then
        echo "Error: Session '$name' not found" >&2
        return 1
    fi

    local tmp="${SESSIONS_FILE}.tmp"
    jq --arg name "$name" '[.[] | select(.name != $name)]' "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
    echo "Removed session '$name'"
}
