#!/bin/bash
# docker/entrypoint.sh — first-run bootstrap + dep-sync, then exec pm2-runtime.
# Designed so the image is built ONCE and ALL future updates happen via:
#   1. host  `git pull` (when /opt/ama is a bind mount)
#   2. in-container `/update` slash command or `self_update` tool
#
# Persistence model: /opt/ama is the code (bind mount or first-run clone into
# named volume); /home/ama is a named volume holding pip --user installs, npm
# cache, pm2 dump, Playwright browsers — everything install-once persists.

set -e

APP_DIR="${APP_DIR:-/opt/ama}"
AMA_REPO="${AMA_REPO:-https://github.com/hangsiahong/mix-autonomous-agent.git}"
AMA_BRANCH="${AMA_BRANCH:-master}"
REQS_HASH_FILE="${HOME}/.ama_reqs_hash"
PLAYWRIGHT_HOME="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.playwright}"

# ── ~/.local on PATH so pip --user installs are visible ───────────────────────
export PATH="${HOME}/.local/bin:${PATH}"

echo "[entrypoint] APP_DIR=$APP_DIR  HOME=$HOME  branch=$AMA_BRANCH"

# ── First-run clone (for `docker run -v named_vol:/opt/ama` users) ───────────
# Compose users typically bind-mount their host checkout, so bot.sh already
# exists and we skip the clone. The clone only kicks in when /opt/ama is
# empty AND a git checkout — never overwrites existing files.
if [[ ! -e "${APP_DIR}/bot.sh" ]]; then
    echo "[entrypoint] /opt/ama empty — cloning ${AMA_REPO} (branch ${AMA_BRANCH})"
    if [[ -z "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
        git clone --depth 50 --branch "$AMA_BRANCH" "$AMA_REPO" "$APP_DIR"
    else
        echo "[entrypoint] ERROR: $APP_DIR is non-empty but has no bot.sh — refusing to clone over it."
        echo "[entrypoint] Mount a clean dir, or pre-clone the repo into it."
        exit 1
    fi
fi

cd "$APP_DIR"

# ── First-run env scaffold ────────────────────────────────────────────────────
if [[ ! -f .env && -f .env.example ]]; then
    cp .env.example .env
    echo "[entrypoint] WARNING: created .env from .env.example — fill in TG_TOKEN before bot will work."
fi

# ── Pip deps: install --user (lives in /home/ama/.local, persists) ───────────
# Only run when requirements.txt actually changed since last successful install.
if [[ -f requirements.txt ]]; then
    cur_hash=$(sha256sum requirements.txt | awk '{print $1}')
    prev_hash=$(cat "$REQS_HASH_FILE" 2>/dev/null || echo "")
    if [[ "$cur_hash" != "$prev_hash" ]]; then
        echo "[entrypoint] requirements.txt changed — installing --user"
        if pip install --user --no-warn-script-location --break-system-packages -r requirements.txt; then
            echo "$cur_hash" > "$REQS_HASH_FILE"
        else
            echo "[entrypoint] WARNING: pip install failed — continuing with stale deps"
        fi
    fi
fi

# ── Playwright browsers: install once into /home/ama/.playwright ─────────────
# Persists across container recreates (saves ~250MB on every rebuild).
mkdir -p "$PLAYWRIGHT_HOME"
if [[ ! -d "${PLAYWRIGHT_HOME}/chromium-"* ]]; then
    echo "[entrypoint] Installing Playwright Chromium into $PLAYWRIGHT_HOME"
    PLAYWRIGHT_BROWSERS_PATH="$PLAYWRIGHT_HOME" playwright install chromium || \
        echo "[entrypoint] WARNING: playwright install failed — browser tools will be unavailable"
fi

# ── Ensure runtime dirs exist (idempotent — bind mounts may not have them) ──
mkdir -p logs brain/state tools/custom

# ── Hand off to pm2-runtime as PID 1 ─────────────────────────────────────────
echo "[entrypoint] Starting pm2-runtime"
exec pm2-runtime pm2.config.js
