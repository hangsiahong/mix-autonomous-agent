#!/bin/bash
# core/mix/36_think_scrubber.sh - Scrub reasoning blocks from assistant text

# Removes <think>, <thinking>, <reasoning>, <thought> blocks
# Both paired and unterminated (at end of text)
scrub_thought() {
    local text="$1"
    
    # 1. Remove paired tags: <think>...</think>
    # Using python for reliable multi-line non-greedy regex
    local cleaned=$(echo "$text" | python3 -c "
import sys, re
text = sys.stdin.read()
# Case-insensitive, multi-line, non-greedy
patterns = [r'<(think|thinking|reasoning|thought)>.*?</\1>', r'<(think|thinking|reasoning|thought)>.*']
for p in patterns:
    text = re.sub(p, '', text, flags=re.DOTALL | re.IGNORECASE)
print(text.strip())
")
    echo "$cleaned"
}
