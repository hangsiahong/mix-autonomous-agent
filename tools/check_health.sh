#!/bin/bash
# Tool: check_health
# Description: Check the health of the AMA system, including file existence, syntax, and recent error rates.

echo "--- AMA Health Report ---"
echo "Time: $(date)"
echo "Uptime: $(uptime -p)"

echo -e "\n[Files]"
REQUIRED_FILES=("bot.sh" "core/mix/init.sh" "brain/tools.json" "brain/system_prompt.md")
for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        echo "OK: $f"
    else
        echo "MISSING: $f"
    fi
done

echo -e "\n[Syntax Check]"
for f in core/mix/*.sh; do
    bash -n "$f" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "OK: $f"
    else
        echo "FAIL: $f (Syntax Error)"
    fi
done

echo -e "\n[Recent Errors]"
if [[ -f "brain/state/error_log.jsonl" ]]; then
    python3 -c "
import json, sys
for line in open('brain/state/error_log.jsonl'):
    try:
        e = json.loads(line.strip())
        print(f\"{e.get('ts','')} | {e.get('reason','')} | {e.get('model','')}\")
    except: pass
" 2>/dev/null | tail -n 5
else
    echo "No errors logged."
fi

echo -e "\n[Disk Usage]"
df -h . | tail -n 1
