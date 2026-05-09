#!/bin/bash
# core/ui.sh - Pluggable UI

ui_msg() {
    local msg="$1"
    if [ -n "$TG_CHAT_ID" ]; then
        tg_send "$TG_CHAT_ID" "$msg"
    else
        echo -e "$msg"
    fi
}

ui_error() {
    local msg="$1"
    if [ -n "$TG_CHAT_ID" ]; then
        tg_send "$TG_CHAT_ID" "❌ *Error*: $msg"
    else
        echo -e "\033[1;31mError:\033[0m $msg"
    fi
}
