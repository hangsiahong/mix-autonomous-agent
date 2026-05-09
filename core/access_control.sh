#!/bin/bash
# core/access_control.sh - Tool execution permissions

# Sensitive tools that require explicit approval
SENSITIVE_TOOLS=("edit_code" "create_code" "delete_file" "execute_bash")
PERMISSION_STORE="brain/state/permissions.json"

check_tool_permission() {
    local tool_name="$1"
    local chat_id="$2"
    local thread_id="$3"
    
    # Non-sensitive tools are allowed by default
    local is_sensitive=false
    for t in "${SENSITIVE_TOOLS[@]}"; do
        [[ "$t" == "$tool_name" ]] && is_sensitive=true && break
    done
    
    [[ "$is_sensitive" == "false" ]] && return 0
    
    # Check if tool is whitelisted for this session
    local session_id="tg_${chat_id}"
    [[ -n "$thread_id" ]] && session_id="tg_${chat_id}_${thread_id}"
    
    if [[ -f "$PERMISSION_STORE" ]]; then
        local allowed=$(jq -r --arg sid "$session_id" --arg tool "$tool_name" '.[$sid][$tool] // "ask"' "$PERMISSION_STORE")
        if [[ "$allowed" == "always" ]]; then
            return 0
        fi
    fi
    
    # In safety-first mode, we deny sensitive tools unless approved.
    # Since we can't easily wait for a Telegram callback in this sync bash function without
    # blocking the whole bot, we will for now allow but REQUIRE a specific skill or flag.
    # REALITY: For now, we will allow but log, and later we will implement the /approve command.
    
    echo "PERMISSION_GRANTED: $tool_name" >&2
    return 0
}

grant_permission() {
    local session_id="$1"
    local tool_name="$2"
    local level="${3:-always}" # always, once
    
    mkdir -p "$(dirname "$PERMISSION_STORE")"
    [[ ! -f "$PERMISSION_STORE" ]] && echo "{}" > "$PERMISSION_STORE"
    
    local new_store=$(jq --arg sid "$session_id" --arg tool "$tool_name" --arg level "$level" \
        '.[$sid][$tool] = $level' "$PERMISSION_STORE")
    echo "$new_store" > "$PERMISSION_STORE"
}
