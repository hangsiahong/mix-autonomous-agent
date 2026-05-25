# ─── Provider: Xiaomi MiMo ───────────────────────────────────────────────────
# OpenAI-compatible API for Xiaomi's MiMo model family.
# https://token-plan-sgp.xiaomimimo.com
#
# Config:
#   PROVIDER=mimo
#   MODEL=mimo-v2.5-pro        (lowercase! verified via /v1/models)
#   MIMO_API_KEY=tp-...
#
# Chat models (lowercase IDs): mimo-v2.5-pro, mimo-v2.5, mimo-v2-pro, mimo-v2-omni
# TTS models (separate endpoint, not used by the chat loop):
#   mimo-v2.5-tts, mimo-v2.5-tts-voiceclone, mimo-v2.5-tts-voicedesign, mimo-v2-tts
#
# Notes:
# - Thinking models return chain-of-thought in `reasoning_content` (R1-style),
#   NOT in standard OpenAI fields. Existing parsers in this repo expect either
#   `content` or Anthropic-style thinking blocks — `reasoning_content` is
#   currently NOT surfaced to the UI. Treat it as silent thinking for now.
# - Automatic server-side prompt caching: no headers needed. Hits are reported
#   in `usage.prompt_tokens_details.cached_tokens`.

mimo_activate() {
  BASE_URL="https://token-plan-sgp.xiaomimimo.com/v1"
  API_KEY="${MIMO_API_KEY:-${API_KEY:-}}"
}
