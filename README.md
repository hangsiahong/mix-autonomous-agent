# AMA: Autonomous Mix Agent

A self-evolving autonomous agent that lives in Telegram. Pure Bash harness, 24 tools, Playwright browser, vector memory, and a self-improvement loop.

---

## Setup

### Prerequisites
- Linux / macOS
- `bash`, `curl`, `jq`, `python3`
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- An LLM API key (Google Vertex AI, Gemini API, Anthropic, or OpenAI)

### Install Python dependencies
```bash
pip install -r requirements.txt
python3 -m playwright install chromium
```

### Configure
```bash
cp .env.example .env
# Edit .env with your values
```

Minimum required in `.env`:
```env
TG_TOKEN=your-telegram-bot-token
TG_ADMIN=your-telegram-user-id
PROVIDER=google
GOOGLE_CLOUD_PROJECT=your-gcp-project-id
```

---

## Run

### Directly
```bash
bash bot.sh
```

### With pm2 (recommended — auto-restarts on crash)
```bash
npm install -g pm2
pm2 start pm2.config.js
pm2 save          # persist across reboots
pm2 startup       # generate boot hook
```

Useful pm2 commands:
```bash
pm2 logs ama-bot   # live logs
pm2 restart ama-bot
pm2 stop ama-bot
```

---

## Run with Docker

```bash
docker build -t ama-bot .
docker run -d --env-file .env --name ama ama-bot
```

Logs:
```bash
docker logs -f ama
```

---

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/help` | Show all commands |
| `/new` | Reset conversation |
| `/status` | Agent status |
| `/skill <name>` | Activate a skill |
| `/skills` | List available skills |
| `/insights` | Token & tool usage stats |
| `/restart` | Restart bot (admin) |
| `/stop` | Shut down bot (admin) |

---

## Project Structure

```
bot.sh              Entry point & Telegram polling
pm2.config.js       pm2 process config
Dockerfile          Container definition
requirements.txt    Python deps
brain/
  system_prompt.md  Agent personality & rules
  tools.json        Tool registry (24 tools)
  config.json       Toolsets & whitelist config
core/
  mix/              Agent loop, API, history, compression
  telegram/         Polling, routing, formatting
tools/
  _lib/             Python core (fuzzy edit, patch, browser)
  bash.sh           Hardened shell executor
  browser.sh        Playwright browser automation
  fetch_url.sh      Web fetching (Jina + fallback)
  memory_helper.py  LanceDB vector memory (chunked)
  edit_code.sh      9-strategy fuzzy file editor
  patch.sh          V4A atomic multi-file patcher
extensions/
  cron/             Background maintenance (log trim, memory prune)
```

---

## Tests

```bash
bash scripts/run_all_tests.sh
```

