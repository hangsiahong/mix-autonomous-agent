#!/bin/bash
# tools/access_control.sh - Tool for agent to manage whitelist

action="${TOOL_action}" # whitelist, sethome
target_id="${TOOL_target_id}"

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"

source "${_ROOT_DIR}/core/config.sh"

case "$action" in
    whitelist)
        if [[ -n "$target_id" ]]; then
            add_to_whitelist "$target_id"
            echo "Successfully whitelisted $target_id"
        else
            echo "Error: target_id is required for whitelist action"
        fi
        ;;
    sethome)
        if [[ -n "$target_id" ]]; then
            set_home_chat "$target_id"
            echo "Successfully set $target_id as home chat"
        else
            echo "Error: target_id is required for sethome action"
        fi
        ;;
    *)
        echo "Error: unknown action $action"
        ;;
esac
