#!/bin/bash
# Test Google Provider (Vertex OpenAI-compatible)

# Load environment
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Set specific vars for the test
export PROVIDER="google"
export GOOGLE_MODE="vertex"
# export GOOGLE_VERTEX_KEY="..." (should be in .env)

# Load core
source core/config.sh
source core/mix/00_header.sh
source core/mix/11_history.sh
source core/mix/16_api.sh
source core/mix/18_streaming_api_call.sh
source core/mix/providers/google.sh

# Mock some values needed by the core
export HISTORY="[]"
export SYSTEM_PROMPT_FILE="/tmp/sys_prompt.txt"
echo "You are a helpful assistant." > "$SYSTEM_PROMPT_FILE"
export TOOLS_JSON="[]"
export MODEL="gemini-3.1-flash-lite-preview"
export TG_TOKEN="mock" # Not needed for call_api but maybe for stream
export INTERACTIVE="false"

echo "--- Activating Google Provider ---"
google_activate

echo "--- Testing google_get_api_key ---"
KEY=$(google_get_api_key)
if [[ "$KEY" == AQ.* ]]; then
  echo "Key detected as Static Vertex Key (AQ...)"
else
  echo "Key: ${KEY:0:10}..."
fi

echo "--- Testing google_extra_headers_json ---"
HEADERS=$(google_extra_headers_json)
echo "Headers: $HEADERS"

echo "--- Testing call_api (tool_call_id vs id) ---"
export MODEL="gemini-3-flash-preview"
export _GOOGLE_VERTEX_MODEL_PREFIX="google/"
export HISTORY='[
  {"role": "user", "content": "What time is it?"},
  {"role": "assistant", "content": null, "tool_calls": [{"id": "call_abc", "type": "function", "function": {"name": "sys_info", "arguments": "{}"}}]},
  {"role": "tool", "id": "call_abc", "name": "sys_info", "content": "12:00"}
]'

# Debug: Print payload
payload=$(_api_build_payload "false")
echo "Payload: $payload"

RESP=$(call_api)
echo "Response: $RESP"
