#!/bin/bash
# core/mix/28_summary.sh - Title and Summary generation

generate_title() {
    local session_id="$1"
    local history=$(load_history "$session_id" | jq -c '.[-2:]')
    
    local prompt="Based on the conversation above, generate a short (3-5 words) descriptive title for this chat. Respond ONLY with the title."
    
    # Use call_api with specific prompt
    local response=$(call_api "$prompt")
    local parsed=$(parse_resp "$response")
    local title=$(echo "$parsed" | grep "^TEXT:" | cut -c6- | tr -d '"')
    
    if [[ -n "$title" && "$title" != "null" ]]; then
        # Save title to brain/state/titles.json
        local titles_file="brain/state/titles.json"
        mkdir -p "brain/state"
        [ ! -f "$titles_file" ] && echo "{}" > "$titles_file"
        
        local updated=$(jq --arg id "$session_id" --arg t "$title" '.[$id] = $t' "$titles_file")
        echo "$updated" > "$titles_file"
        echo "Title generated: $title"
    fi
}
