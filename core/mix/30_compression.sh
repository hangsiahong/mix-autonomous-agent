#!/bin/bash
# core/mix/30_compression.sh - Summary-based context compression

# Thresholds
COMPRESSION_THRESHOLD=25  # Start compressing if messages > 25
KEEP_LAST_N=8             # Always keep the last 8 messages as-is
KEEP_FIRST_N=2            # Always keep the first 2 messages (usually intro/setup)

compress_history() {
    local chat_id="$1"
    local count=$(echo "$HISTORY" | jq 'length')
    
    if [ "$count" -le "$COMPRESSION_THRESHOLD" ]; then
        return
    fi

    echo "AMA: Compressing context for $chat_id..."

    # 1. Identify slices
    local end_index=$((count - KEEP_LAST_N))
    local start_index=$KEEP_FIRST_N
    
    if [ "$start_index" -ge "$end_index" ]; then
        return # Not enough room to compress
    fi

    # 2. Extract middle messages for summarization
    local middle_msgs=$(echo "$HISTORY" | jq -c ".[$start_index:$end_index]")
    
    # 3. Request Summary from LLM
    local summary_prompt="The following is a middle portion of a conversation history. 
Summarize the key events, decisions, and information exchanged in these turns. 
Focus on what is still relevant for the ongoing task. 
Format as a concise bulleted list.
If tools were used, mention the outcomes.
Respond ONLY with the summary.

CONVERSATION TO SUMMARIZE:
$middle_msgs"

    # Use call_api (non-streaming)
    local summary_response=$(call_api "$summary_prompt")
    local summary_text=$(echo "$summary_response" | jq -r '.choices[0].message.content // empty')

    if [[ -z "$summary_text" ]]; then
        echo "AMA: Compression failed (empty summary)."
        return
    fi

    # 4. Build new history
    local first_part=$(echo "$HISTORY" | jq -c ".[0:$start_index]")
    local last_part=$(echo "$HISTORY" | jq -c ".[$end_index:]")
    
    local summary_msg=$(jq -n --arg text "[CONTEXT SUMMARY]:\n$summary_text" \
        '{role: "system", content: $text}')

    # 5. Archive the compressed part to long-term memory before replacing
    echo "$middle_msgs" | jq -c '.[]' | while read -r msg; do
        local role=$(echo "$msg" | jq -r '.role')
        local content=$(echo "$msg" | jq -r 'if .content | type == "array" then .content | map(.text // "") | join(" ") else .content // "" end')
        if [[ -n "$content" && "$content" != "null" ]]; then
             python3 "tools/memory_helper.py" save "[$role]: $content" "{\"chat_id\": \"$chat_id\", \"type\": \"archived_during_compression\"}" >/dev/null 2>&1
        fi
    done

    # Assemble new history
    HISTORY=$(echo "$first_part" | jq -c ". + [$summary_msg] + $last_part")
    
    echo "AMA: Context compressed successfully."
    save_history "$chat_id"
}
