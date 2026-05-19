# Slash Commands

Everything the user can type that doesn't go straight to the LLM. Implemented in [`core/telegram/router.sh`](../core/telegram/router.sh).

## Session

| Command | What it does |
|---|---|
| `/new` or `/reset` | Archive current history, start fresh session. Clears active skill, goal, queue, prefetch. |
| `/retry` | Re-run the last user message (trims trailing assistant + tool turns first) |
| `/undo` | Drop the last exchange from history |
| `/stop` | Kill the running agent worker for this session. `/stop all` kills every running worker. |
| `/queue <text>` | Queue a message to run after the current turn ends |
| `/steer <note>` | Inject guidance into the agent's next tool result without interrupting it |
| `/btw <question>` | Ephemeral side-question — uses current session as context but doesn't write to history, no tools, no thinking (fast + cheap). [Details](self_improvement.md#btw) |
| `/goal <prose>` | Autonomous goal loop — judge decides DONE/CONTINUE/FAIL each turn. Also: `status`, `stop`, `pause`, `resume`, `max <n>`. [Details](self_improvement.md#goal-loop) |
| `/schedule add every=<dur> "<prompt>" [model=X] [provider=Y]` | Recurring task. Also: `list`, `remove <id>`, `pause <id>`, `resume <id>`. [Details](self_improvement.md#scheduler) |

## Config

| Command | What it does |
|---|---|
| `/model <name>` | Switch model for this session. `/model default` to reset to env value. |
| `/skill <name>` | Manually bind a skill. `/skill off` to clear. (Auto-routing usually picks the right one automatically.) |
| `/skills` | List available skills |
| `/providers` | Show all providers + their pool status |
| `/models` | List available models for the current provider. `/models <name>` to switch. |
| `/topic <name>` | Name the current chat/thread topic (used for per-topic default skill bindings) |
| `/google_login` | Begin Google OAuth flow (free Code Assist tier) |
| `/google_login_callback <redirect-url>` | Complete the OAuth flow |
| `/group mode [active\|mention_only\|silent]` | Per-group reply behavior (admin only, group chats) |

## Info

| Command | What it does |
|---|---|
| `/status` | Model, session age, message count, active workers, queue depth |
| `/usage` | Token usage this session |
| `/insights` | Token + tool-frequency stats |
| `/history [n]` | Show last N turns (default 10) |
| `/sessions` | List recent sessions with lineage (parent → child on compression) |
| `/help` | The full command list |

## Admin (TG_ADMIN only)

| Command | What it does |
|---|---|
| `/whitelist <id>` | Add user/chat to whitelist (writes `brain/config.json` + audit log) |
| `/reload` | Hot-reload core files (no restart) — `SIGHUP` to bot.pid |
| `/restart` | Full restart via pm2 |
| `/shutdown` | Stop the bot |

## Reactions on user messages

When `TG_REACTIONS=1` (default):
- 👀 — bot received your message, working on it
- ✅ — agent finished cleanly
- 👎 — agent failed or hit max-turns

## Topic-based auto-routing

If you message in a Telegram topic that's been bound to a skill (via `brain/config.json` `group_topics`), the agent auto-loads that skill before processing.

The keyword auto-router (`tools/skill_router.py`) ALSO scans your message text for skill `triggers:` and overrides the topic default per-message. See [`skills.md`](skills.md) for how triggers work.

## Status-query circuit breaker

When your message matches a status-query shape (`how many X`, `list X`, `show me X`, `what's my X`, `is X running`, `count X`), the agent:
1. Receives a `STATUS QUERY` bullet in `context_prompt` reminding it to answer in 1 tool call
2. Has `MAX_TURNS` clamped to 2 for that turn — forces a final answer even if the model tries to over-investigate

Lifted from a real incident where the agent burned 6 tool calls and 96 seconds to answer "how many scheduled tasks?" when 1 call would do.
