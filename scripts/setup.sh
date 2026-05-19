#!/usr/bin/env bash
# AMA interactive setup wizard.
#
# Run once after cloning:
#   bash scripts/setup.sh
# Then start the bot:
#   bash bot.sh          # native
#   pm2 start pm2.config.js
#   docker compose up -d --build

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# ── ui helpers ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[36m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    RED=''; GRN=''; YLW=''; BLU=''; DIM=''; NC=''
fi
hr()   { printf "${DIM}%s${NC}\n" "────────────────────────────────────────────────────────"; }
say()  { printf "${BLU}»${NC} %s\n" "$*"; }
ok()   { printf "${GRN}✓${NC} %s\n" "$*"; }
warn() { printf "${YLW}!${NC} %s\n" "$*"; }
err()  { printf "${RED}✗${NC} %s\n" "$*" >&2; }

ask() {
    # ask "prompt" "default" → echoes the answer (default if empty)
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        printf "${BLU}?${NC} %s ${DIM}[%s]${NC} " "$prompt" "$default" >&2
    else
        printf "${BLU}?${NC} %s " "$prompt" >&2
    fi
    IFS= read -r reply </dev/tty || reply=""
    printf '%s' "${reply:-$default}"
}

ask_secret() {
    local prompt="$1" reply
    printf "${BLU}?${NC} %s ${DIM}(hidden)${NC} " "$prompt" >&2
    IFS= read -rs reply </dev/tty || reply=""
    printf '\n' >&2
    printf '%s' "$reply"
}

confirm() {
    # confirm "prompt" "y|n default" → 0 if yes
    local prompt="$1" default="${2:-n}" reply
    local hint="y/N"; [ "$default" = "y" ] && hint="Y/n"
    printf "${BLU}?${NC} %s ${DIM}[%s]${NC} " "$prompt" "$hint" >&2
    IFS= read -r reply </dev/tty || reply=""
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

choose() {
    # choose "header" "opt1" "opt2" ... → echoes the chosen number
    local header="$1"; shift
    printf "\n${BLU}»${NC} %s\n" "$header" >&2
    local i=1
    for opt in "$@"; do
        printf "  ${YLW}%d)${NC} %s\n" "$i" "$opt" >&2
        i=$((i+1))
    done
    local n=$#
    local reply
    while :; do
        printf "${BLU}?${NC} Choose [1-%d]: " "$n" >&2
        IFS= read -r reply </dev/tty || reply=""
        if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "$n" ]; then
            printf '%s' "$reply"
            return 0
        fi
        warn "Enter a number between 1 and $n."
    done
}

# ── banner ─────────────────────────────────────────────────────────────────
hr
printf "${GRN}AMA — Autonomous Mix Agent — setup${NC}\n"
printf "${DIM}Repo:${NC} %s\n" "$DIR"
hr

# ── 1. system deps ─────────────────────────────────────────────────────────
say "Step 1/6: checking system dependencies"
MISSING=()
for cmd in bash python3 curl jq sqlite3 flock; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING+=("$cmd")
    fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    err "Missing commands: ${MISSING[*]}"
    cat >&2 <<EOF
Install hints:
  Debian/Ubuntu: sudo apt-get install -y bash python3 python3-pip curl jq sqlite3 util-linux
  Arch:          sudo pacman -S bash python python-pip curl jq sqlite util-linux
  macOS:         brew install bash python3 curl jq sqlite flock
EOF
    if ! confirm "Continue anyway?"; then exit 1; fi
else
    ok "All required commands present"
fi

# ── 2. run mode ────────────────────────────────────────────────────────────
RUN_MODE_NUM=$(choose "Step 2/6: how do you want to run AMA?" \
    "Native bash on this host (development)" \
    "pm2 background daemon (recommended for VPS)" \
    "Docker sandbox (isolated container)")
case "$RUN_MODE_NUM" in
    1) RUN_MODE=native ;;
    2) RUN_MODE=pm2 ;;
    3) RUN_MODE=docker ;;
esac
ok "Run mode: $RUN_MODE"

# ── 3. python deps (skip for docker — image builds them) ──────────────────
if [ "$RUN_MODE" != "docker" ]; then
    say "Step 3/6: installing Python dependencies"
    if [ ! -d venv ]; then
        say "Creating virtualenv at ./venv"
        if ! python3 -m venv venv 2>/tmp/ama-venv.err; then
            err "venv creation failed:"
            cat /tmp/ama-venv.err >&2
            warn "Try: sudo apt-get install python3-venv"
            exit 1
        fi
    fi
    # shellcheck disable=SC1091
    . venv/bin/activate
    say "pip install -r requirements.txt (this can take a minute)"
    if ! pip install --quiet --upgrade pip; then warn "pip self-upgrade failed (continuing)"; fi
    if ! pip install --quiet -r requirements.txt; then
        err "pip install failed. Re-run with: . venv/bin/activate && pip install -r requirements.txt"
        exit 1
    fi
    ok "Python deps installed inside ./venv"

    if [ "$RUN_MODE" = "pm2" ]; then
        if ! command -v pm2 >/dev/null 2>&1; then
            if command -v npm >/dev/null 2>&1; then
                if confirm "pm2 not found. Install globally via npm now?" y; then
                    if ! npm install -g pm2; then
                        warn "pm2 install failed (try sudo). Continuing — you can install pm2 later."
                    fi
                fi
            else
                warn "npm not found. Install Node.js + npm, then: npm install -g pm2"
            fi
        else
            ok "pm2 already installed"
        fi
    fi
else
    say "Step 3/6: skipping local Python install (Docker image will build deps)"
    if ! command -v docker >/dev/null 2>&1; then
        err "docker command not found. Install Docker Engine first: https://docs.docker.com/engine/install/"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        warn "'docker compose' plugin not found. Install docker-compose-plugin."
    fi
fi

# ── 4. telegram ────────────────────────────────────────────────────────────
say "Step 4/6: Telegram bot credentials"
echo "  Get a bot token from @BotFather: https://t.me/BotFather → /newbot" >&2
echo "  Get your numeric user ID from @userinfobot" >&2
TG_TOKEN=$(ask_secret "Telegram bot token")
while [ -z "$TG_TOKEN" ] || ! [[ "$TG_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; do
    warn "Token looks invalid (expected NNN:XXXXXX...). Try again."
    TG_TOKEN=$(ask_secret "Telegram bot token")
done
TG_ADMIN=$(ask "Your Telegram numeric user ID")
while ! [[ "$TG_ADMIN" =~ ^[0-9]+$ ]]; do
    warn "Must be a numeric ID."
    TG_ADMIN=$(ask "Your Telegram numeric user ID")
done
ok "Telegram credentials captured"

# ── 5. provider ────────────────────────────────────────────────────────────
PROV_NUM=$(choose "Step 5/6: which LLM provider?" \
    "Google Vertex AI         (Gemini 3, full features, gcloud OAuth)" \
    "Google AI Studio         (Gemini, simple API key)" \
    "GitHub Copilot           (uses your Copilot subscription, OAuth)" \
    "KConsole                 (Koompi gateway, single key for many models)" \
    "Anthropic Claude         (claude-opus / sonnet / haiku)" \
    "Ollama                   (local models on this host)" \
    "OpenAI / OpenAI-compat   (groq, deepseek, mistral, openrouter, ...)")

PROVIDER=""
PROVIDER_ENV=""    # extra lines appended to .env
MODEL_DEFAULT=""
POST_SETUP_NOTE=""

case "$PROV_NUM" in
1)  PROVIDER=google
    MODEL_DEFAULT=gemini-3-flash-preview
    GCP_PROJECT=$(ask "GCP project ID")
    GCP_REGION=$(ask "GCP region" "global")
    # NOTE: code reads GOOGLE_PROJECT / GOOGLE_REGION (NOT GOOGLE_CLOUD_*).
    PROVIDER_ENV=$(cat <<EOF
GOOGLE_MODE=vertex
GOOGLE_PROJECT=$GCP_PROJECT
GOOGLE_REGION=$GCP_REGION
EOF
)
    if command -v gcloud >/dev/null 2>&1; then
        if confirm "Run 'gcloud auth application-default login' now?" y; then
            gcloud auth application-default login || warn "gcloud auth failed — you can retry later."
            gcloud config set project "$GCP_PROJECT" 2>/dev/null || true
        else
            POST_SETUP_NOTE="Before starting the bot, run: gcloud auth application-default login"
        fi
    else
        warn "gcloud CLI not found."
        echo "  Install: https://cloud.google.com/sdk/docs/install" >&2
        echo "  Then run: gcloud auth application-default login" >&2
        echo "  Alternative: paste a Vertex API key (AQ.*) — prompt-caching won't work." >&2
        if confirm "Paste a Vertex API key (AQ.*) instead?" n; then
            VKEY=$(ask_secret "Vertex API key")
            PROVIDER_ENV="$PROVIDER_ENV
GOOGLE_VERTEX_KEY=$VKEY"
        else
            POST_SETUP_NOTE="Install gcloud and run 'gcloud auth application-default login' before starting the bot."
        fi
    fi
    ;;
2)  PROVIDER=google
    MODEL_DEFAULT=gemini-2.5-flash
    GKEY=$(ask_secret "Google AI Studio API key (AIza...)")
    PROVIDER_ENV=$(cat <<EOF
GOOGLE_MODE=studio
GOOGLE_API_KEY=$GKEY
EOF
)
    ;;
3)  PROVIDER=copilot
    MODEL_DEFAULT=gpt-5
    PROVIDER_ENV=""
    POST_SETUP_NOTE="Copilot OAuth: after the bot starts, message it /copilot_login in Telegram and follow the device-code prompt."
    ;;
4)  PROVIDER=kconsole
    MODEL_DEFAULT=koompi-fast
    KKEY=$(ask_secret "KConsole API key (kpi_...)")
    PROVIDER_ENV="KCONSOLE_AI_KEY=$KKEY"
    ;;
5)  PROVIDER=anthropic
    MODEL_DEFAULT=claude-sonnet-4-6
    AKEY=$(ask_secret "Anthropic API key (sk-ant-...)")
    PROVIDER_ENV="ANTHROPIC_API_KEY=$AKEY"
    ;;
6)  PROVIDER=ollama
    MODEL_DEFAULT=llama3.3:70b-instruct
    OHOST=$(ask "Ollama host" "http://localhost:11434")
    PROVIDER_ENV="OLLAMA_HOST=$OHOST"
    ;;
7)  echo "  Sub-providers: openai | groq | deepseek | mistral | openrouter | xai | minimax | zai" >&2
    SUBP=$(ask "Sub-provider name" "openai")
    PROVIDER="$SUBP"
    MODEL_DEFAULT=$(ask "Default model" "gpt-4o-mini")
    KEY_NAME=$(printf '%s' "$SUBP" | tr '[:lower:]' '[:upper:]')_API_KEY
    SKEY=$(ask_secret "$KEY_NAME")
    PROVIDER_ENV="$KEY_NAME=$SKEY"
    ;;
esac

MODEL=$(ask "Model" "$MODEL_DEFAULT")
ok "Provider: $PROVIDER, model: $MODEL"

# ── 6. write configs ──────────────────────────────────────────────────────
say "Step 6/6: writing .env and brain/config.json"

# back up any existing .env / config.json
TS=$(date +%Y%m%d-%H%M%S)
if [ -f .env ]; then
    if ! confirm "An .env already exists. Overwrite? (backup will be made)" n; then
        err "Aborted — not overwriting .env. Remove or rename it and re-run setup."
        exit 1
    fi
    cp .env ".env.backup-$TS"
    ok "Backed up existing .env → .env.backup-$TS"
fi
if [ -f brain/config.json ]; then
    cp brain/config.json "brain/config.json.backup-$TS"
fi

UMASK_OLD=$(umask); umask 077
{
    echo "# AMA — generated by scripts/setup.sh on $(date -Iseconds)"
    echo "# Re-run 'bash scripts/setup.sh' to reconfigure (old .env is backed up automatically)."
    echo
    echo "TG_TOKEN=$TG_TOKEN"
    echo "TG_ADMIN=$TG_ADMIN"
    echo
    echo "PROVIDER=$PROVIDER"
    echo "MODEL=$MODEL"
    if [ -n "$PROVIDER_ENV" ]; then
        echo
        echo "$PROVIDER_ENV"
    fi
    if [ "$RUN_MODE" = "docker" ]; then
        echo
        echo "# Docker UID/GID — keeps mounted-volume files owned by you"
        echo "UID=$(id -u)"
        echo "GID=$(id -g)"
    fi
    echo
    echo "# Optional caps (uncomment to customise):"
    echo "# MAX_CONCURRENT_AGENTS=10"
    echo "# MAX_AGENTS_PER_USER=3"
    echo "# WORKSPACE_DIR=$HOME/projects"
} > .env
umask "$UMASK_OLD"

# brain/config.json — whitelist + home_chat = admin id
mkdir -p brain
python3 - "$TG_ADMIN" <<'PY'
import json, sys, pathlib
admin = sys.argv[1]
path = pathlib.Path("brain/config.json")
cfg = {}
if path.exists():
    try: cfg = json.loads(path.read_text())
    except Exception: cfg = {}
cfg["whitelist"] = sorted(set(cfg.get("whitelist", []) + [admin]))
cfg.setdefault("home_chat", admin)
cfg.setdefault("default_toolsets", ["core", "search", "memory", "meta"])
cfg.setdefault("group_topics", cfg.get("group_topics", []))
path.write_text(json.dumps(cfg, indent=2) + "\n")
print(f"  wrote {path}")
PY

ok ".env (mode 0600) and brain/config.json written"

# ── 7. optional persona ────────────────────────────────────────────────────
if [ ! -f SOUL.md ] && [ -f SOUL.md.example ]; then
    if confirm "Copy SOUL.md.example → SOUL.md (custom persona)?" n; then
        cp SOUL.md.example SOUL.md
        ok "SOUL.md created — edit it any time, no restart needed"
    fi
fi

# ── 8. final summary ──────────────────────────────────────────────────────
hr
ok "Setup complete."
echo
case "$RUN_MODE" in
    native)
        say "Start the bot with:"
        echo "    ${GRN}bash bot.sh${NC}"
        ;;
    pm2)
        say "Start the bot with:"
        echo "    ${GRN}pm2 start pm2.config.js${NC}"
        echo "    ${DIM}pm2 logs ama-bot     # tail logs${NC}"
        echo "    ${DIM}pm2 save && pm2 startup    # boot-time autostart${NC}"
        ;;
    docker)
        say "Start the bot with:"
        echo "    ${GRN}docker compose up -d --build${NC}"
        echo "    ${DIM}docker compose logs -f${NC}"
        ;;
esac
if [ -n "$POST_SETUP_NOTE" ]; then
    echo
    warn "$POST_SETUP_NOTE"
fi
echo
echo "${DIM}Message your bot on Telegram with /help to see commands.${NC}"
hr
