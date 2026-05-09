# Parse Gemini native response
parse_resp() {
    local resp="$1"
    # Extract text and tool calls
    local text=$(echo "$resp" | jq -r '.candidates[0].content.parts[0].text // empty')
    local tool_calls=$(echo "$resp" | jq -c '.candidates[0].content.parts[] | select(.functionCall != null) | .functionCall // empty' | jq -s -c '.')
    
    if [[ "$tool_calls" == "[]" ]]; then tool_calls="null"; fi
    
    printf 'RAW:%s\nTC:%s\nTEXT:%s\n' "$resp" "$tool_calls" "$text"
}
