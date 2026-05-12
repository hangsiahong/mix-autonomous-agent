# AMA Killer Features & Capabilities

Capability map for the agent — prevents duplication, tracks what's implemented.

---

## 🧠 Cognitive Layer

- **Memory Auto-Prefetch (async)**: Pre-warmed after each turn in background (`brain/state/prefetch_<sid>`). Consumed at 0 latency on next turn. Cold-start fallback: 2s inline search. Toggle: `MEMORY_PREFETCH=0`.
- **Chunked Semantic Memory**: LanceDB via `tools/memory_helper.py`. Texts >400 words chunked with 50-word overlap, each chunk embedded separately. Access frequency tracked per entry.
- **Memory Pruning**: Monthly cron removes entries unused 30+ days. CLI: `python3 tools/memory_helper.py prune 30 --dry-run`.
- **Session Recaps**: Structured recap after tool-heavy turns → `session_recaps.jsonl` + LanceDB. Last 3 recaps injected at **top** of system prompt (labeled "READ THIS FIRST").
- **Session Recall Fast Path**: `tools/last_session.sh` reads recaps directly (~0.1s, no embeddings). Agent instructed to use this before `session_search`.
- **Weekly Memory Consolidation**: Cron extracts new facts from session recaps → appends to `MEMORY.md`.
- **Reflection Core** (`core/mix/26_reflection.sh`): Background after each turn. Calls `read_error_log`, saves memory facts. Breaks on FAIL response (no more empty-payload loops).
- **SQLite Session DB** (`tools/session_db.py`): Durable metadata, FTS5 message search, compression lineage (`parent_session_id`). CLI: create/end/update/link/sync/list/lineage/search/stats.
- **Context Compression** (`core/mix/30_compression.sh`): Token-based trigger (~80K). 7-section hermes-style summary. Pre-prunes large tool results before summarizing.
- **Self-Healing Loop** (`core/mix/27_self_heal.sh` + `tools/error_analyzer.py`):
  - Pattern detection: 3+ same API error in 24h → `heal_request.json`
  - Self-heal session: diagnostic loop with write access to `tools/`, blocks `core/` (sends to admin via `clarify`)
  - Cron alerts admin (max once/hour), auto-archives addressed errors
  - CLI: `python3 tools/error_analyzer.py report|clear|patterns|create_request`

---

## 🛠 Skills & Autonomy

- **Skill Manager** (`tools/skill_manager.sh`): Agent creates/lists/binds skills. `/skill`, `/skills` commands.
- **Toolset System**: 30 tools across 6 toolsets. Default: core+search+memory+meta. `inspect`/`media` on-demand.
- **AST-based Python Editor** (`tools/ast_edit.py`): Structurally safe — validates syntax before and after every change. Actions: `validate`, `list_symbols`, `get_symbol`, `replace_func`, `add_import`, `rename`. Impossible to produce broken Python.
- **Custom Tools → `brain/tools_extra.json`**: `custom_tool_manager` writes to gitignored `tools_extra.json` (merged at runtime), not base `brain/tools.json`. Upstream updates never conflict.
- **Plan/Todo Injection**: If `brain/state/todo_default.json` has pending items, `## Active Plan` is prepended to every API call. Agent sees its own checklist every turn.
- **Dynamic Access Control**: Whitelist via `core/config.sh` (atomic writes).

---

## 💬 Commands (full list)

| Category | Commands |
|----------|---------|
| Session | `/stop`, `/stop all`, `/new`, `/retry`, `/undo`, `/steer`, `/queue` |
| Config | `/model`, `/skill`, `/skills`, `/topic` |
| Info | `/status`, `/usage`, `/history`, `/sessions`, `/last_session`, `/insights`, `/help` |
| Admin | `/whitelist`, `/restart`, `/shutdown` |

Key behaviors:
- **`/steer`**: drained into last tool result after tool batch; if no tools, injects as user guidance + triggers one more turn
- **`/queue`**: FIFO — popped after flock releases, spawns new `run_agent` call
- **`/model`**: per-session file override, cleared on `/new`
- **`/retry`**: trims history to before last user message, re-runs
- **`/sessions`**: reads SQLite DB — lineage, token counts, status

---

## 🌐 Web & Browser

- **`fetch_url`**: Jina Reader + httpx fallback. SSRF guard. LLM summarization for long pages.
- **`browser` (Playwright)**: Headless Chromium. JS-heavy pages, click/type/scroll. SSRF guard.
- **`web_search`**: Auto-selects: Tavily → Exa → Brave → SearXNG → DuckDuckGo.

---

## 📡 Telegram UX

- **Reactions**: `tg_react()` → 👀 on receive, ✅ on done, 👎 on error. `TG_REACTIONS=1`.
- **Reply threading**: every bot response uses `reply_to_message_id`.
- **Tool progress display**: `` `🛠️ bash: command` `` code blocks during streaming.
- **Photo album batching**: `media_group_id` → 1s buffer → single agent call.
- **Group @mention gate**: `REQUIRE_MENTION=1` — respond only when @mentioned.
- **Stream retry**: auto-reconnect once on network drop. Shows `⏳ Reconnecting…`.
- **Max-turns notice**: 👎 + ⚠️ warning + retry instructions.
- **Smart folding**: long outputs → `--- [N lines folded | M error(s) | git: +X/-Y] ---`.
- **Error hints in bash**: 💡 hint on non-zero exit (pip install, chmod, port in use, etc.).

---

## 🔌 Engine & Infrastructure

- **Provider fallback chain**: `FALLBACK_PROVIDER=provider:model` activates on 2nd retry.
- **Agent process cap**: `MAX_CONCURRENT_AGENTS=10` (env var) — rejects with user-facing notice.
- **Atomic writes**: `save_history`, `save_config` use `mktemp + mv`.
- **Session idle auto-reset**: `SESSION_IDLE_HOURS` archives and resets stale sessions.
- **Async memory prefetch**: post-turn background pre-warm, 0 latency hot path.
- **Cron dedup**: `flock` lock prevents multiple parallel instances on bot restart.
- **pm2**: `pm2.config.js`, `autorestart: true`. `/restart` delegates to `pm2 restart ama-bot`.
- **Docker**: Debian slim + Playwright Chromium. `pm2-runtime` entrypoint.

---

## 🛡 Stability & Safety

- **`/stop` race fix**: PID written inside flock. Stop flag catches queued processes.
- **tools.json crash safety**: reflection uses `mktemp` backup + `trap` always restores.
- **Empty-payload guard**: `_api_build_payload` exits with code 2 if no user messages (prevents "Model input cannot be empty" retry loops).
- **Error classifier**: `bad_request_permanent` for empty/thought_signature errors (non-retryable).
- **Fork-safe gitignore**: `brain/config.json`, `brain/tools_extra.json`, `tools/custom/`, `SOUL.md` all gitignored. `git pull` never conflicts with agent self-modifications.
- **Multi-Line Fuzzy Edit** (`tools/edit_code.sh`): 9-strategy fuzzy matcher. Syntax gate. Auto-revert.
- **V4A Atomic Patch** (`tools/patch.sh`): Multi-file, phase-1 validate → phase-2 apply.
- **Hardened Bash** (`tools/bash.sh`): Blocklist, exit-code analysis, 💡 hints, timeout.
- **Prompt Injection Scanner**: Blocks injection patterns in system_prompt.md before injection.
