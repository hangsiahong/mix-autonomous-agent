#!/bin/bash
# core/telegram/formatter.sh - Text processing

# Escape for MarkdownV2
tg_escape() {
    echo "$1" | sed 's/\([_*[]()~`>#+\-=|{}.!]\)/\\\1/g'
}

# Simple Markdown to MarkdownV2 conversion if needed (placeholder)
tg_to_v2() {
    tg_escape "$1"
}
