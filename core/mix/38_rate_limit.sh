#!/bin/bash
# core/mix/38_rate_limit.sh - Rate Limit Tracking

RL_STATE_FILE="brain/state/rate_limits.json"

check_rate_limit() {
    local provider="$1"
    local model="$2"
    
    [ ! -f "$RL_STATE_FILE" ] && return 0
    
    local key="${provider}_${model}"
    local backoff_until
    backoff_until=$(KEY="$key" python3 -c "
import json, os
try:
    d = json.load(open('$RL_STATE_FILE'))
    print(d.get(os.environ['KEY'], 0) or 0)
except:
    print(0)
" 2>/dev/null)
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
    
    KEY="$key" BU="$backoff_until" python3 -c "
import json, os
f = '$RL_STATE_FILE'
try: d = json.load(open(f))
except: d = {}
d[os.environ['KEY']] = int(os.environ['BU'])
open(f, 'w').write(json.dumps(d))
"
}
