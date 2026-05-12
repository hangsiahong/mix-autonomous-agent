# Active Context

## Current Status (2026-05-13)
- **Branch**: `improve` — comprehensive harness upgrade in progress
- **Stable under pm2** — all features tested against Google Vertex AI Gemini 3 Flash
- **30+ tools**, 6 toolsets, Playwright browser, SQLite session DB, LanceDB vector memory

## Major Changes Landed (improve branch — May 2026)

### Vertex AI / Gemini 3 Fixes
- **`thought_signature`**: Captured from stream deltas and restored in API payloads — fixes 400 errors on Gemini 3 thinking models
- **`google_filter_history`**: Fixed stdin bug (was reading `sys.argv[1]` instead of `sys.stdin`) — filter was silently a no-op
- **Native payload builders**: Both `google_call_api` and `google_call_api_stream` now restore `thoughtSignature` in `function_call` parts

### Telegram UX (openclaw patterns)
- **Reactions** (`TG_REACTIONS=1`): 👀 on receive, ✅ on done, 👎 on max-turns/error via `tg_react()`
- **Reply-to threading**: All bot responses are `reply_to_message_id` of user's original message
- **Tool progress display**: `_Working…_` header + individual tool lines in backtick code blocks
- **Photo album batching**: Detects `media_group_id`, buffers 1s, coalesces into one agent call
- **Group @mention gate**: `REQUIRE_MENTION=1` env var — only respond when @mentioned in groups
- **Stream retry**: Auto-reconnects once on network drop before showing error

### New Slash Commands
| Command | What it does |
|---------|-------------|
| `/retry` | Trim history to before last user message, re-run it |
| `/undo` | Remove last exchange from history |
| `/model <name>` | Per-session model override (stored in `brain/state/model_<sid>`) |
| `/usage` | Token counts for this session from usage_log.jsonl |
| `/steer <note>` | Inject guidance mid-run after next tool call |
| `/queue <text>` | FIFO queue — processed after current turn |
| `/history [n]` | Show last N conversation turns |
| `/topic <name>` | Name this Telegram thread/topic |
| `/sessions [n]` | List recent sessions with lineage and token counts |
| `/stop all` | Kill every running session + edit all dangling messages |

### /stop race condition fix
- PID file now written **inside** the flock (always points to running process, not queued)
- Stop flag file (`brain/state/stop_<sid>`) catches queued processes after kill
- `/stop` edits the dangling message to "Stopped."

### Memory and Sessions (hermes patterns)
- **Memory auto-prefetch**: Every API call queries LanceDB with current user input (3s timeout), injects `<memory-context>` fence into last user message (not system prompt — preserves prefix cache)
- **Session recaps**: End-of-session structured summary saved to `session_recaps.jsonl` + LanceDB
- **Recent recaps in context**: Last 3 session recaps injected into system prompt
- **Session idle auto-reset**: `SESSION_IDLE_HOURS` env var (0=disabled)
- **`tools/session_db.py`**: Full SQLite session manager — FTS5 message search, compression lineage, token tracking
- **Compression lineage**: `parent_session_id` recorded in SQLite on context compression

### Compression Improvements (hermes patterns)
- **Structured summary**: 7 sections — Active Task, Goal, Completed Actions, Current State, Key Context, Remaining Work, Important Facts
- **Token-based trigger**: ~80K tokens instead of naive message count
- **Pre-compression pruning**: Tool results >400 chars truncated before feeding to LLM summarizer
- **Tool result cap**: `append_tool_result` truncates outputs >6000 chars (head 4K + tail 1K)

### Reliability Fixes
- **Stream error recovery**: Shows partial content + warning instead of leaving "Thinking…" stuck
- **Agent process cap**: `MAX_CONCURRENT_AGENTS=10` rejects new messages when overloaded
- **Max-turns notification**: Shows warning + retry instructions instead of silent exit
- **tools.json race in reflection**: Uses unique `mktemp` backup + `trap` to always restore
- **Atomic writes**: `save_history`, `save_config` use `mktemp + mv`
- **Provider fallback chain**: `FALLBACK_PROVIDER=provider:model` activates on 2nd retry
- **Media download timeout**: 30s timeout + 10MB/s rate limit on `tg_download`

## Architecture Patterns in Use
- **hermes-agent**: Session state machine, compression lineage, memory prefetch, steer/queue, reactions, structured summaries
- **openclaw**: Tool progress display (backtick code blocks), reply-to threading, photo batching, @mention gate

## Immediate Next (if continuing)
- `/branch` + `/rollback` — snapshot history before risky work, restore on failure
- `/approve` / `/deny` — Telegram confirmation gate for dangerous tools
- Memory dreaming / background consolidation (openclaw pattern)
