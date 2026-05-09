#!/bin/bash
# core/config.sh - Configuration management

CONFIG_FILE="${DIR}/brain/config.json"

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
