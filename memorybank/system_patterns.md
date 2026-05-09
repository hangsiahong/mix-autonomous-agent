# Architecture: AMA (Autonomous Minimalist Agent)

## Overview
AMA is a Bash-based autonomous agent that uses modular components inspired by the Mix Coding Agent and streaming interaction patterns from OpenClaw.

## Core Components
- **`bot.sh`**: The long-polling Telegram entry point.
- **`core/mix/`**:
    - `11_history.sh`: Manages conversation state and Gemini native mapping.
    - `18_streaming_api_call.sh`: Uses a Python shim to stream Gemini SSE tokens and update Telegram messages in real-time.
    - `24_agent_loop.sh`: Multi-turn tool execution loop.
- **`tools/`**: Simple bash scripts that receive arguments via `TOOL_` environment variables.

## Key Features
- **Real-time Streaming**: Edits the initial "Thinking..." message in Telegram as tokens arrive.
- **Self-Modification**: Has access to `edit_code`, `read_code`, and `list_files` to alter its own logic.
- **Native Gemini Support**: Uses Google AI Studio's native REST API for tool calling and streaming.

## Future Directions
- **Skills System**: Shifting from hardcoded tools to dynamic skill loading (Hermes style).
- **Proactive Memory**: Using a solution writer to persist lessons across sessions.