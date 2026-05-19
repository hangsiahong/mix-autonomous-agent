# AMA — Autonomous Mix Agent

Telegram bot backed by a bash harness, running Google Vertex AI (Gemini 3 Flash Preview). Branch: `improve`.

## Architecture

```
bot.sh  →  core/telegram/router.sh  →  run_agent() [24_agent_loop.sh]
                                             ↓
                                    core/mix/16_api.sh (build payload)
                                    core/mix/18_streaming_api_call.sh
                                    core/mix/providers/google_stream.py
```

- **One flock per session_id** (`brain/state/locks/<sid>.lock`). Agent PID written INSIDE the flock.
- **Tools**: `tools/*.sh` + `tools/*.py`. Declared in `brain/tools.json`; agent-created extras in `brain/tools_extra.json` (gitignored).
- **Memory**: LanceDB via `tools/memory_helper.py`. Session recaps in `brain/state/session_recaps.jsonl`.
- **Session DB**: SQLite via `tools/session_db.py` (FTS5 search, compression lineage).

## Critical Bash Rules

### PID handling — `$$` vs `$BASHPID`
In bash, `$$` inside `( ... )` subshells returns the **top-level shell's PID**, NOT the subshell's own PID.

**Always capture `$BASHPID` BEFORE entering a subshell:**
```bash
local _agent_pid=$BASHPID        # correct: actual process PID
( flock -x 200
  echo "$_agent_pid|..." > "$pid_file"   # NOT $$
  ...
) 200>"$lock_file"
```

### Killing agents — never use negative PID
`kill -TERM "-PID"` sends SIGTERM to the entire **process group** — this kills bot.sh.

**Always use positive PID + pkill for children:**
```bash
kill -TERM "$run_pid" 2>/dev/null || true
sleep 0.3
pkill -TERM -P "$run_pid" 2>/dev/null || true
```

### History filters — use stdin not argv
Python scripts called from bash history filters must read from `sys.stdin`, not `sys.argv[1]`.

## Key Files

| File | Purpose |
|------|---------|
| `bot.sh` | Entry point, long-poll loop, MAX_CONCURRENT_AGENTS cap |
| `core/telegram/router.sh` | All slash commands (/stop /retry /undo /model /steer /queue …) |
| `core/mix/24_agent_loop.sh` | `run_agent()`: flock, PID file, turn loop, tool execution |
| `core/mix/16_api.sh` | Payload builder: memory prefetch, plan injection, session recaps |
| `core/mix/18_streaming_api_call.sh` | Streaming + thought_signature capture |
| `core/mix/providers/google_stream.py` | Native Vertex AI SSE stream parser |
| `core/mix/providers/google.sh` | `google_filter_history()`, payload builder, response normalizer |
| `core/mix/11_history.sh` | History load/save (atomic), smart folding, SQLite sync |
| `core/mix/26_reflection.sh` | Post-turn reflection + session recap saving |
| `core/mix/27_self_heal.sh` | Self-healing: picks up heal_request.json at session start |
| `core/mix/30_compression.sh` | Hermes-style 7-section summary compression |
| `tools/delegate.py` | Sub-agent delegation (Claude Code CLI / Codex / self backends) |
| `tools/ast_edit.py` | Python AST-based structural editing |
| `tools/session_db.py` | SQLite session manager |
| `tools/error_analyzer.py` | Error pattern detection, heal_request creation |
| `brain/tools.json` | Tool declarations (toolsets: core/search/memory/meta/inspect/media) |
| `brain/system_prompt.md` | Agent system prompt |
| `extensions/cron/run.sh` | Cron jobs: health check, memory consolidation |

## Provider: Google Vertex AI

- Gemini 3 thinking models attach `thought_signature` to every `functionCall` part.
- Must be captured from stream, stored in history, re-sent on subsequent turns.
- `google_filter_history` pipes via stdin; both native payload builders restore `thoughtSignature`.
- Config: `PROVIDER=google`, `BASE_URL=...`, `MODEL=gemini-3-flash-preview` (or similar).

## Toolsets (default loaded each turn)
- `core`: bash, edit_code, patch, write_file, clarify
- `search`: web_search, fetch_url, search_files, browser
- `memory`: memory, memory_remember, memory_recall, session_search
- `meta`: todo, process, custom_tool_manager, skill_manager, **repo_map**, **last_session**, **delegate**
- `inspect` (on-demand): repo_map, sys_info, read_error_log, insights
- `media` (on-demand): image_generate

## State Files (brain/state/)

| Pattern | Purpose |
|---------|---------|
| `run_<sid>.pid` | `$BASHPID|msg_id|chat_id|thread_id` — active agent |
| `stop_<sid>` | Stop flag (touch = stop requested) |
| `steer_<sid>` | /steer text pending injection |
| `queue_<sid>` | /queue messages (one per line) |
| `model_<sid>` | Per-session model override |
| `prefetch_<sid>` | Pre-warmed memory context for next turn |
| `history_<sid>.json` | Conversation history |

## Common Tasks

**Add a new slash command:** Edit `core/telegram/router.sh` case block + `tg_set_commands` list.

**Add a new tool:** Create `tools/<name>.sh`, declare in `brain/tools.json` with `name/description/parameters/toolset`.

**Test without Telegram:** `AMA_DIR=. python3 tools/session_db.py stats` or `bash tools/repo_map.sh`.

**Check logs:** `tail -f logs/bot.log` (if running under pm2: `pm2 logs ama-bot`).
