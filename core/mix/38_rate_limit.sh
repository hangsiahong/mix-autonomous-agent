#!/bin/bash
# core/mix/38_rate_limit.sh - Rate Limit Tracking

RL_STATE_FILE="brain/state/rate_limits.json"

check_rate_limit() {
    local provider="$1"
    local model="$2"
    
    [ ! -f "$RL_STATE_FILE" ] && return 0
    
    local key="${provider}_${model}"
    local backoff_until
    backoff_until=$(python3 -c "
import json, sys
try:
    d = json.load(open('$RL_STATE_FILE'))
    print(d.get(sys.argv[1], 0) or 0)
except:
    print(0)
" "$key" 2>/dev/null)
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
    # _AMA_NO_RATE_MARK=1: background tasks (reflection, recap) set this so their
    # 429s don't poison the rate limit state for the main agent turn.
    [[ "${_AMA_NO_RATE_MARK:-0}" == "1" ]] && return 0

    local provider="$1"
    local model="$2"
    local delay="${3:-60}"

    mkdir -p "brain/state"
    [ ! -f "$RL_STATE_FILE" ] && echo "{}" > "$RL_STATE_FILE"

    local key="${provider}_${model}"
    local backoff_until=$(( $(date +%s) + delay ))
    
    python3 -c "
import json, sys
f = '$RL_STATE_FILE'
try: d = json.load(open(f))
except: d = {}
d[sys.argv[1]] = int(sys.argv[2])
open(f, 'w').write(json.dumps(d))
" "$key" "$backoff_until"
}
