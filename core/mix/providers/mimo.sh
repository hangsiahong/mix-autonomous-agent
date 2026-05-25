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

# System-prompt suffix appended only when running on mimo. Counters its
# observed agentic weakness: under tool_choice=auto mimo prefers to NARRATE
# its plan ("I'll write the file now") and then close the turn with
# finish_reason=stop, never emitting the tool_call delta. Verified against
# a live broken session — same payload with tool_choice=required produced
# the correct write_file call instantly. Forcing required globally would
# break chat-only turns, so we nudge via prompt instead. Other providers
# can register the same hook by defining `${PROVIDER}_system_prompt_suffix`.
mimo_system_prompt_suffix() {
  cat <<'EOF'
## Action discipline (mimo)

When the user asks you to DO something (build, write, create, run, install,
edit, fix, etc.), you MUST call the appropriate tool in THIS response —
not in some imagined "next" response. Reasoning is fine, but it has to be
followed by the actual tool call in the same turn.

If you find yourself producing text like "Writing it now…", "I'll create
the file…", "Let me build that…" — STOP. The tool call must be in the
same response as that text. Closing the turn after narration without a
tool_call is a known failure mode of this model. Watch for it actively.

Greetings and questions are exempt — those don't need tools.
EOF
}
