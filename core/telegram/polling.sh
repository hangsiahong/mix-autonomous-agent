#!/bin/bash
# core/telegram/polling.sh - Long polling logic

# Telegram's default allowed_updates does NOT include message_reaction —
# we have to opt in explicitly. The list below is the default set
# (message, edited_message, callback_query) + message_reaction so the bot
# receives user reactions on its own messages (used for learning capture).
# Per Telegram docs, providing allowed_updates means YOU must list everything
# you want — anything not listed will be silently dropped.
_TG_ALLOWED_UPDATES='["message","edited_message","callback_query","message_reaction"]'

tg_poll() {
    local offset="$1"
    local timeout="${2:-30}"
    # URL-encode the JSON allowed_updates value (Python's quote handles brackets/commas).
    local enc
    enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$_TG_ALLOWED_UPDATES")
    curl -s "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${offset}&timeout=${timeout}&allowed_updates=${enc}"
}
