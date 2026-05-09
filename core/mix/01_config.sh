# Config
WORKDIR="$(pwd)"
# Save values explicitly passed in the environment (before .env can override them)
_env_PROVIDER="${PROVIDER:-}"
_env_MODEL="${MODEL:-}"
_env_BASE_URL="${BASE_URL:-}"
_env_API_KEY="${API_KEY:-}"
[ -f .env ] && source .env
# Restore explicitly-set env vars so they win over .env defaults
[ -n "$_env_PROVIDER" ] && PROVIDER="$_env_PROVIDER"
[ -n "$_env_MODEL" ]    && MODEL="$_env_MODEL"
[ -n "$_env_BASE_URL" ] && BASE_URL="$_env_BASE_URL"
[ -n "$_env_API_KEY" ]  && API_KEY="$_env_API_KEY"
unset _env_PROVIDER _env_MODEL _env_BASE_URL _env_API_KEY

# API Config
PROVIDER="${PROVIDER:-default}"
MODEL="${MODEL:-${LLM_MODEL:-gemini-3-flash-preview}}"
FALLBACK_MODEL=""  # No fallback: global Vertex endpoint only serves gemini-3 preview models
# BASE_URL is handled by providers or default
BASE_URL="${BASE_URL:-https://generativelanguage.googleapis.com/v1beta}"
API_KEY="${GEMINI_KEY:-${GOOGLE_VERTEX_KEY:-${API_KEY:-}}}"

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
