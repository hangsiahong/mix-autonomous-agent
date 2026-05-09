# Active Context

## Current Status
- **Self-Learning System Complete**: Vector memory (LanceDB) + Identity (AGENT/SOUL) integrated.
- **Modular SDK & Engine**: Fully restructured with conflict-free growth paths.
- **Streaming UI**: Live Telegram updates via Python SSE shim.

## Recent Changes
- **Long-Term Memory**: Implemented LanceDB-based vector store for conversation archiving and retrieval.
- **Smart Compaction**: History compaction now auto-archives discarded turns to the vector database.
- **Identity Layer**: Created `AGENT.md` (Directives) and `SOUL.md` (Cognitive Strategy).
- **Tool Expansion**: Added `memory_recall` and `memory_remember` tools.
- **Conflict Prevention**: Solidified `tools/custom/` and `extensions/` for autonomous growth.

## Immediate Tasks
- [ ] Verify LanceDB connectivity in the bot's runtime environment.
- [ ] Test `gemini-2.0-flash` tool-calling with the new memory tools.
- [ ] Finalize `bot.sh` reliability and error handling for long-polling.
- [ ] Perform a "Self-Improvement" test: ask the agent to build a simple extension.
