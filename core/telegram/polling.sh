#!/bin/bash
# core/telegram/polling.sh - Long polling logic

tg_poll() {
    local offset="$1"
    local timeout="${2:-30}"
    curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${offset}&timeout=${timeout}"
}
