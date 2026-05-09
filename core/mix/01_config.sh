# Config
WORKDIR="$(pwd)"
[ -f .env ] && source .env

# API Config
PROVIDER="${PROVIDER:-default}"
MODEL="${LLM_MODEL:-gemini-2.0-flash-exp}"
# BASE_URL is handled by providers or default
BASE_URL="${BASE_URL:-https://generativelanguage.googleapis.com/v1beta}"
API_KEY="${GEMINI_KEY:-${API_KEY:-}}"

# Agent Config
MAX_TURNS=30
MAX_HIST_MSGS=40
STREAM="${STREAM:-true}"
GIT_ENABLED=false

# Telegram Config
TG_TOKEN="${TG_TOKEN}"
TG_API="https://api.telegram.org/bot${TG_TOKEN}"

# State
HISTORY="[]"
mkdir -p brain/state

# Provider Activation
if [ "$PROVIDER" != "default" ]; then
  # Providers should be sourced before this
  if type "${PROVIDER}_activate" >/dev/null 2>&1; then
    ${PROVIDER}_activate 2>/dev/null || true
  fi
fi
