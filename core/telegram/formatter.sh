#!/bin/bash
# core/telegram/formatter.sh - Text processing

# Escape for MarkdownV2
tg_escape() {
    echo "$1" | sed 's/\([_*[]()~`>#+\-=|{}.!]\)/\\\1/g'
}

# Convert Markdown to Telegram HTML — delegates to tools/md_to_html.py
# (single source of truth; previously this file had a duplicate Python impl).
md_to_tg_html() {
    printf '%s' "$1" | python3 "${DIR:-$(pwd)}/tools/md_to_html.py"
}
