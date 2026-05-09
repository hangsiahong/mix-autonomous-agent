#!/bin/bash
# core/mix/38_rate_limit.sh - Rate Limit Tracking

RL_STATE_FILE="brain/state/rate_limits.json"

check_rate_limit() {
    local provider="$1"
    local model="$2"
    
    [ ! -f "$RL_STATE_FILE" ] && return 0
    
    local key="${provider}_${model}"
    local backoff_until=$(jq -r --arg k "$key" '.[$k] // 0' "$RL_STATE_FILE" 2>/dev/null)
    backoff_until=$(( ${backoff_until:-0} + 0 ))  # coerce to int
    local now=$(date +%s)
    
    if [ "$now" -lt "$backoff_until" ]; then
        local wait_time=$((backoff_until - now))
        echo "AMA: Model $model is rate-limited. Waiting $wait_time s..." >&2
        return 1
    fi
    return 0
}

mark_rate_limited() {
    local provider="$1"
    local model="$2"
    local delay="${3:-60}"
    
    mkdir -p "brain/state"
    [ ! -f "$RL_STATE_FILE" ] && echo "{}" > "$RL_STATE_FILE"
    
    local key="${provider}_${model}"
    local backoff_until=$(( $(date +%s) + delay ))
    
    local updated=$(jq --arg k "$key" --argjson v "$backoff_until" '.[$k] = $v' "$RL_STATE_FILE")
    echo "$updated" > "$RL_STATE_FILE"
}
