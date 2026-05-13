# ─── Provider: MiniMax ───────────────────────────────────────────────────────
# MiniMax M-series models. Uses their OpenAI-compatible /v1 endpoint.
#
# Config:
#   PROVIDER=minimax
#   MODEL=MiniMax-M1   (or MiniMax-Text-01)
#   MINIMAX_API_KEY=...
#
# Note: For China region use PROVIDER=minimax and set
#   MINIMAX_API_KEY from platform.minimaxi.com and
#   MINIMAX_BASE_URL=https://api.minimaxi.com/v1 in .env

minimax_activate() {
  BASE_URL="${MINIMAX_BASE_URL:-https://api.minimax.io/v1}"
  API_KEY="${MINIMAX_API_KEY:-${API_KEY:-}}"
}
