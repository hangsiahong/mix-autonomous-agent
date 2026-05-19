#!/bin/bash
# tools/access_control.sh - Tool for agent to manage whitelist
#
# Every mutation is appended to brain/state/access_control.log (one line each,
# pipe-delimited: ts|action|target_id|by). The audit log exists so next time
# the agent asks "who did I unwhitelist last session?" it can grep one file
# instead of trawling thousands of lines of session history.

action="${TOOL_action}" # whitelist | revoke | sethome | log
target_id="${TOOL_target_id}"

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"

source "${_ROOT_DIR}/core/config.sh"

_AUDIT_LOG="${_ROOT_DIR}/brain/state/access_control.log"

_audit() {
    local _act="$1"
    local _tgt="$2"
    local _by="${TOOL_CHAT_ID:-${USER:-unknown}}"
    mkdir -p "$(dirname "$_AUDIT_LOG")"
    printf '%s|%s|%s|by:%s\n' \
        "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$_act" "$_tgt" "$_by" >> "$_AUDIT_LOG"
}

case "$action" in
    whitelist)
        if [[ -n "$target_id" ]]; then
            add_to_whitelist "$target_id"
            _audit whitelist "$target_id"
            echo "Successfully whitelisted $target_id (logged to brain/state/access_control.log)"
        else
            echo "Error: target_id is required for whitelist action"
        fi
        ;;
    revoke)
        if [[ -n "$target_id" ]]; then
            remove_from_whitelist "$target_id"
            _audit revoke "$target_id"
            echo "Successfully removed $target_id from whitelist (logged to brain/state/access_control.log)"
        else
            echo "Error: target_id is required for revoke action"
        fi
        ;;
    sethome)
        if [[ -n "$target_id" ]]; then
            set_home_chat "$target_id"
            _audit sethome "$target_id"
            echo "Successfully set $target_id as home chat (logged to brain/state/access_control.log)"
        else
            echo "Error: target_id is required for sethome action"
        fi
        ;;
    log|history|audit)
        # Fast "who changed access recently?" — no session-history trawling needed.
        if [[ -f "$_AUDIT_LOG" ]]; then
            tail -20 "$_AUDIT_LOG"
        else
            echo "(no access_control changes logged yet)"
        fi
        ;;
    *)
        echo "Error: unknown action '$action' (valid: whitelist | revoke | sethome | log)"
        ;;
esac
