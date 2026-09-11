#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2059
# Conversation — read recent chat from a session's Claude Code JSONL transcript
[[ -n "${_AIOS_CONVERSATION_LOADED:-}" ]] && return 0; _AIOS_CONVERSATION_LOADED=1

source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
source "$(dirname "${BASH_SOURCE[0]}")/display.sh"
source "$(dirname "${BASH_SOURCE[0]}")/context.sh"

# Parse a JSONL session file and extract readable conversation
# Uses jq to extract user text messages and assistant text blocks
parse_conversation() {
    local jsonl_file="$1"
    local limit="${2:-20}"

    if [[ ! -f "$jsonl_file" ]]; then
        echo "(file not found: $jsonl_file)"
        return 1
    fi

    # Extract user text messages and assistant text responses
    # Skip tool results (user) and tool_use/thinking blocks (assistant)
    jq -r --argjson limit "$limit" '
        # Only process user text and assistant text messages
        select(.type == "user" or .type == "assistant") |
        select(.message.role == "user" or .message.role == "assistant") |
        {
            role: .message.role,
            ts: (.timestamp // ""),
            content: (
                if .message.role == "user" then
                    [.message.content[] |
                        select(type == "object" and .type == "text") |
                        .text
                    ] | join("\n")
                elif .message.role == "assistant" then
                    [.message.content[] |
                        select(type == "object" and .type == "text") |
                        .text
                    ] | join("\n")
                else ""
                end
            )
        } |
        select(.content != "" and .content != null)
    ' "$jsonl_file" 2>/dev/null | \
    jq -rs --argjson limit "$limit" '
        .[-$limit:] | .[] |
        "\(.ts[0:16] // "")  [\(.role)]  \(.content[0:500])"
    ' 2>/dev/null
}

# Find the most recent JSONL session file for a given project path
find_latest_session() {
    local project_dir="$1"
    local encoded
    encoded=$(encode_claude_path "$project_dir")
    local sessions_dir="$HOME/.claude/projects/${encoded}"

    if [[ ! -d "$sessions_dir" ]]; then
        return 1
    fi

    # Find the most recently modified .jsonl file
    # shellcheck disable=SC2012
    ls -t "$sessions_dir"/*.jsonl 2>/dev/null | head -1
}

# Find latest session on a remote VPS
find_remote_latest_session() {
    local host="$1"
    local project_dir="$2"
    local encoded
    encoded=$(encode_claude_path "$project_dir")

    ssh -o ConnectTimeout=10 "$host" "
        SESSIONS_DIR=\"\$HOME/.claude/projects/${encoded}\"
        if [ -d \"\$SESSIONS_DIR\" ]; then
            ls -t \"\$SESSIONS_DIR\"/*.jsonl 2>/dev/null | head -1
        fi
    " 2>/dev/null
}

# Main conversation command
run_conversation() {
    local name="$1"
    local limit="${2:-20}"

    if ! registry_session_exists "$name"; then
        print_error "Session '$name' not found in registry"
        return 1
    fi

    local type path host
    type=$(registry_get_field "$name" "type")
    path=$(registry_get_field "$name" "path")
    host=$(registry_get_field "$name" "host")

    echo ""
    printf "  ${C_BOLD}Conversation: %s${C_RESET} (last %d messages)\n" "$name" "$limit"
    echo "  ────────────────────────────────────────────"

    case "$type" in
        local|utility)
            local jsonl_file
            jsonl_file=$(find_latest_session "$path")
            if [[ -z "$jsonl_file" ]]; then
                printf "  ${C_DIM}(no session transcript found)${C_RESET}\n"
                echo ""
                return 0
            fi

            printf "  ${C_DIM}Source: %s${C_RESET}\n\n" "$(basename "$jsonl_file")"
            parse_conversation "$jsonl_file" "$limit" | while IFS= read -r line; do
                # Color-code by role
                if [[ "$line" == *"[user]"* ]]; then
                    printf "  ${C_CYAN}%s${C_RESET}\n" "$line"
                elif [[ "$line" == *"[assistant]"* ]]; then
                    printf "  ${C_GREEN}%s${C_RESET}\n" "$line"
                else
                    printf "  %s\n" "$line"
                fi
            done
            ;;
        remote)
            local remote_jsonl
            remote_jsonl=$(find_remote_latest_session "$host" "$path")
            if [[ -z "$remote_jsonl" ]]; then
                printf "  ${C_DIM}(no session transcript found)${C_RESET}\n"
                echo ""
                return 0
            fi

            printf "  ${C_DIM}Source: %s${C_RESET}\n\n" "$(basename "$remote_jsonl")"

            # Stream the JSONL from VPS and parse locally
            ssh -o ConnectTimeout=10 "$host" "cat '$remote_jsonl'" 2>/dev/null | \
            jq -r --argjson limit "$limit" '
                select(.type == "user" or .type == "assistant") |
                select(.message.role == "user" or .message.role == "assistant") |
                {
                    role: .message.role,
                    ts: (.timestamp // ""),
                    content: (
                        if .message.role == "user" then
                            [.message.content[] |
                                select(type == "object" and .type == "text") |
                                .text
                            ] | join("\n")
                        elif .message.role == "assistant" then
                            [.message.content[] |
                                select(type == "object" and .type == "text") |
                                .text
                            ] | join("\n")
                        else ""
                        end
                    )
                } |
                select(.content != "" and .content != null)
            ' 2>/dev/null | \
            jq -rs --argjson limit "$limit" '
                .[-$limit:] | .[] |
                "\(.ts[0:16] // "")  [\(.role)]  \(.content[0:500])"
            ' 2>/dev/null | while IFS= read -r line; do
                if [[ "$line" == *"[user]"* ]]; then
                    printf "  ${C_CYAN}%s${C_RESET}\n" "$line"
                elif [[ "$line" == *"[assistant]"* ]]; then
                    printf "  ${C_GREEN}%s${C_RESET}\n" "$line"
                else
                    printf "  %s\n" "$line"
                fi
            done
            ;;
    esac

    echo ""
}
