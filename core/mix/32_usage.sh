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
d = json.load(sys.stdin)
print(int(d.get('prompt_tokens', 0) or 0), int(d.get('completion_tokens', 0) or 0), int(d.get('total_tokens', 0) or 0))
" 2>/dev/null)"

    P="$p" C="$c" T="$t" TFILE="$totals_file" python3 -c "
import json, os
f = os.environ['TFILE']
try: d = json.load(open(f))
except: d = {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0}
d['prompt_tokens'] = d.get('prompt_tokens', 0) + int(os.environ['P'])
d['completion_tokens'] = d.get('completion_tokens', 0) + int(os.environ['C'])
d['total_tokens'] = d.get('total_tokens', 0) + int(os.environ['T'])
open(f, 'w').write(json.dumps(d))
"
}

log_tool_usage() {
    local chat_id="$1"
    local tool_name="$2"
    local timestamp=$(date +%s)
    
    local tool_log="brain/state/tool_usage.jsonl"
    echo "{\"ts\": $timestamp, \"chat_id\": \"$chat_id\", \"tool\": \"$tool_name\"}" >> "$tool_log"
}
