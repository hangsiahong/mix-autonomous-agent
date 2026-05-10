# AMA Killer Features & Capabilities

This document tracks unique features implemented in AMA to prevent duplication and provide a capability map for the agent.

## 🧠 Cognitive Layer
- **Reflection Core (`core/mix/26_reflection.sh`)**: Background self-improvement loop that runs after every turn. Reviews actions, fixes bugs, and proactively creates skills.
- **Episodic/Semantic Memory**: Integrated **LanceDB** via `tools/memory_helper.py`. Automatically archives compressed history into vector space for future recall.
- **Contextual Identity**: Multi-identity support via system prompt overrides. Allows the agent to switch into "Reflector", "Researcher", or "Coder" modes without context pollution.

## 🛠 Skills & Autonomy
- **Skill Manager (`tools/custom_tool_manager.sh`)**: Agent can autonomously create, test, and register new Bash tools in `tools/custom/`.
- **Dynamic Access Control**: Whitelist and Home Chat management via `core/config.sh`. Managed through natural language rather than static commands.
- **Permission Layer (`core/access_control.sh`)**: Detects sensitive tools (`edit_code`, `bash`) and checks against a session-aware permission store.
- **Web Research**: Dual-mode research engine using `web_search` (DuckDuckGo) and `fetch_url` (Jina/Markdown).

## 🔌 Engine & Infrastructure
- **Reasoning Stream Capture**: Capture and wrap Gemini 3 `thought` fields into `<think>` tags for internal processing while scrubbing them from Telegram UI.
- **Multi-Topic Isolation**: Full support for Telegram Forum Topics (threads) with isolated history, titles, and topic-bound skills.
- **Vertex AI Optimization**: Native support for Google Vertex AI Gemini models and `text-embedding-004`. Handles gcloud OAuth tokens and API keys interchangeably.
- **Auto-Labeling**: Conversations are automatically summarized into titles using background async tasks (`core/mix/28_summary.sh`).
- **Minimalist Scaling**: Pure Bash harness with Python only for heavy lifting (JSON/Vector/Requests).

## 🛡 Stability & Safety
- **Subdirectory Context Discovery**: `read_code` and `list_files` automatically inject `README.md` or `HINTS.md` from the target directory up to 3 levels deep.
- **Multi-Line Fuzzy Edit (`tools/edit_code.sh`)**: 9-strategy fuzzy matcher (exact → ws_normalized → indent_flexible → escape_normalized → unicode_normalized → context_aware…). Returns unified diff. Auto-rejects on syntax errors (bash/python/json), reverts on failure. Multi-line, multi-strategy. Backed by `tools/_lib/fuzzy_match.py`.
- **V4A Atomic Patch (`tools/patch.sh`)**: Multi-file/multi-hunk patches — Phase 1 validates all hunks in memory, Phase 2 applies atomically. Safe for coordinated cross-file edits. Backed by `tools/_lib/patch_parser.py`.
- **Path Safety Library (`tools/_lib/path_safety.py`)**: Blocks writes outside project root, sensitive system paths (/etc, /boot, /usr, /sys, /proc), home dotfiles (.ssh, .aws, .gnupg, .netrc, .kube/config), and device files (/dev/std*, /dev/tty).
- **Hardened Bash Executor (`tools/bash.sh`)**: Comprehensive danger-pattern blocklist covering credential exfil, reverse shells (/dev/tcp/, nc -e, bash -i >), destructive ops (rm -rf, dd of=/dev/sd*, mkfs, shutdown), invisible Unicode rejection, and configurable timeout (default 30s, max 120s).
- **Validated Custom Tool Manager (`tools/custom_tool_manager.sh`)**: Name regex `^[a-z][a-z0-9_]{1,40}$`, refuses to shadow built-ins, `bash -n` syntax gate, danger-pattern scan before registering.
- **Smart History Compaction**: `core/mix/30_compression.sh` summarizes middle turns to save context while preserving head/tail. Handles OpenAI + Gemini native response formats.
- **Tool Loop Guardrails**: `core/mix/22_process_one_tool_call.sh` detects identical tool calls AND caps same tool at 3 calls/turn with a hard stop message to the LLM.
- **ARG_MAX-safe media handling**: Image base64 passed via env var to `jq` (`B64DATA=... jq -n 'env.B64DATA'`) — avoids kernel argument size limit.
- **Usage Insights**: `tools/insights.sh` tracks tokens and tool usage frequency.
- **Repo Mapping**: `tools/repo_map.sh` provides a recursive tree view of the project structure.
- **ID Injection**: Every user turn is injected with `chat_id` and `user_id` context for reliable access control.

## 💬 Telegram UX (OpenClaw-style)
- **Single-draft message flow**: One Telegram message per user turn, continuously edited — no spam of per-tool status messages.
- **HTML formatting**: All output uses `parse_mode: HTML` with `md_to_tg_html()` in `formatter.sh`. Live streaming also converts to HTML. Supports `<b>`, `<i>`, `<code>`, `<pre><code>`, `<s>`, `<a href>`.
- **Deduped tool footer**: Response ends with `🔧 N tool calls: tool_a ×3, tool_b ×1`.
- **Startup drain**: Stale Telegram updates are discarded on bot startup — prevents replaying buffered commands.
- **Reliable `/stop`**: Kills process group via PID file, not just current subshell.
