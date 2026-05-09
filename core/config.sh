#!/bin/bash
# core/config.sh - Configuration management

_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_CONFIG_DIR/.." && pwd)"
CONFIG_FILE="${_ROOT_DIR}/brain/config.json"

# Default config if not exists
if [ ! -f "$CONFIG_FILE" ]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    echo '{"whitelist": [], "home_chat": null}' > "$CONFIG_FILE"
fi

load_config() {
    cat "$CONFIG_FILE"
}

save_config() {
    echo "$1" > "$CONFIG_FILE"
}

is_whitelisted() {
    local id="$1"
    # Always whitelist the user who started the bot or defined in TG_ADMIN
    if [[ -n "${TG_ADMIN}" && "$id" == "${TG_ADMIN}" ]]; then
        return 0
    fi
    
    local whitelist=$(load_config | jq -r '.whitelist[]')
    for entry in $whitelist; do
        if [[ "$id" == "$entry" ]]; then
            return 0
        fi
    done
    return 1
}

add_to_whitelist() {
    local id="$1"
    local config=$(load_config)
    local new_config=$(echo "$config" | jq --arg id "$id" '.whitelist += [$id] | .whitelist |= unique')
    save_config "$new_config"
}

set_home_chat() {
    local id="$1"
    local config=$(load_config)
    local new_config=$(echo "$config" | jq --arg id "$id" '.home_chat = $id')
    save_config "$new_config"
    # Also ensure home chat is whitelisted
    add_to_whitelist "$id"
}

get_topic_config() {
    local chat_id="$1"
    local thread_id="$2"
    local config=$(load_config)
    
    # Try to find topic in group_topics
    echo "$config" | jq -c --arg cid "$chat_id" --arg tid "$thread_id" \
        '.group_topics[]? | select(.chat_id == $cid) | .topics[]? | select(.thread_id == $tid)'
}

set_topic_config() {
    local chat_id="$1"
    local thread_id="$2"
    local topic_data="$3" # JSON object
    
    local config=$(load_config)
    
    # Ensure group_topics exists
    config=$(echo "$config" | jq 'if has("group_topics") then . else . + {group_topics: []} end')
    
    # Check if chat_id exists in group_topics
    local chat_exists=$(echo "$config" | jq --arg cid "$chat_id" 'any(.group_topics[]; .chat_id == $cid)')
    
    if [[ "$chat_exists" == "false" ]]; then
        config=$(echo "$config" | jq --arg cid "$chat_id" '.group_topics += [{chat_id: $cid, topics: []}]')
    fi
    
    # Update or add topic
    local updated_config=$(echo "$config" | jq --arg cid "$chat_id" --arg tid "$thread_id" --argjson data "$topic_data" '
        .group_topics |= map(
            if .chat_id == $cid then
                .topics |= (
                    if any(.[]; .thread_id == $tid) then
                        map(if .thread_id == $tid then $data else . end)
                    else
                        . + [$data]
                    end
                )
            else . end
        )')
    
    save_config "$updated_config"
}
