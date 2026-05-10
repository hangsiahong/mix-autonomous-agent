# AMA Killer Features & Capabilities

This document tracks unique features implemented in AMA to prevent duplication and provide a capability map for the agent.

## 🧠 Cognitive Layer
- **Reflection Core (`core/mix/26_reflection.sh`)**: Background self-improvement loop that runs after every turn. Reviews actions, fixes bugs, and proactively creates skills.
- **Chunked Semantic Memory**: LanceDB via `tools/memory_helper.py`. Texts >400 words are split into overlapping chunks (50-word overlap), each embedded separately for precise retrieval. Access frequency and timestamps tracked automatically.
- **Memory Pruning**: Monthly cron job removes entries unused for 30+ days. CLI: `python3 tools/memory_helper.py prune 30 --dry-run`.
- **Contextual Identity**: Multi-identity support via system prompt overrides.

## 🛠 Skills & Autonomy
- **Skill Manager (`tools/skill_manager.sh`)**: Agent creates, lists, and binds skills. `/skill`, `/skills` Telegram commands list all core+user skills with validation.
- **Toolset System**: 24 tools tagged across 6 toolsets. Default loads core+search+memory+meta (~16 tools). `inspect` and `media` on-demand. Configurable per-skill via `_enabled_toolsets`.
- **Dynamic Access Control**: Whitelist and Home Chat management via `core/config.sh`.
- **Permission Layer (`core/access_control.sh`)**: Detects sensitive tools and checks session-aware permission store.
- **Resilience & Retry Strategy**: System prompt encodes per-tool fallback rules (web search → rephrase/browser; fetch_url fails → browser; edit_code no-match → re-read first; memory empty → try 3 phrasings).

## 🌐 Web & Browser
- **`fetch_url`**: Jina Reader primary, direct httpx fallback. SSRF guard, LLM summarization for long pages.
- **`browser` (Playwright)**: Headless Chromium. Navigates JS-heavy pages, clicks, types, scrolls. Aria-snapshot text output with interactive element listing. SSRF guard. In `search` toolset (always loaded).
- **`web_search`**: DuckDuckGo search.

## 🔌 Engine & Infrastructure
- **pm2 process manager**: `pm2.config.js` — `autorestart: true`, logs to `logs/`. `/restart` Telegram command delegates to `pm2 restart ama-bot`.
- **Docker**: Single `Dockerfile` (Debian slim) with Playwright Chromium system deps. `pm2-runtime` as entrypoint.
- **`requirements.txt`**: Python dependency manifest for clean deploys.
- **Reasoning Stream Capture**: Gemini 3 `thought` fields wrapped in `<think>` tags, scrubbed from Telegram UI.
- **Multi-Topic Isolation**: Telegram Forum Topics with isolated history, titles, and topic-bound skills.
- **Vertex AI Optimization**: Native Vertex AI Gemini support. `text-embedding-004` for memory.
- **Auto-Labeling**: Conversations auto-summarized into titles (`core/mix/28_summary.sh`).
- **Cron Extension**: `extensions/cron/` — runs every 5 min, trims logs, monthly memory pruning.

## 🛡 Stability & Safety
- **Multi-Line Fuzzy Edit (`tools/edit_code.sh`)**: 9-strategy fuzzy matcher. Unified diff output. Syntax gate (bash/python/json). Auto-revert on failure.
- **V4A Atomic Patch (`tools/patch.sh`)**: Multi-file/multi-hunk patches. Phase 1 validates all hunks in memory, Phase 2 applies atomically.
- **Path Safety Library (`tools/_lib/path_safety.py`)**: Blocks writes outside project root, sensitive system paths, home dotfiles, device files.
- **Hardened Bash Executor (`tools/bash.sh`)**: Blocklist covers credential exfil, reverse shells, destructive ops, invisible Unicode. Configurable timeout (default 30s).
- **Validated Custom Tool Manager**: Name regex, `bash -n` syntax gate, danger-pattern scan, refuses to shadow built-ins.
- **Smart History Compaction**: `core/mix/30_compression.sh` summarizes middle turns. Handles OpenAI + Gemini formats.
- **Tool Loop Guardrails**: Detects identical repeated tool calls, caps same tool at 3/turn.
- **Usage Insights**: `tools/insights.sh` tracks tokens and tool frequency.

## 💬 Telegram UX
- **Single-draft message flow**: One message per user turn, continuously edited.
- **HTML formatting**: `parse_mode: HTML` with `md_to_tg_html()`. Supports bold, italic, code, pre, strikethrough, links.
- **Deduped tool footer**: `🔧 N tool calls: tool_a ×3, tool_b ×1`.
- **Full command menu**: 12 commands registered via `setMyCommands` (shown as hints in Telegram).
- **Startup drain**: Stale updates discarded on bot startup.
- **Reliable `/stop` and `/restart`**: Admin-only, kill process group via PID file / pm2.

