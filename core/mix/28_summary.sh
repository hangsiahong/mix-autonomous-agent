#!/bin/bash
# core/mix/28_summary.sh - Title and Summary generation

generate_title() {
    local session_id="$1"

    # Load last 4 messages from the saved history file directly (HISTORY var is session-local)
    local hist_file="brain/state/history_${session_id}.json"
    local snippet="[]"
    if [[ -f "$hist_file" ]]; then
        snippet=$(python3 -c "
import json, sys
h = json.load(open('$hist_file'))
# flatten array content to strings
out = []
for m in h[-6:]:
    c = m.get('content') or ''
    if isinstance(c, list):
        c = ' '.join(p.get('text','') for p in c if isinstance(p,dict))
    if m.get('role') in ('user','assistant') and c.strip():
        out.append({'role':m['role'],'content':c})
print(json.dumps(out))
" 2>/dev/null || echo '[]')
    fi

    [[ "$snippet" == "[]" || -z "$snippet" ]] && return

    local prompt="Based on the following conversation, generate a short (3-5 words) descriptive title. Respond ONLY with the title, no explanation.\n\n$snippet"
    
    # Use call_api with specific prompt
    local response=$(call_api "$prompt")
    local parsed=$(parse_resp "$response")
    local title=$(echo "$parsed" | grep "^TEXT:" | cut -c6- | head -1 | tr -d '"' | sed 's/^[[:space:]]*//' | cut -c1-60)
    
    if [[ -n "$title" && "$title" != "null" ]]; then
        # Save title to brain/state/titles.json
        local titles_file="brain/state/titles.json"
        mkdir -p "brain/state"
        [ ! -f "$titles_file" ] && echo "{}" > "$titles_file"
        
        local updated
        python3 -c "
import json, sys
tfile = sys.argv[1]
try: d = json.load(open(tfile))
except: d = {}
d[sys.argv[2]] = sys.argv[3]
open(tfile, 'w').write(json.dumps(d))
" "$titles_file" "$session_id" "$title"
        echo "Title generated: $title"
    fi
}
