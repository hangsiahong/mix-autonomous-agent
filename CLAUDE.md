# AMA — Autonomous Mix Agent

Telegram bot backed by a bash harness, running Google Vertex AI (Gemini 3 Flash Preview). Default branch: `master`. Valid `PROVIDER=` values (from `core/mix/providers/`): **google, anthropic, openrouter, deepseek, copilot, groq, kconsole, minimax, mistral, ollama, xai, zai**. For Vertex AI: `PROVIDER="google"` + `GOOGLE_MODE="vertex"` (NOT `PROVIDER="vertex"`).

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
| `tools/session_db.py` | SQLite session manager + FTS5 helpers (`search_messages_with_context`, `get_message_window`, `get_session_bookends`, `list_recent_sessions`) |
| `tools/session_search.sh` | No-LLM recall — three modes (discovery / scroll / browse) over FTS5 |
| `tools/error_analyzer.py` | Error pattern detection, heal_request creation |
| `tools/token_budget.py` | Self-throttle parser. User says `+500k` / `spend 50k tokens` → budget enforced on this session |
| `tools/tool_search.py` + `.sh` | Deferred-tool loader. 14 deferred tools surface by name only; `tool_search(query=…)` loads schemas |
| `tools/task.sh` + `task_manager.py` | Cross-session task list (SQLite at `brain/state/tasks.db`); statuses: pending/in_progress/completed/failed/deleted |
| `tools/clarify.sh` | Asks the user. With `options=[...]` renders Telegram inline-keyboard buttons (qid-protected against stale taps) |
| `tools/file_mutation_check.py` | Post-batch verifier — stats every write-tool target path, footer appended to last tool result |
| `tools/mix_call.py` | OpenAI-compat helper for background tasks. Reads `brain/tier_routing.json`; main user-facing turn does NOT use this — it stays on Vertex |
| `tools/memory_critic.py` | Cheap-model gatekeeper for memory writes. Wired into `memory.sh` (add/replace) and `memory_remember.sh`. Killswitch: `AMA_MEM_CRITIC_DISABLED=1` |
| `tools/citation_check.py` | Event-driven hallucination scanner. Cheap regex pre-filter; only invokes LLM when fact patterns appear in the reply. Writes `brain/state/citation_warnings_<sid>.json` |
| `tools/delegate_prep.py` | Wraps `delegate.py` sync path: prompt critique + 24h result cache + post-run sanity check. Per-call opt-out: `TOOL_skip_prep=1` |
| `tools/provider_caps.py` + `brain/provider_capabilities.json` | Per-(provider,model) capability map (tools/thinking/cache/structured_output/vision/max_context) |
| `tools/mistake_db.py` + `tools/mistake_detect.py` | Per-user correction recall — regex pre-filter + cheap-model extraction; embedded via Vertex `text-embedding-004`; SQLite at `brain/state/mistakes.db` |
| `tools/voice_check.py` | Style drift detector — only runs when USER.md has voice-related entries |
| `tools/md_to_html.py` | Markdown→Telegram-HTML renderer. Includes `_auto_wrap_tables()` pre-pass that fences raw `| col \| col |` lines so they render as monospace `<pre>` |
| `core/mix/14_tool_distill.sh` | Semantic distill for whitelisted info tools (web_search/fetch_url/memory_recall/session_search/browser). Called from `append_tool_result`. Audit at `brain/state/distill_audit/` |
| `brain/tier_routing.json` | Per-tier provider+model for background tasks (distill / memory_critic / memory_writer / classify / research_subq / delegate_prep / citation / voice_check / heavy). Main turn config lives in `.env`, NOT here |
| `brain/skills/research/` | Multi-source research protocol skill (auto-binds on "research/investigate/look into") |
| `brain/tools.json` | Tool declarations (toolsets: core/search/memory/meta/inspect/media + `defer: true` flag) |
| `brain/system_prompt.md` | Agent system prompt — includes Honesty & Citation rules + Telegram Formatting Cookbook |
| `extensions/cron/run.sh` | Cron jobs: health check, memory consolidation |

## Provider: Google Vertex AI

- Gemini 3 thinking models attach `thought_signature` to every `functionCall` part.
- Must be captured from stream, stored in history, re-sent on subsequent turns.
- `google_filter_history` pipes via stdin; both native payload builders restore `thoughtSignature`.
- Config: `PROVIDER=google`, `BASE_URL=...`, `MODEL=gemini-3-flash-preview` (or similar).

## Toolsets (default loaded each turn)
- `core`: bash, edit_code, patch, write_file, clarify, **tool_search**
- `search`: web_search, fetch_url, search_files, browser
- `memory`: memory, memory_remember, memory_recall, session_search
- `meta`: todo, process, custom_tool_manager, skill_manager, **task**, repo_map, last_session, delegate
- `inspect` (on-demand): repo_map, sys_info, read_error_log, insights
- `media` (on-demand): image_generate

## Deferred tools (marked `"defer": true` in brain/tools.json)
14 tools surface in the per-turn context as **`## Deferred Tools`** by NAME ONLY — their schemas are NOT in the payload. To call one, the agent must first run `tool_search(query="...")` (exact: `select:name1,name2`; keyword: `query="image"`). Activated tool stays loaded for the rest of the session via `brain/state/active_tools_<sid>.json`.

Currently deferred: `image_generate`, `kanban_show/create/complete/block`, `sys_info`, `read_error_log`, `insights`, `ast_edit`, `skill_install`, `custom_tool_manager`, `browser`, `scheduler`, `delegate`. Roughly ~1755 tokens saved per turn vs all-loaded.

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
| `budget_<sid>.json` | Token budget — set/spent/limit when user declared `+500k` |
| `active_tools_<sid>.json` | Deferred tools currently activated for this session |
| `clarify_<sid>.json` | Pending clarify question with options + qid (for button taps) |
| `tasks.db` | SQLite — cross-session structured task list (table `tasks`) |
| `sessions.db` | SQLite — sessions + messages + FTS5 index (`messages_fts`) for session_search |
| `mistakes.db` | SQLite — per-user correction recall (table `mistakes`); embedded via Vertex `text-embedding-004` |
| `citation_warnings_<sid>.json` | Last ≤3 hallucination flags from `citation_check.py`; injected as `## Citation Warnings` block next turn |
| `voice_warnings_<sid>.json` | Last voice-drift flag from `voice_check.py`; injected as `## Voice Reminder` next turn |
| `mix_call_usage.jsonl` | One line per background-tier call (tier, model, ok, tokens, ms) — audit for cheap-model spend |
| `memory_critic.log` | JSONL log of every accept/reject verdict from the memory critic |
| `distill_audit/<sid>_<ts>_<tcid>.txt` | Raw tool output before distillation; referenced from the distilled footer |
| `delegate_cache/<hash>.json` | 24h-TTL cache of delegate sync results, keyed by SHA256(backend + goal + context) |

## Common Tasks

**Add a new slash command:** Edit `core/telegram/router.sh` case block + `tg_set_commands` list.

**Add a new tool:** Create `tools/<name>.sh`, declare in `brain/tools.json` with `name/description/parameters/toolset`.

**Test without Telegram:** `AMA_DIR=. python3 tools/session_db.py stats` or `bash tools/repo_map.sh`.

**Check logs:** `tail -f logs/bot.log` (if running under pm2: `pm2 logs ama-bot`).

## Per-turn context blocks (injected by 16_api.sh)
The agent sees these as additional `[SYSTEM: Context Updated]` content each turn:
- `## Current Session Context` — date, model, vision status, working dir
- `## My Notes` / `## About the User` / `## Recent Session Recaps` — from `brain/state/MEMORY.md`, `USER.md`, `session_recaps.jsonl`
- `## Available Skills` — auto-bound + bindable
- `## Active Tasks` — open `task` entries for this session
- `## Deferred Tools` — names-only list of tools requiring `tool_search` to activate
- `## Prior Corrections` — fired when current input semantically matches a stored mistake for this user (cosine ≥ 0.82 via Vertex embeddings)
- `## Citation Warnings` — hallucinated claims flagged by `citation_check.py` on the previous turn
- `## Voice Reminder` — voice/style drift flagged by `voice_check.py` (only fires when USER.md has voice prefs)
- `Active budget: ... | ... used | ...% of cap` — if a token budget is set

## Post-turn background passes (24_agent_loop.sh)
Fired in a detached subshell after the agent loop completes (uses `( ( cmd & ) )` so it survives the EXIT trap). Order: `reflect_turn` → `citation_check` → `mistake_detect` → `voice_check` → optional `curator`. Each writes a per-session state file consumed by the NEXT turn's context block. Every pass fails open — kconsole rate limits or transient errors never block the next turn.

## Background-tier model routing (brain/tier_routing.json)
All background helpers route through **kconsole**, NOT Vertex. The user-facing main turn stays on Vertex (paid credits). Tier → model:
- `distill` / `memory_writer` / `research_subq` / `citation` → `gemini-3.1-flash-lite-preview` (no thinking overhead)
- `memory_critic` / `classify` / `voice_check` → `gemini-2.5-flash` (different family than writers — disagreement catches drift)
- `delegate_prep` → `gemini-3-flash-preview`
- `heavy` → `gemini-3.1-pro-preview`
- Embeddings stay on Vertex via `tools/memory_helper.py:get_embedding()` — do NOT route through kconsole

## Killswitches (for the fidelity passes)
All fail-open env vars: `AMA_DISTILL_DISABLED` · `AMA_MEM_CRITIC_DISABLED` · `AMA_CITATION_CHECK_DISABLED` · `AMA_MISTAKE_DETECT_DISABLED` · `AMA_VOICE_CHECK_DISABLED` · `AMA_DELEGATE_PREP_DISABLED`. Per-call: `TOOL_skip_prep=1` on `delegate`.

## Post-batch hooks (in 24_agent_loop.sh, after tool execution)
Order: file-mutation verifier footer → steer drain → fingerprint-circuit-breaker. All three mutate the last tool result in HISTORY before the next API call.
