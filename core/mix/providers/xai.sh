# ─── Provider: xAI (Grok) ────────────────────────────────────────────────────
# xAI's Grok models. OpenAI-compatible endpoint.
#
# Config:
#   PROVIDER=xai
#   MODEL=grok-3-beta   (or grok-3-mini-beta)
#   XAI_API_KEY=xai-...

xai_activate() {
  BASE_URL="https://api.x.ai/v1"
  API_KEY="${XAI_API_KEY:-${API_KEY:-}}"
}
