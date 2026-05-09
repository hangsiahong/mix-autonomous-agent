#!/bin/bash
# Tool: read_error_log
# Description: Read the recent API errors logged by the system.

LIMIT="${TOOL_limit:-10}"
LOG_FILE="brain/state/error_log.jsonl"

if [[ ! -f "$LOG_FILE" ]]; then
    echo "No errors logged yet."
    exit 0
fi

tail -n "$LIMIT" "$LOG_FILE"
