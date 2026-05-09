#!/bin/bash

# core/llm.sh - LLM Provider Adapter (Gemini Native)

if [[ -f ".env" ]]; then
    source .env
fi

# Default model
MODEL="${LLM_MODEL:-gemini-2.0-flash-exp}"
API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_KEY}"

llm_complete() {
    local messages_json="$1" # Array of {role, content}
    local tools_json="$2"    # Optional array of tool definitions

    local system_instr=$(echo "$messages_json" | jq -r '.[] | select(.role=="system") | .content' | tr '\n' ' ')
    # Convert OpenAI-style messages to Gemini contents
    local contents=$(echo "$messages_json" | jq -c '
        map(select(.role != "system")) |
        map(
            if .role == "user" then
                {role: "user", parts: [{text: .content}]}
            elif .role == "assistant" then
                {role: "model", parts: (
                    if .tool_calls then
                        .tool_calls | map({functionCall: .})
                    else
                        [{text: .content}]
                    end
                )}
            elif .role == "tool" then
                {role: "user", parts: [{functionResponse: {name: .name, response: {output: .content}}}]}
            else
                empty
            end
        )
    ')

    local payload=$(jq -n \
        --arg system "$system_instr" \
        --argjson contents "$contents" \
        '{
            system_instruction: { parts: [{text: $system}] },
            contents: $contents,
            generationConfig: {
                temperature: 0.7,
                maxOutputTokens: 2048
            }
        }')

    # Add tools if provided
    if [[ -n "$tools_json" && "$tools_json" != "null" ]]; then
        payload=$(echo "$payload" | jq --argjson tools "$tools_json" '. + {tools: [{function_declarations: $tools}]}')
    fi

    local response=$(curl -s -X POST "${API_URL}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    # Error handling
    local error_msg=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error_msg" ]]; then
        echo "LLM Error: $error_msg" >&2
        return 1
    fi

    echo "$response"
}

llm_parse_response() {
    local response="$1"
    # Extract text content
    echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty'
}

llm_parse_tools() {
    local response="$1"
    # Extract function calls
    echo "$response" | jq -c '.candidates[0].content.parts[] | select(.functionCall != null) | .functionCall // empty'
}
