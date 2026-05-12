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
    
    local p c t
    read -r p c t <<< "$(echo "$usage_json" | python3 -c "
import json, sys
d = json.loads(open(sys.argv[1]).read())
print(int(d.get('prompt_tokens', 0) or 0), int(d.get('completion_tokens', 0) or 0), int(d.get('total_tokens', 0) or 0))
" 2>/dev/null)"

    python3 -c "
import json, sys
f = sys.argv[1]
try: d = json.load(open(f))
except: d = {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0}
d['prompt_tokens'] = d.get('prompt_tokens', 0) + int(sys.argv[2])
d['completion_tokens'] = d.get('completion_tokens', 0) + int(sys.argv[3])
d['total_tokens'] = d.get('total_tokens', 0) + int(sys.argv[4])
open(f, 'w').write(json.dumps(d))
" "$totals_file" "${p:-0}" "${c:-0}" "${t:-0}"

    # Mirror token counts to SQLite session DB in background
    # Note: chat_id here is actually session_id (e.g. tg_670967877) — use as-is
    ( python3 tools/session_db.py update "$chat_id" --tokens "${p:-0}" "${c:-0}" \
        --model "$model" > /dev/null 2>&1 & )
}

log_tool_usage() {
    local chat_id="$1"
    local tool_name="$2"
    local timestamp=$(date +%s)
    
    local tool_log="brain/state/tool_usage.jsonl"
    echo "{\"ts\": $timestamp, \"chat_id\": \"$chat_id\", \"tool\": \"$tool_name\"}" >> "$tool_log"
}
