# AMA Killer Features & Capabilities

This document tracks unique features implemented in AMA to prevent duplication and provide a capability map for the agent.

## 🧠 Cognitive Layer

- **Memory Auto-Prefetch**: Before every API call, `_api_build_payload` queries LanceDB with the current user input (3s timeout, 3 results). Result injected as `<memory-context>` fence into the last user message — NOT the system prompt, so prefix caching is preserved. Tags scrubbed from streaming output. Toggle: `MEMORY_PREFETCH=0`.
- **Chunked Semantic Memory**: LanceDB via `tools/memory_helper.py`. Texts >400 words split into overlapping 50-word chunks, each embedded separately. Access frequency and timestamps tracked automatically.
- **Memory Pruning**: Monthly cron job removes entries unused 30+ days. CLI: `python3 tools/memory_helper.py prune 30 --dry-run`.
- **Session Recaps**: After tool-heavy turns, a structured recap (Key Facts, Unresolved Items, Next Steps) is saved to `session_recaps.jsonl` + LanceDB. Last 3 recaps injected into every system prompt for cross-session continuity.
- **Reflection Core** (`core/mix/26_reflection.sh`): Background self-improvement loop after every turn. Limited to safe read-only tools. Uses `mktemp` backup + `trap` to survive crashes without leaving tools.json empty.
- **SQLite Session DB** (`tools/session_db.py`): Durable metadata store alongside JSON history files. Schema: sessions (id, user_id, model, parent_session_id, token counts) + messages (FTS5 indexed). Compression lineage recorded via `parent_session_id`. CLI: create/end/update/link/sync/list/lineage/search/stats.
- **Context Compression** (`core/mix/30_compression.sh`): Token-based trigger (~80K tokens). 7-section hermes-style summary (Active Task, Goal, Completed Actions, Current State, Key Context, Remaining Work, Important Facts). Pre-prunes large tool results before summarizing. Lineage tracked in SQLite.
- **Contextual Identity**: Multi-identity support via SOUL.md persona + per-topic skill binding.

## 🛠 Skills & Autonomy

- **Skill Manager** (`tools/skill_manager.sh`): Agent creates, lists, and binds skills. `/skill`, `/skills` Telegram commands list all core+user skills with validation.
- **Toolset System**: 30+ tools tagged across 6 toolsets. Default: core+search+memory+meta. `inspect` and `media` on-demand. Configurable per-skill via `_enabled_toolsets`.
- **Dynamic Access Control**: Whitelist and Home Chat management via `core/config.sh` (atomic writes).
- **Permission Layer** (`core/access_control.sh`): Detects sensitive tools and checks session-aware permission store.
- **Tool Result Cap**: `append_tool_result` truncates outputs >6000 chars (head 4K + tail 1K) to prevent history bloat.

## 💬 Telegram Commands (full list)

| Category | Commands |
|----------|---------|
| Session | `/stop`, `/stop all`, `/new`, `/retry`, `/undo`, `/steer`, `/queue` |
| Config | `/model`, `/skill`, `/skills`, `/topic` |
| Info | `/status`, `/usage`, `/history`, `/sessions`, `/insights`, `/help` |
| Admin | `/whitelist`, `/restart`, `/shutdown` |

### Command details
- **`/retry`**: Trims history to before last user message, re-runs it as a new agent turn
- **`/undo`**: Removes last exchange from history, reports preview
- **`/model <name>`**: Per-session model override stored in `brain/state/model_<sid>`, cleared on `/new`
- **`/steer <note>`**: Queued in `brain/state/steer_<sid>`, drained into last tool result after next tool batch
- **`/queue <text>`**: Appended to `brain/state/queue_<sid>` (FIFO), processed one-per-turn after current completes
- **`/history [n]`**: Shows last N turns (default 20) with role labels
- **`/sessions [n]`**: Lists recent sessions from SQLite with token counts and compression lineage
- **`/topic <name>`**: Persists topic name in `group_topics` config

## 🌐 Web & Browser

- **`fetch_url`**: Jina Reader primary, direct httpx fallback. SSRF guard, LLM summarization for long pages.
- **`browser` (Playwright)**: Headless Chromium. Navigates JS-heavy pages, clicks, types, scrolls. Aria-snapshot text output. SSRF guard.
- **`web_search`**: Auto-selects backend: Tavily → Exa → Brave → SearXNG → DuckDuckGo.

## 📡 Telegram UX (openclaw + hermes patterns)

- **Reactions**: `tg_react()` uses `setMessageReaction` API. 👀 on receive, ✅ on done, 👎 on error. Enabled via `TG_REACTIONS=1`.
- **Reply-to threading**: Every bot response uses `reply_to_message_id` pointing to the user's original message — creates a native Telegram thread.
- **Tool progress display**: During streaming, each tool shown as `` `🛠️ bash: command` `` (code block format), with `_Working…_` header.
- **Photo album batching**: Detects `media_group_id`, buffers 1s, coalesces all photos into one agent call. Prevents 5-photo albums from spawning 5 parallel agents.
- **Group @mention gate**: `REQUIRE_MENTION=1` — in groups, only respond when @mentioned or replied-to.
- **Stream retry**: Auto-reconnects once on network drop. Shows `⏳ Reconnecting…` then retries with clean state.
- **Max-turns notification**: On turn limit, shows ⚠️ warning + retry instructions + 👎 reaction.

## 🔌 Engine & Infrastructure

- **Provider fallback chain**: `FALLBACK_PROVIDER=provider:model` env var. On 2nd retry, activates fallback provider via `${provider}_activate`. Also supports `FALLBACK_MODEL` for same-provider model switch.
- **Agent process cap**: `MAX_CONCURRENT_AGENTS` (default 10). On overload, rejects with user-facing notice.
- **Atomic writes**: `save_history()`, `save_config()`, `append_tool_result()` all use `mktemp + mv` pattern.
- **Session idle auto-reset**: `SESSION_IDLE_HOURS` env var. On load, if history file older than threshold, archives and resets.
- **Streaming error recovery**: Both streaming paths (OpenAI-compat + native Gemini) show partial content + ⚠️ instead of leaving "Thinking…" stuck.
- **pm2 process manager**: `pm2.config.js` — `autorestart: true`. `/restart` Telegram command delegates to `pm2 restart ama-bot`.
- **Docker**: Single `Dockerfile` (Debian slim) with Playwright Chromium. `pm2-runtime` as entrypoint.
- **Reasoning Stream Capture**: Gemini 3 `thought` fields wrapped in `<think>` tags, scrubbed from Telegram UI.
- **Multi-Topic Isolation**: Telegram Forum Topics with isolated history, titles, and topic-bound skills.
- **Auto-Labeling**: Conversations auto-summarized into titles (`core/mix/28_summary.sh`).
- **Cron Extension**: `extensions/cron/` — runs every 5 min, trims logs, monthly memory pruning.

## 🛡 Stability & Safety

- **`/stop` race condition fix**: PID file written inside flock (always points to running process, never queued). Stop flag file catches queued processes after kill.
- **tools.json crash safety**: Reflection uses `mktemp` unique backup + `trap` on EXIT/INT/TERM to always restore.
- **Multi-Line Fuzzy Edit** (`tools/edit_code.sh`): 9-strategy fuzzy matcher. Unified diff output. Syntax gate (bash/python/json). Auto-revert on failure.
- **V4A Atomic Patch** (`tools/patch.sh`): Multi-file/multi-hunk patches. Phase 1 validates all hunks in memory, Phase 2 applies atomically.
- **Path Safety Library** (`tools/_lib/path_safety.py`): Blocks writes outside project root, sensitive system paths.
- **Hardened Bash Executor** (`tools/bash.sh`): Blocklist covers credential exfil, reverse shells, destructive ops. 30s timeout (max 120s), configurable per call.
- **Prompt Injection Scanner**: Blocks obvious injection patterns in system_prompt.md and context files before injection.
