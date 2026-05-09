# AMA Killer Features & Capabilities

This document tracks unique features implemented in AMA to prevent duplication and provide a capability map for the agent.

## 🧠 Cognitive Layer
- **Reflection Core (`core/mix/26_reflection.sh`)**: Background self-improvement loop that runs after every turn. Reviews actions, fixes bugs, and proactively creates skills.
- **Episodic/Semantic Memory**: Integrated **LanceDB** via `tools/memory_helper.py`. Automatically archives compressed history into vector space for future recall.
- **Contextual Identity**: Multi-identity support via system prompt overrides. Allows the agent to switch into "Reflector", "Researcher", or "Coder" modes without context pollution.

## 🛠 Skills & Autonomy
- **Skill Manager (`tools/custom_tool_manager.sh`)**: Agent can autonomously create, test, and register new Bash tools in `tools/custom/`.
- **Dynamic Access Control**: Whitelist and Home Chat management via `tools/access_control.sh`. Managed through natural language rather than static commands.
- **Web Research**: Dual-mode research engine using `web_search` (DuckDuckGo) and `fetch_url` (Jina/Markdown).

## 🔌 Engine & Infrastructure
- **Vertex AI Optimization**: Native support for Google Vertex AI Gemini models and `text-embedding-004`. Handles gcloud OAuth tokens and API keys interchangeably.
- **Auto-Labeling**: Conversations are automatically summarized into titles using background async tasks (`core/mix/28_summary.sh`).
- **Minimalist Scaling**: Pure Bash harness with Python only for heavy lifting (JSON/Vector/Requests).

## 🛡 Stability & Safety
- **Self-Healing Edit**: `tools/edit_code.sh` automatically validates Bash syntax (`bash -n`) after every edit. If the edit breaks the script, it reverts to a backup and reports the error, preventing the agent from "bricking" itself.
- **History Compaction**: Prevents context overflow by moving old turns to vector memory.
- **Tool Guardrails**: Custom tool registration requires valid JSON schema.
- **ID Injection**: Every user turn is injected with `chat_id` and `user_id` context for reliable access control.
