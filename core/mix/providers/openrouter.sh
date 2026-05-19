# ─── Provider: OpenRouter ────────────────────────────────────────────────────
# Unified API for 200+ models (Claude, GPT, Gemini, DeepSeek, etc.).
# Useful as a fallback or to access models without separate accounts.
#
# Config:
#   PROVIDER=openrouter
#   MODEL=anthropic/claude-sonnet-4-6   (or any openrouter model slug)
#   OPENROUTER_API_KEY=sk-or-...

openrouter_activate() {
  BASE_URL="https://openrouter.ai/api/v1"
  API_KEY="${OPENROUTER_API_KEY:-${API_KEY:-}}"
}

openrouter_extra_headers_json() {
  echo '{"HTTP-Referer": "https://github.com/ama-agent", "X-Title": "AMA"}'
}
