# Config
WORKDIR="$(pwd)"
[ -f .env ] && source .env

# API Config
PROVIDER="${PROVIDER:-default}"
MODEL="${LLM_MODEL:-gemini-2.0-flash-exp}"
BASE_URL="${BASE_URL:-https://generativelanguage.googleapis.com/v1beta}"
API_KEY="${GEMINI_KEY}"

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
SESSION_ID=$(date +%s)
mkdir -p brain/state
