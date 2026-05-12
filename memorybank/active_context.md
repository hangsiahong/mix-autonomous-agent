# Active Context

## Current Status (2026-05-13)
- **Branch**: `improve` — comprehensive harness upgrade, all major features landed
- **Running under pm2** against Google Vertex AI (Gemini 3 Flash Preview, global region)
- **30 tools**, SQLite session DB, LanceDB vector memory, self-healing loop active

---

## Everything landed on `improve` branch (chronological)

### 1. Vertex AI / Gemini 3 — thought_signature fix
- Captured `thoughtSignature` in stream deltas (OpenAI-compat + native Gemini)
- Fixed `google_filter_history` stdin bug (was silently a no-op)
- Native payload builders now restore `thoughtSignature` on subsequent turns

### 2. Openclaw-style tool streaming UX
- Each tool shown as `` `🛠️ bash: command` `` during streaming (code block format)
- `_Working…_` italic header above tool lines
- `google_stream.py` and `18_streaming_api_call.sh` both updated

### 3. Hermes patterns ported
- **Reactions**: `tg_react()` → 👀 receive, ✅ done, 👎 error/max-turns (`TG_REACTIONS=1`)
- **Reply-to threading**: every bot response threads to user's original message
- **Photo album batching**: 1s buffer, coalesces `media_group_id` albums into one call
- **Group @mention gate**: `REQUIRE_MENTION=1` — only respond when @mentioned
- **Stream retry**: auto-reconnect once on network drop before showing error
- **10 new commands**: `/retry`, `/undo`, `/model`, `/usage`, `/steer`, `/queue`, `/history`, `/topic`, `/sessions`, `/stop all`
- **`/steer`**: queued in `brain/state/steer_<sid>`, drained into last tool result after batch; if no tools called, injects as user guidance and continues loop
- **`/queue`**: FIFO file, popped one-per-turn after current completes (outside flock)
- **`/model`**: per-session override in `brain/state/model_<sid>`, cleared on `/new`

### 4. /stop race condition — fully fixed
- PID file written **inside** flock (always points to running process)
- Stop flag file (`brain/state/stop_<sid>`) catches queued processes after kill
- `/stop` edits dangling "⏳ Thinking…" to "🛑 Stopped."

### 5. Hermes-pattern memory & sessions
- **Memory auto-prefetch (async)**: pre-warmed after each turn into `brain/state/prefetch_<sid>`, consumed at 0 latency next turn
- **SQLite session DB** (`tools/session_db.py`): FTS5 search, compression lineage, token counts
- **Session recaps**: structured summary → `session_recaps.jsonl` + LanceDB after tool-heavy turns
- **Recent recaps injected at TOP of system prompt** (clearly labeled "READ THIS FIRST")
- **Session idle auto-reset**: `SESSION_IDLE_HOURS` (default 0=disabled)
- **Atomic writes**: `save_history`, `save_config` use `mktemp + mv`
- **Provider fallback chain**: `FALLBACK_PROVIDER=provider:model`
- **Agent process cap**: `MAX_CONCURRENT_AGENTS=10`
- **Media download timeout**: 30s + 10MB/s rate limit

### 6. Compression improvements (hermes-style)
- 7-section structured summary (Active Task, Goal, Completed Actions, etc.)
- Token-based trigger (~80K) instead of message count
- Pre-compression pruning of large tool results
- Tool result cap: `append_tool_result` truncates >6000 chars (head 4K + tail 1K)

### 7. Self-healing loop
- **`tools/error_analyzer.py`**: FTS pattern detection, 3+ hits in 24h = create `heal_request.json`
- **`core/mix/27_self_heal.sh`**: picked up at session start, runs diagnostic loop
  - Has write access to `tools/` — can fix tool scripts directly
  - Core files (`core/`, `bot.sh`) blocked — sends description via `clarify` to admin
- **Reflection** now calls `read_error_log` automatically; breaks on FAIL responses
- **Cron**: error pattern detection → alert (max once/hour) → heal request creation
- **`error_analyzer.py clear <hours>`**: archives acknowledged errors so alerts stop

### 8. Level 4 harness — reduce LLM cognitive load
- **Smart folding**: 200-line outputs → `--- [142 lines folded | 3 error(s) | git: +15/-8] ---`
- **Error hints in bash**: on non-zero exit, 💡 hint injected (pip install, chmod, port in use, etc.)
- **Plan/todo injection**: `brain/state/todo_default.json` injected as `## Active Plan` at top of every turn
- **`tools/ast_edit.py`**: AST-aware Python editor (validate, list_symbols, get_symbol, replace_func, add_import, rename) — structurally impossible to produce syntax errors

### 9. Session recall fix
- **Memory priority order** in system prompt: context first → `last_session` tool → `session_search` (slow, last resort)
- **`tools/last_session.sh`**: instant recall from `session_recaps.jsonl` (~0.1s, no embeddings)
- **Session recaps injected at TOP** with "READ THIS FIRST" label — agent no longer over-searches

### 10. Bug fixes
- `reflect_turn`: break on FAIL response (was looping 5x, each generating "Model input cannot be empty" errors)
- `_api_build_payload`: guard against empty history (sys.exit(2) if no user messages)
- `34_error_classifier.sh`: "cannot be empty" and "thought_signature" → `bad_request_permanent` (non-retryable)
- FutureWarning suppressed in `memory_helper.py`
- `/usage` command: fixed session_id filter (was comparing wrong values)
- Cron: `_now` now defined at top (was used before definition), `needs_attention` only fires for error patterns (not normal tool usage), flock dedup prevents multiple parallel cron instances on bot restart

### 11. Fork-safe architecture
- `brain/config.json` → **gitignored** (copy from `brain/config.example.json`)
- `brain/tools_extra.json` → **gitignored** (agent custom tools, merged at runtime)
- `tools/custom/` → **gitignored** (agent tool scripts)
- `SOUL.md` → **gitignored** (persona, copy from `SOUL.md.example`)
- `custom_tool_manager` now writes to `brain/tools_extra.json` (not base `brain/tools.json`)
- `git pull` never conflicts — agent writes only to gitignored paths

---

## Key files added in this branch
```
core/mix/27_self_heal.sh         — self-healing diagnostic loop
tools/error_analyzer.py          — error pattern detection + archiving
tools/session_db.py              — SQLite session manager CLI
tools/ast_edit.py                — AST-aware Python editor
tools/last_session.sh            — instant session recap recall
brain/config.example.json        — setup template
SOUL.md.example                  — persona template
```

## What's still left (future work)
- `/branch` + `/rollback` — snapshot history before risky work
- `/approve` / `/deny` — Telegram confirmation gate for dangerous tools
- Memory dreaming / background consolidation (openclaw pattern)
- Per-session `require_mention` toggle
