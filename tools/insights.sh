#!/bin/bash
# tools/insights.sh - Display usage insights

TOTALS_FILE="brain/state/usage_totals.json"
TOOL_LOG="brain/state/tool_usage.jsonl"

if [ ! -f "$TOTALS_FILE" ]; then
    echo "No usage data found yet."
    exit 0
fi

PROMPT_TOKENS=$(jq -r '.prompt_tokens' "$TOTALS_FILE")
COMPLETION_TOKENS=$(jq -r '.completion_tokens' "$TOTALS_FILE")
TOTAL_TOKENS=$(jq -r '.total_tokens' "$TOTALS_FILE")

echo "📊 **AMA Usage Insights**"
echo ""
echo "**Token Consumption:**"
echo "- Prompt: $PROMPT_TOKENS"
echo "- Completion: $COMPLETION_TOKENS"
echo "- Total: $TOTAL_TOKENS"
echo ""

if [ -f "$TOOL_LOG" ]; then
    echo "**Top Tools Used:**"
    sort "$TOOL_LOG" | jq -r '.tool' | sort | uniq -c | sort -nr | head -n 5 | while read -r count tool; do
        echo "- $tool: $count times"
    done
fi
