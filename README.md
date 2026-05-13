# AMA — Autonomous Mix Agent

A self-evolving autonomous agent that lives in Telegram. Pure Bash harness, 30+ tools, Playwright browser, vector memory + SQLite session DB, and a self-improvement loop. Inspired by hermes-agent and openclaw.

---

## Setup

### Prerequisites
- Linux / macOS
- `bash`, `curl`, `python3`
- A Telegram bot token from [@BotFather](https://t.me/BotFather)
- An LLM API key (Google Vertex AI, Gemini API, Anthropic, OpenAI, DeepSeek, OpenRouter, xAI/Grok, Groq, Zai/GLM, Mistral, MiniMax, or local Ollama/Copilot)

### Install
```bash
pip install -r requirements.txt
python3 -m playwright install chromium
```

### Configure
```bash
cp .env.example .env
# Edit .env with your values

cp brain/config.example.json brain/config.json
# Edit brain/config.json with your Telegram user ID and whitelist

cp SOUL.md.example SOUL.md
# Edit SOUL.md to customize the agent's persona (optional)
```

Minimum required `.env`:
```env
TG_TOKEN=your-telegram-bot-token
TG_ADMIN=your-telegram-user-id

# Google Vertex AI (recommended — Gemini 3 Flash)
PROVIDER=google
GOOGLE_PROJECT=your-gcp-project-id
MODEL=gemini-3-flash-preview

# Optional fallback if primary provider fails
FALLBACK_PROVIDER=default:gpt-4o-mini
```

#### Provider Pool (optional)

Pool multiple API keys or accounts per provider, with automatic rotation on rate limits:

```bash
cp brain/provider_pool.json.example brain/provider_pool.json
# Edit brain/provider_pool.json with your keys
```

Format:
```json
{
  "strategy": "fallback",
  "providers": [
    { "name": "google", "model": "gemini-2.5-flash-preview-04-17", "key": "..." },
    { "name": "deepseek", "model": "deepseek-chat", "key": "..." },
    { "name": "openrouter", "model": "mistralai/mistral-7b-instruct", "key": "..." }
  ]
}
```

Strategies:
- `fallback` — try providers in order; advance on error/rate-limit
- `round-robin` — distribute requests evenly across all entries

Other useful env vars:
```env
TG_REACTIONS=1              # Enable 👀/✅/👎 reactions on messages
REQUIRE_MENTION=1           # Groups: only respond when @mentioned
MAX_CONCURRENT_AGENTS=10    # Max parallel sessions before rejecting new messages
SESSION_IDLE_HOURS=24       # Auto-reset sessions idle for N hours (0=disabled)
MEMORY_PREFETCH=1           # Auto-inject recalled memory into every turn (default on)
BOT_USERNAME=YourBotName    # For @mention detection in groups
```

---

## Run

### Directly
```bash
bash bot.sh
```

### With pm2 (recommended)
```bash
npm install -g pm2
pm2 start pm2.config.js
pm2 save && pm2 startup
pm2 logs ama-bot
```

### Docker
```bash
docker build -t ama-bot .
docker run -d --env-file .env --name ama ama-bot
docker logs -f ama
```

---

## Telegram Commands

### Session
| Command | Description |
|---------|-------------|
| `/stop` | Stop current running task |
| `/stop all` | Kill all running tasks across all sessions |
| `/new` or `/reset` | Start fresh session (archives history) |
| `/retry` | Re-run the last message |
| `/undo` | Remove the last exchange from history |
| `/steer <note>` | Inject guidance mid-run (appended after next tool call) |
| `/queue <text>` | Queue a message to run after current task finishes |

### Config
| Command | Description |
|---------|-------------|
| `/model <name>` | Switch model for this session (`/model default` to reset) |
| `/providers` | Show provider pool status and rate limits |
| `/skill <name>` | Activate a skill for this session |
| `/skill off` | Clear active skill |
| `/skills` | List all available skills |
| `/topic <name>` | Name this Telegram thread/topic |

### Info
| Command | Description |
|---------|-------------|
| `/status` | Model, session age, message count, active agents, queue depth |
| `/usage` | Token counts for this session |
| `/history [n]` | Show last N conversation turns (default 20) |
| `/sessions [n]` | List recent sessions with lineage and token counts |
| `/insights` | Token and tool usage frequency statistics |
| `/help` | Full command reference |

### Admin
| Command | Description |
|---------|-------------|
| `/whitelist <id>` | Add user or chat to whitelist |
| `/restart` | Restart bot via pm2 |
| `/shutdown` | Shut down bot |

---

## Architecture

```
bot.sh                    Entry point, Telegram long-poll, process cap (MAX_CONCURRENT_AGENTS)
pm2.config.js             Process manager config
Dockerfile                Container (Debian slim + Playwright Chromium)
requirements.txt          Python dependencies

brain/
  system_prompt.md        Agent personality and rules
  tools.json              Tool registry (30+ tools across 6 toolsets)
  config.json             Toolsets, whitelist, group topics
  state/
    sessions.db           SQLite session DB (metadata + FTS message index)
    history_<sid>.json    Active conversation history (JSON array)
    sessions/             Archived session histories
    session_recaps.jsonl  End-of-session summaries for cross-session recall
    usage_log.jsonl       Per-call token usage
    model_<sid>           Per-session model override (/model command)
    steer_<sid>           Pending /steer text for next tool call
    queue_<sid>           Queued messages (/queue command)

core/
  mix/
    00_header.sh          Constants and icons
    01_config.sh          Environment defaults, provider activation
    11_history.sh         History load/save (atomic), idle auto-reset
    13_tool_execution.sh  Tool dispatch with permission checks
    16_api.sh             Payload builder, memory auto-prefetch, provider fallback
    17_response_parser.sh OpenAI-format response parser
    18_streaming_api_call.sh  SSE streaming + TG live updates + retry
    22_process_one_tool_call.sh  Loop detection, per-tool caps, TG status
    23_parallel_tools.sh  Parallel-safe tool batching
    24_agent_loop.sh      Main loop: reactions, reply-to, steer, queue drain
    26_reflection.sh      Background reflection + end-of-session recap
    28_summary.sh         Session title generation
    30_compression.sh     Context compression (token-based, hermes format)
    32_usage.sh           Token usage logging + SQLite sync
    34_error_classifier.sh HTTP error → retry/fallback classification
    35_provider_pool.sh   Multi-provider pool with auto-routing
    36_think_scrubber.sh  Strip thinking blocks from response
    38_rate_limit.sh      Per-provider backoff tracking
    40_trajectory.sh      Session metadata log
    providers/
      google.sh           Vertex AI + AI Studio (native + OpenAI-compat)
      google_stream.py    Native Gemini SSE streaming + retry
      ollama.sh           Local Ollama provider
      copilot.sh          GitHub Copilot OAuth provider
      deepseek.sh         OpenAI-compatible provider shim
      groq.sh             OpenAI-compatible provider shim
      minimax.sh          OpenAI-compatible provider shim
      mistral.sh          OpenAI-compatible provider shim
      openrouter.sh       OpenAI-compatible provider shim
      xai.sh              OpenAI-compatible provider shim
      zai.sh              OpenAI-compatible provider shim
  telegram/
    api.sh                tg_send, tg_edit, tg_react, tg_download (with timeout)
    media.sh              Photo/voice/video download and base64 encoding
    formatter.sh          Markdown → Telegram HTML
    polling.sh            Long-poll with offset tracking
    router.sh             Update parsing, @mention gate, album batching, all commands
  access_control.sh       Tool permission checks
  config.sh               Whitelist, topic config, atomic save_config
  ui.sh                   Generic message/error display

tools/
  bash.sh                 Hardened shell executor (timeout, blocklist)
  browser.sh              Playwright Chromium headless
  edit_code.sh            9-strategy fuzzy file editor
  fetch_url.sh            Web fetching (Jina + fallback)
  memory_helper.py        LanceDB vector memory (chunked, access-tracked)
  session_db.py           SQLite session DB CLI (create/end/sync/search/lineage)
  patch.sh                V4A atomic multi-file patcher
  web_search.sh           DuckDuckGo / Tavily / Exa / Brave / SearXNG
  process.sh              Background process manager
  clarify.sh              Ask user before acting (blocks until reply)
  image_generate.sh       Image generation via Pollinations.ai
  todo.sh                 Per-session task list
  insights.sh             Token and tool frequency report
  [20+ more tools]

extensions/
  cron/                   Background maintenance (log trim, memory prune)
```

---

## Key Features

### Telegram UX (openclaw + hermes patterns)
- **Reactions**: 👀 on receive, ✅ on done, 👎 on error/max-turns (enable: `TG_REACTIONS=1`)
- **Reply threading**: Bot replies thread to your original message
- **Tool progress**: Live `_Working…_ \`🛠️ bash: git status\`` in the streaming message
- **Photo album batching**: Multiple photos → coalesced into one agent call (1s buffer)
- **Group @mention gate**: `REQUIRE_MENTION=1` → only respond when @mentioned

### Memory & Sessions (hermes patterns)
- **Memory auto-prefetch**: LanceDB queried every turn, recalled context injected into user message (invisible, scrubbed from output)
- **SQLite session DB**: Durable metadata, FTS message search, compression lineage chain
- **Session recaps**: Structured summary saved after each tool-heavy session
- **Cross-session memory**: Last 3 recaps injected into system prompt
- **Idle auto-reset**: `SESSION_IDLE_HOURS=24` archives and resets stale sessions

### Reliability
- **Stream retry**: Auto-reconnects once on network drop before showing error
- **Provider fallback chain**: `FALLBACK_PROVIDER=provider:model` activates on 2nd retry; pools chain through all entries automatically
- **Multi-provider pool**: `brain/provider_pool.json` — pool multiple keys/accounts per provider, auto-rotate on rate limit, strategies: `fallback` or `round-robin`
- **Agent process cap**: Rejects new messages when `MAX_CONCURRENT_AGENTS` exceeded
- **Atomic writes**: History, config use `mktemp + mv` to prevent corruption
- **Compression**: Token-based trigger (80K), hermes-style 7-section summary

### Commands
- `/retry`, `/undo` — redo/undo last turn
- `/steer` — inject guidance mid-run between tool calls
- `/queue` — FIFO message queue (processed after current turn)
- `/model` — per-session model override
- `/sessions` — list recent sessions with lineage
- `/history` — show conversation turns
- `/stop all` — kill every running session

---

## Pulling upstream updates (fork workflow)

AMA is designed so `git pull` never conflicts with your agent's self-modifications:

| File | Status | Notes |
|------|--------|-------|
| `core/`, `tools/` (built-in) | ✅ versioned | Receives upstream updates safely |
| `brain/tools.json` | ✅ versioned | Base tool registry — upstream adds new tools here |
| `brain/system_prompt.md` | ✅ versioned | Base prompt — upstream improves it here |
| `brain/config.json` | 🔒 gitignored | Your whitelist/config — copy from `config.example.json` |
| `brain/tools_extra.json` | 🔒 gitignored | Agent-added custom tools — merged at runtime |
| `brain/state/` | 🔒 gitignored | All runtime state (history, memory, sessions) |
| `tools/custom/` | 🔒 gitignored | Agent-created tool scripts |
| `brain/skills/` | 🔒 gitignored | User/agent skills |
| `SOUL.md` | 🔒 gitignored | Your persona — copy from `SOUL.md.example` |

**The agent writes to gitignored paths only** — it adds custom tools to `brain/tools_extra.json` (not `brain/tools.json`), and creates scripts in `tools/custom/` (not `tools/`). You can always `git pull` without conflicts.

```bash
# Update your fork with upstream improvements
git pull origin master   # or: git fetch origin && git merge origin/master
# No conflicts — your config, custom tools, and state are all gitignored
```

---

## Tests

```bash
bash scripts/run_all_tests.sh
```
