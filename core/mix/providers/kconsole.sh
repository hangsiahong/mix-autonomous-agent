# ─── Provider: KConsole AI ───────────────────────────────────────────────────
# KOOMPI Cloud AI Gateway — OpenAI-compatible proxy for Gemini, Imagen, Veo.
# Handles billing, rate limiting, and translates requests behind a standard
# OpenAI-compatible interface.
#
# Config:
#   PROVIDER=kconsole
#   MODEL=koompi-fast          (default fast model)
#   KCONSOLE_AI_KEY=<key>      (from https://ai.koompi.cloud)

kconsole_activate() {
  BASE_URL="https://ai.koompi.cloud/v1"
  API_KEY="${KCONSOLE_AI_KEY:-${API_KEY:-}}"
}
