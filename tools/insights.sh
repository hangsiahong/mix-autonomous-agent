#!/bin/bash
# tools/insights.sh - Display usage insights

TOTALS_FILE="brain/state/usage_totals.json"
TOOL_LOG="brain/state/tool_usage.jsonl"

if [ ! -f "$TOTALS_FILE" ]; then
    echo "No usage data found yet."
    exit 0
fi

read -r PROMPT_TOKENS COMPLETION_TOKENS TOTAL_TOKENS <<< "$(python3 -c "
import json
try:
    d = json.load(open('$TOTALS_FILE'))
    print(d.get('prompt_tokens',0), d.get('completion_tokens',0), d.get('total_tokens',0))
except:
    print(0, 0, 0)
" 2>/dev/null)"

echo "📊 **AMA Usage Insights**"
echo ""
echo "**Token Consumption:**"
echo "- Prompt: $PROMPT_TOKENS"
echo "- Completion: $COMPLETION_TOKENS"
echo "- Total: $TOTAL_TOKENS"
echo ""

if [ -f "$TOOL_LOG" ]; then
    echo "**Top Tools Used:**"
    python3 -c "
import json, sys
from collections import Counter
tools = []
for line in open('$TOOL_LOG'):
    try:
        tools.append(json.loads(line.strip()).get('tool',''))
    except: pass
for tool, count in Counter(tools).most_common(5):
    print(count, tool)
" 2>/dev/null | while read -r count tool; do
        echo "- $tool: $count times"
    done
fi
