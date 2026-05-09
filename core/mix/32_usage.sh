#!/bin/bash
# core/mix/32_usage.sh - Usage Tracking

log_usage() {
    local chat_id="$1"
    local usage_json="$2"
    local model="$3"
    local timestamp=$(date +%s)
    
    [ -z "$usage_json" ] && return
    
    local usage_file="brain/state/usage_log.jsonl"
    mkdir -p "brain/state"
    
    # Append to daily log
    echo "{\"ts\": $timestamp, \"chat_id\": \"$chat_id\", \"model\": \"$model\", \"usage\": $usage_json}" >> "$usage_file"
    
    # Update totals
    local totals_file="brain/state/usage_totals.json"
    [ ! -f "$totals_file" ] && echo "{\"prompt_tokens\": 0, \"completion_tokens\": 0, \"total_tokens\": 0}" > "$totals_file"
    
    local p=$(echo "$usage_json" | jq -r '.prompt_tokens // 0')
    local c=$(echo "$usage_json" | jq -r '.completion_tokens // 0')
    local t=$(echo "$usage_json" | jq -r '.total_tokens // 0')
    
    local updated=$(jq --argjson p "$p" --argjson c "$c" --argjson t "$t" \
        '.prompt_tokens += $p | .completion_tokens += $c | .total_tokens += $t' "$totals_file")
    echo "$updated" > "$totals_file"
}

log_tool_usage() {
    local chat_id="$1"
    local tool_name="$2"
    local timestamp=$(date +%s)
    
    local tool_log="brain/state/tool_usage.jsonl"
    echo "{\"ts\": $timestamp, \"chat_id\": \"$chat_id\", \"tool\": \"$tool_name\"}" >> "$tool_log"
}
