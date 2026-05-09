# SPEC - Autonomous Mix Agent (AMA)

## §G Goal
Build a self-improving, autonomous agent in Bash that communicates via Telegram. Minimalist, extensible, and capable of modifying its own harness.

## §C Constraints
- **Language:** Pure Bash for harness/logic where possible.
- **Interface:** Telegram Bot API (Long Polling).
- **LLM:** Gemini or OpenRouter (API).
- **Environment:** Linux/Standard tools.
- **Safety:** Agent can only write to its own project directory.

## §I Interfaces
- `bot.sh`: Main entry point, Telegram polling.
- `core/mix/`: Modular engine (History, API, Execution, Loop).
- `core/mix/providers/`: Pluggable API backends (Google, Copilot, etc.).
- `core/telegram.sh`: Bot API wrapper.
- `tools/`: Bash tools.
- `brain/`: System prompt, tool definitions, and conversation state.

## §V Invariants
- Modular Bash structure inspired by Mix Coding Agent.
- Multi-provider support (Pluggable logic).
- Streaming responses to Telegram via message editing (OpenClaw style).
- Self-modification capability.

## §T Tasks
- [x] Initialize project structure.
- [x] Implement `core/telegram.sh` for polling/sending.
- [x] Implement `core/llm.sh` (Provider adapter).
- [x] Create `core/main.sh` (The Loop).
- [x] Implement `tools/edit_code.sh` (Self-modification tool).
- [x] Implement `tools/read_code.sh`.
- [x] Implement `bot.sh` entry point.
- [x] Implement **Reflection Core** for proactive self-awareness.
- [x] Implement **Skill Manager** (`custom_tool_manager`) for autonomous tool creation.
- [x] Integrate **LanceDB** for persistent episodic/semantic memory.
- [x] Implement **Multi-session Isolation** (Telegram Forum Topics).
- [x] Implement **Context Engineering** and **Skill Binding**.
- [ ] Implement **Subdirectory Context Discovery** (Local README/Hint injection).
- [ ] Implement **Permission Manager** (Allow Once/Always/Deny for tools).
- [ ] Implement **Advanced Provider Adapters** (Gemini Thinking/Reasoning support).
- [ ] Implement **Audio/Video processing** via Gemini File API.

## §B Bugs
- N/A
