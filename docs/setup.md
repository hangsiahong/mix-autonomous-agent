# Setup

Detailed installation + configuration. For a one-command quickstart see [README.md](../README.md).

## TL;DR — the wizard

```bash
git clone https://github.com/hangsiahong/mix-autonomous-agent.git ama
cd ama
bash scripts/setup.sh
```

`scripts/setup.sh` is the interactive setup wizard. It:

1. Checks system deps (bash, python3, curl, jq, sqlite3, flock).
2. Asks how you want to run AMA: **native**, **pm2**, or **Docker**.
3. Creates `./venv` and installs `requirements.txt` (skipped for Docker — the image builds it).
4. Installs **pm2** globally via npm if you picked pm2 mode and it isn't present.
5. Prompts for your **Telegram bot token** + **admin user ID** (validates the format).
6. Walks you through one of: **Google Vertex AI** (offers to run `gcloud auth application-default login`), **Google AI Studio**, **GitHub Copilot** (OAuth happens later via `/copilot_login` in Telegram), **KConsole**, **Anthropic**, **Ollama**, or any **OpenAI-compatible** provider.
7. Writes `.env` (mode 0600) and `brain/config.json` with your admin ID whitelisted. Existing files are backed up to `.env.backup-<timestamp>` first.
8. Optionally copies `SOUL.md.example → SOUL.md` for a custom persona.

Re-run the wizard any time — it never silently overwrites your config. The sections below describe what the wizard does behind the scenes if you'd rather configure by hand.

## Prerequisites

| Tool | Why | How to check |
|---|---|---|
| Bash 4+ | The engine | `bash --version` |
| Python 3.11+ | Helpers, JSON munging, LLM clients | `python3 --version` |
| `curl` | HTTP | `curl --version` |
| `sqlite3` | Session DB | `sqlite3 --version` |
| `flock` | Session locking | `which flock` |
| Telegram Bot token | From `@BotFather` | (just register one) |
| LLM provider | Google Vertex AI / Anthropic / Groq / Kconsole / Ollama / etc. | (set up account) |

## Install

```bash
git clone https://github.com/hangsiahong/mix-autonomous-agent.git ama
cd ama
pip install -r requirements.txt
```

`requirements.txt` installs the small Python deps used by tools (`requests`, `lancedb`, etc.). No build step; bash scripts run directly.

## Configure

### 1. Telegram credentials

```bash
cp .env.example .env
# Edit .env:
#   TG_TOKEN=<from @BotFather>
#   TG_ADMIN=<your numeric Telegram user ID>
```

Get your numeric ID by messaging `@userinfobot`.

### 2. Whitelist

```bash
cp brain/config.example.json brain/config.json
# Edit brain/config.json:
#   "whitelist": ["<your numeric Telegram ID>"]
#   "home_chat": "<your numeric Telegram ID>"
```

The `whitelist` controls who can message the bot. `home_chat` is where the bot sends admin alerts (e.g. error patterns from the self-heal loop).

### 3. Provider

In `.env`, pick ONE:

**Google Vertex AI** (recommended — Gemini 3 Flash is fast and multimodal):
```bash
PROVIDER=google
GOOGLE_CLOUD_PROJECT=your-gcp-project-id
GOOGLE_CLOUD_REGION=global   # use global for Gemini 3.x preview models
MODEL=gemini-3-flash-preview
```

Authentication: install `gcloud` CLI and run `gcloud auth application-default login`. Vertex prompt-caching requires this.

Alternative: set `GOOGLE_VERTEX_KEY=AQ...` if you have a Vertex API key — works for chat but **not** for `cachedContents` (which needs OAuth).

**Anthropic Claude**:
```bash
PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
MODEL=claude-opus-4-7
```

Other providers documented in [`providers.md`](providers.md).

### 4. (Optional) Provider pool

For automatic failover / multi-key rotation:
```bash
cp brain/provider_pool.json.example brain/provider_pool.json
# Edit and fill in your keys
```

The pool supports `fallback` (ordered priority) or `round-robin` strategy. See [`providers.md`](providers.md#pool) for the full schema.

### 5. (Optional) Persona

```bash
cp SOUL.md.example SOUL.md
# Edit to set the agent's tone / personality
```

`SOUL.md` is read fresh every turn — no restart needed. Gitignored so upstream pulls don't overwrite your persona.

## Run

### Directly (development)

```bash
bash bot.sh
```

The single-instance lock at the top of `bot.sh` kills any other `bash bot.sh` processes before claiming the lock. Safe to invoke even if you're not sure whether the bot is already running.

### Background with pm2

```bash
npm install -g pm2
pm2 start pm2.config.js
pm2 logs ama-bot
```

### Docker

```bash
cp .env.example .env  # fill in
cp brain/config.example.json brain/config.json  # fill in
docker compose up -d --build
docker compose logs -f
```

The `docker-compose.yml` matches container UID to host UID so volume files don't end up root-owned. Override with `UID=1001` etc. in `.env` if needed.

## Verify

In Telegram, message your bot:
- `/help` — should list available commands
- `hi` — should reply within ~5 seconds
- `/status` — should show your model + session info

If you get no reply, check:
- `pm2 logs ama-bot` (or wherever you're tailing)
- `brain/state/error_log.jsonl` for API errors
- `logs/bot.log` if you're redirecting

## Self-modification

The agent edits its own runtime state without restart:
- `brain/system_prompt.md` — base prompt (reread every turn)
- `brain/state/MEMORY.md` / `USER.md` — agent notes (curator edits these)
- `brain/skills/*` — skill prompts (read on bind)
- `tools/custom/*` — custom tools the agent creates (`custom_tool_manager`)
- `brain/tools_extra.json` — custom tool registrations

Files that need `/reload` (no restart) to take effect:
- `core/mix/*.sh`, `core/telegram/*.sh`, `core/mix/providers/*.sh`

Files that need full `/restart` (pm2 restart or kill + relaunch):
- `.env`

The `/reload` command sends `SIGHUP` to bot.sh which re-sources `core/mix/init.sh` and all extensions.

## Common issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Bot doesn't respond | Multiple `bash bot.sh` instances racing | `pkill -f "bash bot.sh"` then restart |
| 401 from Vertex `cachedContents` | API key auth (Vertex needs OAuth for caching) | Install gcloud + `gcloud auth application-default login` |
| `Permission denied` on `brain/state/` | Container UID ≠ host UID | Set `UID`/`GID` in `.env` to match `id -u`/`id -g` |
| Empty `history_<sid>.json` | Crash mid-save before fix shipped | Already handled (load_history treats empty as `[]`) |
| Scheduler tasks not firing | Cron loop dead | Check `/tmp/ama_cron.log`; HUP or restart |
