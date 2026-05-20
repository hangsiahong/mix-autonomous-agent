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

### Killing agents — use `kill_tree_hard`, never raw `kill`
`router.sh` defines `kill_tree` and `kill_tree_hard` at the top — single source of truth for terminating an agent and everything it spawned. **Use them. Never hand-roll `kill -TERM` + `pkill -P`** (depth-1, misses grandchildren like `bash tool.sh → python3 → curl`).

```bash
[[ -n "$run_pid" ]] && kill_tree_hard "$run_pid"   # TERM → 1s grace → KILL survivors
```

How it works:
1. **Group-kill fast path**: bot.sh enables `set -m` at the outer scope AND inside the `while read -r update` pipe subshell, so every `( run_agent ... ) &` becomes its own process-group leader (PID == PGID). `kill_tree` detects this and signals the whole group with one `kill -- -$PGID` (verified safe: refuses to signal bot.sh's own PGID).
2. **Recursive walk fallback**: anything that escaped its group (rare: tools that `setsid`) is caught by depth-N `pgrep -P` recursion.
3. **SIGKILL escalation**: `kill_tree_hard` polls `kill -0` for up to 1s after TERM, then SIGKILLs survivors. Fixes the "stop does nothing for 60s" case caused by curl wedged on a socket.

Negative PID kill is now safe in this codebase precisely because of (1) — the PGID will never equal bot.sh's own group. Outside of `kill_tree`, still prefer positive PIDs to keep the explicit safety check in one place.

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
