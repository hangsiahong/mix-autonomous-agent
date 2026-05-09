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
        msg_count=$(echo "$HISTORY" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    fi

    local entry
    entry=$(CID="$chat_id" ST="$status" MOD="$MODEL" TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" MC="$msg_count" python3 -c "
import json, os
print(json.dumps({
    'ts': os.environ['TS'],
    'chat_id': os.environ['CID'],
    'status': os.environ['ST'],
    'model': os.environ['MOD'],
    'msg_count': int(os.environ['MC'])
}))
")

    echo "$entry" >> "$trajectory_file"

    # Trim to last 500 entries inline (cheap: runs in same process, avoids separate cron dependency)
    local line_count
    line_count=$(wc -l < "$trajectory_file" 2>/dev/null || echo 0)
    if [[ $line_count -gt 600 ]]; then
        tail -n 500 "$trajectory_file" > "${trajectory_file}.tmp" && mv "${trajectory_file}.tmp" "$trajectory_file"
    fi
}
