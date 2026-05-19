#!/bin/bash
# Provider: Anthropic Claude (native API — not OpenAI-compat)
# Enables prompt caching (90% cost reduction on cached system prompt + tools)
#
# Config:
#   PROVIDER=anthropic
#   API_KEY=sk-ant-...
#   MODEL=claude-sonnet-4-6   (or claude-opus-4-7, claude-haiku-4-5-20251001)
#   BASE_URL=https://api.anthropic.com/v1

anthropic_activate() {
    BASE_URL="${BASE_URL:-https://api.anthropic.com/v1}"
}

anthropic_get_api_key() {
    echo "${ANTHROPIC_API_KEY:-$API_KEY}"
}

# Returns extra headers for Anthropic:
# - anthropic-version: required by native API
# - anthropic-beta: prompt-caching-2024-07-31  (enables cache_control in messages)
#
# The Authorization header is suppressed so the harness uses Bearer with our key.
# Anthropic native uses "x-api-key" instead — we override via the header below.
anthropic_extra_headers_json() {
    local _key="${ANTHROPIC_API_KEY:-$API_KEY}"
    printf '{
  "x-api-key": "%s",
  "anthropic-version": "2023-06-01",
  "anthropic-beta": "prompt-caching-2024-07-31",
  "Authorization": null
}' "$_key"
}
