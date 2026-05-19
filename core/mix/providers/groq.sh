# ─── Provider: Groq ──────────────────────────────────────────────────────────
# Groq cloud — extremely fast inference (LPU hardware).
# Great as a fallback when main provider is rate-limited.
#
# Config:
#   PROVIDER=groq
#   MODEL=llama-3.3-70b-versatile   (or gemma2-9b-it, mixtral-8x7b-32768)
#   GROQ_API_KEY=gsk_...

groq_activate() {
  BASE_URL="https://api.groq.com/openai/v1"
  API_KEY="${GROQ_API_KEY:-${API_KEY:-}}"
}
