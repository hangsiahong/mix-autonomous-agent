# ─── Provider: DeepSeek ──────────────────────────────────────────────────────
# OpenAI-compatible. Popular for cheap, high-quality inference.
#
# Config:
#   PROVIDER=deepseek
#   MODEL=deepseek-chat   (or deepseek-reasoner)
#   DEEPSEEK_API_KEY=sk-...

deepseek_activate() {
  BASE_URL="https://api.deepseek.com/v1"
  API_KEY="${DEEPSEEK_API_KEY:-${API_KEY:-}}"
}
