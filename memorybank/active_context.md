# Active Context

## Current Status
- **Modular Restructuring Complete**: `core/telegram/` and `core/mix/` are now modular with `init.sh` loaders.
- **Pluggable UI**: `core/ui.sh` provides a unified `ui_msg` and `ui_error` that detects Telegram context.
- **Extensions System**: `extensions/` directory added for agent-written harness expansions without core conflict.
- **Slash Commands**: `/start`, `/help`, `/reset`, `/status`, `/login` implemented in `core/telegram/router.sh`.
- **Copilot Integration**: `copilot_login` updated to support Telegram UI via `ui_msg`.

## Recent Changes
- Moved Telegram logic from `core/telegram.sh` to `core/telegram/` (api, polling, router, formatter).
- Created `core/mix/init.sh` to centralize LLM engine loading.
- Added `core/ui.sh` for multi-interface support.
- Configured `bot.sh` to load core modules and extensions.

## Immediate Tasks
- [ ] Verify `copilot` provider auth flow in live Telegram.
- [ ] Test `google` provider with `gemini-2.0-flash`.
- [ ] Finalize `bot.sh` polling reliability.
- [ ] Document how to add extensions.
