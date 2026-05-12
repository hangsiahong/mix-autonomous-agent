#!/bin/bash
# extensions/cron/run.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${DIR}/core/mix/00_header.sh"
source "${DIR}/core/mix/16_api.sh"
source "${DIR}/core/mix/34_error_classifier.sh"
source "${DIR}/core/mix/38_rate_limit.sh"
source "${DIR}/core/mix/01_config.sh"

echo "[$(date)] Running background maintenance..."

# 1. Check Error Log for patterns
if [[ -f "${DIR}/brain/state/error_log.jsonl" ]]; then
    ERROR_COUNT=$(tail -n 100 "${DIR}/brain/state/error_log.jsonl" | wc -l)
    if [[ "$ERROR_COUNT" -gt 50 ]]; then
        echo "High error rate detected ($ERROR_COUNT in last 100). Needs attention."
        # Maybe send alert to TG_ADMIN if home_chat set
        # This is hard since we don't have chat_id easily here
    fi
fi

# 2. Cleanup log files (keep last N lines)
for logfile in "${DIR}/brain/state/trajectories.jsonl" \
               "${DIR}/brain/state/tool_usage.jsonl" \
               "${DIR}/brain/state/usage_log.jsonl" \
               "${DIR}/brain/state/error_log.jsonl"; do
    if [[ -f "$logfile" ]]; then
        local_keep=500
        [[ "$logfile" == *tool_usage* || "$logfile" == *error_log* ]] && local_keep=200
        line_count=$(wc -l < "$logfile")
        if [[ $line_count -gt $((local_keep + 100)) ]]; then
            tail -n "$local_keep" "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
            echo "[$(date)] Trimmed $logfile to $local_keep lines"
        fi
    fi
done

# 3. Monthly memory pruning — remove memories unused for 30+ days
MEMORY_PRUNE_MARKER="${DIR}/brain/state/.memory_last_pruned"
_now=$(date +%s)
_last_prune=0
if [[ -f "$MEMORY_PRUNE_MARKER" ]]; then
    _last_prune=$(cat "$MEMORY_PRUNE_MARKER" 2>/dev/null || echo 0)
fi
_days_since=$(( (_now - _last_prune) / 86400 ))
if [[ $_days_since -ge 30 ]]; then
    echo "[$(date)] Running monthly memory pruning (${_days_since} days since last prune)..."
    _prune_result=$(python3 "${DIR}/tools/memory_helper.py" prune 30 2>/dev/null)
    echo "[$(date)] $_prune_result"
    echo "$_now" > "$MEMORY_PRUNE_MARKER"
fi

# 4. Weekly memory consolidation (openclaw dreaming pattern):
#    Distill session recaps into concise facts and merge into brain/state/MEMORY.md
MEMORY_CONSOLIDATE_MARKER="${DIR}/brain/state/.memory_last_consolidated"
_last_consolidate=0
if [[ -f "$MEMORY_CONSOLIDATE_MARKER" ]]; then
    _last_consolidate=$(cat "$MEMORY_CONSOLIDATE_MARKER" 2>/dev/null || echo 0)
fi
_days_since_consolidate=$(( (_now - _last_consolidate) / 86400 ))
if [[ $_days_since_consolidate -ge 7 ]]; then
    echo "[$(date)] Running weekly memory consolidation..."
    _recap_file="${DIR}/brain/state/session_recaps.jsonl"
    if [[ -f "$_recap_file" && -s "$_recap_file" ]]; then
        _mem_file="${DIR}/brain/state/MEMORY.md"
        _current_memory=""
        [[ -f "$_mem_file" ]] && _current_memory=$(cat "$_mem_file")

        _consolidation_result=$(python3 -c "
import json, sys, subprocess, os
recap_file = sys.argv[1]
mem_file = sys.argv[2]
api_key = os.environ.get('API_KEY') or os.environ.get('GEMINI_KEY') or ''
model = os.environ.get('MODEL', 'gemini-2.5-flash')
base_url = os.environ.get('BASE_URL', 'https://generativelanguage.googleapis.com/v1beta/openai')

# Read last 20 recaps
try:
    lines = open(recap_file).readlines()
    recaps = []
    for line in lines[-20:]:
        e = json.loads(line)
        recaps.append(e.get('recap','').strip())
    recaps_text = '\n\n---\n\n'.join(recaps[:10])
except Exception as e:
    print(f'Error reading recaps: {e}', file=sys.stderr)
    sys.exit(1)

current_memory = open(mem_file).read().strip() if os.path.exists(mem_file) else ''

prompt = f'''You are a memory consolidator. Review these session recaps and extract NEW facts worth keeping long-term.

CURRENT MEMORY.md (what is already known):
{current_memory[:2000] if current_memory else '(empty)'}

RECENT SESSION RECAPS:
{recaps_text[:3000]}

Your task: Output ONLY new facts not already in MEMORY.md. Format as a concise bullet list.
Rules:
- Only include stable, reusable facts (user preferences, environment facts, recurring patterns)
- Skip one-off tasks, completed work, or things that change frequently
- Max 10 new bullets. If nothing new, output exactly: NO_NEW_FACTS
'''

import requests
resp = requests.post(
    f'{base_url}/chat/completions',
    headers={'Authorization': f'Bearer {api_key}', 'Content-Type': 'application/json'},
    json={'model': model, 'messages': [{'role':'user','content':prompt}], 'max_tokens': 500},
    timeout=30
)
if resp.ok:
    result = resp.json().get('choices',[{}])[0].get('message',{}).get('content','').strip()
    if result and result != 'NO_NEW_FACTS' and len(result) > 10:
        print(result)
    else:
        print('NO_NEW_FACTS')
else:
    print(f'API error {resp.status_code}', file=sys.stderr)
    sys.exit(1)
" "$_recap_file" "$_mem_file" 2>/dev/null)

        if [[ -n "$_consolidation_result" && "$_consolidation_result" != "NO_NEW_FACTS" ]]; then
            # Append new facts to MEMORY.md
            _ts=$(date '+%Y-%m-%d')
            {
                [[ -s "$_mem_file" ]] && cat "$_mem_file" && echo ""
                echo ""
                echo "## Consolidated from session recaps ($_ts)"
                echo "$_consolidation_result"
            } > "${_mem_file}.tmp" && mv "${_mem_file}.tmp" "$_mem_file"
            echo "[$(date)] Memory consolidated: new facts added to MEMORY.md"
        else
            echo "[$(date)] Memory consolidation: no new facts to add"
        fi
    fi
    echo "$_now" > "$MEMORY_CONSOLIDATE_MARKER"
fi

echo "[$(date)] Maintenance complete."
