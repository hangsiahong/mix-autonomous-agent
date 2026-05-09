# Active Context

## Current Status
- **Self-Learning System Complete**: Vector memory (LanceDB) + Identity (AGENT/SOUL) integrated.
- **Modular SDK & Engine**: Fully restructured with conflict-free growth paths.
- **Streaming UI**: Live Telegram updates via Python SSE shim.

## Recent Changes
- **Smart History Compression**: Implemented LLM-based summarization of middle turns to preserve context.
- **Robustness Layer**: Added API error classification, retries, and tool loop guardrails.
- **Observability**: Implemented usage tracking (tokens/tools) and the `insights` command.
- **Self-Healing Edits**: `edit_code` now validates Bash syntax and auto-reverts on failure.
- **Repo Mapping**: Added global project awareness via `repo_map` tool.

## Immediate Tasks
- [x] Implement Telegram topic isolation, skill binding, and automated testing.
- [x] Add Subdirectory Context Discovery and Permission Management.
- [x] Support Gemini 3 thinking/reasoning levels.
- [ ] Implement **Curator** background task for skill maintenance and state cleanup.
- [ ] Add **Trajectory Logging** for fine-tuning/debugging dataset collection.
- [ ] Implement **Rate Limit Tracker** to handle multi-provider quota management.
- [ ] Enhance **Reflection Core** to proactively optimize the system prompt based on usage insights.
