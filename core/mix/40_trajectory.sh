#!/bin/bash
# core/mix/40_trajectory.sh - Log conversation trajectories

log_trajectory() {
    local chat_id="$1"
    local status="${2:-completed}" # completed or failed
    
    local trajectory_file="brain/state/trajectories.jsonl"
    mkdir -p "brain/state"
    
    # We use the current HISTORY
    # Convert HISTORY to ShareGPT-like format or just dump it
    local entry=$(jq -n \
        --arg chat_id "$chat_id" \
        --arg status "$status" \
        --arg model "$MODEL" \
        --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson history "$HISTORY" \
        '{ts: $ts, chat_id: $chat_id, status: $status, model: $model, history: $history}')
        
    echo "$entry" >> "$trajectory_file"
}
