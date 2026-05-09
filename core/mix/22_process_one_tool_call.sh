# Process tool call
process_tc() {
    local chat_id="$1"
    local msg_id="$2"
    local tc_json="$3" # Single tool call object
    
    local name=$(echo "$tc_json" | jq -r '.name')
    local args=$(echo "$tc_json" | jq -c '.args')
    
    # Update Telegram status
    tg_edit "$chat_id" "$msg_id" "⚒ Running tool: \`$name\`..."
    
    local output=$(run_tool "$name" "$args")
    
    # Return output
    echo "$output"
}
