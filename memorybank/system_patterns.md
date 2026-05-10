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
- **Self-Modification**: Full toolchain — `read_code` (paginated), `edit_code` (fuzzy multi-line), `patch` (V4A atomic multi-file), `write_file` (path-safe + syntax-validated), `bash` (hardened, timeout), `custom_tool_manager` (validated).
- **Hybrid Bash+Python Pattern**: Bash wrappers marshal `TOOL_*` env vars → JSON → pipe to `tools/_lib/cli.py` Python dispatcher. Keeps Bash thin and Python unit-testable.
- **Native Gemini Support**: Uses Google AI Studio's native REST API for tool calling and streaming.
- **Expanded SENSITIVE_TOOLS**: `bash`, `process`, `write_file`, `edit_code`, `patch`, `delete_file`, `custom_tool_manager`, `skill_manager` all require explicit access control.

## Self-Modification Subsystem (as of 2026-05-10)
```
tools/
  _lib/
    cli.py           # Dispatcher: edit | patch | write | read commands
    fuzzy_match.py   # 9-strategy chain fuzzy replace
    patch_parser.py  # V4A parse → validate → apply
    path_safety.py   # Root confinement + sensitive path blocklist
    file_backend.py  # FileOps: read/write/syntax-validate
  edit_code.sh       # Single-location fuzzy edit → unified diff
  patch.sh           # Multi-file V4A atomic patch
  write_file.sh      # New-file creation with path safety
  read_code.sh       # Paginated read with line numbers
  bash.sh            # Hardened command executor
  custom_tool_manager.sh  # Validated tool registration
```

## Future Directions
- **Skills System**: Shifting from hardcoded tools to dynamic skill loading (Hermes style).
- **Proactive Memory**: Using a solution writer to persist lessons across sessions.