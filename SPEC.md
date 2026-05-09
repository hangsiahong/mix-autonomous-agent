# SPEC - Autonomous Minimalist Agent (AMA)

## §G Goal
Build a self-improving, autonomous agent in Bash that communicates via Telegram. Minimalist, extensible, and capable of modifying its own harness.

## §C Constraints
- **Language:** Pure Bash for harness/logic where possible.
- **Interface:** Telegram Bot API (Long Polling).
- **LLM:** Gemini or OpenRouter (API).
- **Environment:** Linux/Standard tools.
- **Safety:** Agent can only write to its own project directory.

## §I Interfaces
- `bot.sh`: Main entry point, manages Telegram polling.
- `core/brain.sh`: Handles LLM request/response parsing.
- `core/executor.sh`: Runs tool calls (scripts in `tools/`).
- `tools/`: Directory of bash scripts the agent can call.

## §V Invariants
- Every message from Telegram must trigger the loop.
- Tool outputs must be fed back to the LLM.
- State must be saved after every cycle.

## §T Tasks
- [x] Initialize project structure.
- [x] Implement `core/telegram.sh` for polling/sending.
- [x] Implement `core/llm.sh` (Provider adapter).
- [x] Create `core/main.sh` (The Loop).
- [x] Implement `tools/edit_code.sh` (Self-modification tool).
- [x] Implement `tools/read_code.sh`.
- [x] Implement `bot.sh` entry point.

## §B Bugs
- N/A
