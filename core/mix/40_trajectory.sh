#!/bin/bash
# core/mix/40_trajectory.sh - Log conversation trajectories

log_trajectory() {
    local chat_id="$1"
    local status="${2:-completed}" # completed or failed

    local trajectory_file="brain/state/trajectories.jsonl"
    mkdir -p "brain/state"

    # Store only metadata, not full history (avoids O(n²) file growth)
    local msg_count=0
    if [[ -n "$HISTORY" ]]; then
        msg_count=$(echo "$HISTORY" | jq 'length' 2>/dev/null || echo 0)
    fi

    local entry
    entry=$(jq -n \
        --arg chat_id "$chat_id" \
        --arg status "$status" \
        --arg model "$MODEL" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson msg_count "$msg_count" \
        '{ts: $ts, chat_id: $chat_id, status: $status, model: $model, msg_count: $msg_count}')

    echo "$entry" >> "$trajectory_file"

    # Trim to last 500 entries inline (cheap: runs in same process, avoids separate cron dependency)
    local line_count
    line_count=$(wc -l < "$trajectory_file" 2>/dev/null || echo 0)
    if [[ $line_count -gt 600 ]]; then
        tail -n 500 "$trajectory_file" > "${trajectory_file}.tmp" && mv "${trajectory_file}.tmp" "$trajectory_file"
    fi
}
