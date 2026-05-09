#!/bin/bash
# core/mix/36_think_scrubber.sh - Scrub reasoning blocks from assistant text

# Removes <think>, <thinking>, <reasoning>, <thought>, <REASONING_SCRATCHPAD> blocks
# Both paired and unterminated. Handles all known reasoning tag variants.
scrub_thought() {
    local text="$1"

    local cleaned=$(echo "$text" | python3 -c "
import sys, re
text = sys.stdin.read()
TAGS = r'think|thinking|reasoning|thought|REASONING_SCRATCHPAD'
text = re.sub(r'<(' + TAGS + r')>[\s\S]*?</\1>', '', text, flags=re.IGNORECASE)
text = re.sub(r'<(' + TAGS + r')>[\s\S]*', '', text, flags=re.IGNORECASE)
text = re.sub(r'</(' + TAGS + r')>', '', text, flags=re.IGNORECASE)
print(text.strip())
")
    echo "$cleaned"
}
