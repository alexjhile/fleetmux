#!/usr/bin/env bash
# shellcheck disable=SC1091
# Registry CRUD — jq-based operations on sessions.json
[[ -n "${_FLEETMUX_REGISTRY_LOADED:-}" ]] && return 0; _FLEETMUX_REGISTRY_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# claude_flags for sessions created by `fleetmux add`
REGISTRY_DEFAULT_FLAGS="--dangerously-skip-permissions --verbose"

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
           --arg flags "$REGISTRY_DEFAULT_FLAGS" \
           '. + [{name: $name, type: $type, host: $host, path: $path, description: $desc, tags: [], autostart: false, claude_flags: $flags}]' \
           "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
    else
        jq --arg name "$name" \
           --arg type "$type" \
           --arg path "$path" \
           --arg desc "$description" \
           --arg flags "$REGISTRY_DEFAULT_FLAGS" \
           '. + [{name: $name, type: $type, path: $path, description: $desc, tags: [], autostart: false, claude_flags: $flags}]' \
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

# registry_set_field <name> <field> <string value>
registry_set_field() {
    local name="$1" field="$2" value="$3"
    local tmp="${SESSIONS_FILE}.tmp"
    jq --arg name "$name" --arg field "$field" --arg value "$value" \
       'map(if .name == $name then .[$field] = $value else . end)' \
       "$SESSIONS_FILE" > "$tmp" && mv "$tmp" "$SESSIONS_FILE"
}

# registry_conversation_id <name>
# The Claude conversation this session resumes on every start. Minted and
# saved on first use, so the session keeps one conversation for its lifetime.
# (--continue can't do this: it takes the newest conversation in the
# directory, and several sessions can share a directory.)
registry_conversation_id() {
    local name="$1" id
    id=$(registry_get_field "$name" "conversation_id")
    if [[ -z "$id" ]]; then
        id=$(platform_uuid)
        registry_set_field "$name" "conversation_id" "$id" || return 1
    fi
    printf '%s\n' "$id"
}
