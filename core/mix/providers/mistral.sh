# ─── Provider: Mistral AI ────────────────────────────────────────────────────
# Mistral AI models. OpenAI-compatible endpoint.
#
# Config:
#   PROVIDER=mistral
#   MODEL=mistral-large-latest   (or mistral-small-latest, codestral-latest)
#   MISTRAL_API_KEY=...

mistral_activate() {
  BASE_URL="https://api.mistral.ai/v1"
  API_KEY="${MISTRAL_API_KEY:-${API_KEY:-}}"
}
