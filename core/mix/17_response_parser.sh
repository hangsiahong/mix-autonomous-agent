# Parse LLM response (supports OpenAI and Gemini Native)
parse_resp() {
    local resp="$1"
    local text=""
    local tool_calls="null"

    if echo "$resp" | jq -e '.candidates' >/dev/null 2>&1; then
        # Gemini Native
        text=$(echo "$resp" | jq -r '.candidates[0].content.parts[] | select(.text != null) | .text' | tr '\n' ' ' | sed 's/ $//')
        
        local g_tc=$(echo "$resp" | jq -c '.candidates[0].content.parts[] | select(.functionCall != null) | .functionCall' 2>/dev/null | jq -s -c '.')
        if [[ "$g_tc" != "[]" && "$g_tc" != "null" ]]; then
            # Convert Gemini functionCall to OpenAI tool_call format for consistency in history
            tool_calls=$(echo "$g_tc" | jq -c 'map({id: "call_" + (now | tostring), type: "function", function: {name: .name, arguments: (.args | tojson)}})')
        fi
    elif echo "$resp" | jq -e '.choices' >/dev/null 2>&1; then
        # OpenAI Format
        text=$(echo "$resp" | jq -r '.choices[0].message.content // empty')
        tool_calls=$(echo "$resp" | jq -c '.choices[0].message.tool_calls // empty')
    fi
    
    [ -z "$tool_calls" ] && tool_calls="null"
    
    printf 'RAW:%s\nTC:%s\nTEXT:%s\n' "$resp" "$tool_calls" "$text"
}
