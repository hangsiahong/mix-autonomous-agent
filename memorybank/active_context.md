# Active Context

## Current Status
- **Self-Learning System Complete**: Vector memory (LanceDB) + Identity (AGENT/SOUL) integrated.
- **Modular SDK & Engine**: Fully restructured with conflict-free growth paths.
- **Streaming UI**: Live Telegram updates via Python SSE shim.
- **Professional Self-Modification Subsystem**: Ported Hermes-agent patterns (fuzzy match, V4A patch, path safety) into the AMA Bash harness. All 19 end-to-end tests pass (2026-05-10).

## Recent Changes (2026-05-10 — Harness Professionalization)
- **`tools/_lib/` Python core**: `fuzzy_match.py` (9-strategy chain), `patch_parser.py` (V4A two-phase validate→apply), `path_safety.py`, `file_backend.py`, `cli.py` dispatcher.
- **`edit_code`**: Full multi-line fuzzy edits, unified diff output, syntax gate (bash/python/json), auto-revert on failure.
- **`patch`** (new tool): V4A multi-file/multi-hunk atomic patches — validates ALL hunks before touching disk.
- **`write_file`**: Path safety + syntax validation on overwrite.
- **`read_code`**: Pagination (offset/limit), line numbers, large-file refusal (>5 MB).
- **`bash`**: Comprehensive danger-pattern blocklist (exfil, reverse shell, credential reads, destructive ops), invisible-Unicode rejection, configurable timeout.
- **`custom_tool_manager`**: Name regex, `bash -n` syntax gate, danger-pattern scan, refuses to shadow built-ins.
- **Harness bug fixed**: `local args="$args_json"` in `13_tool_execution.sh`.
- **`SENSITIVE_TOOLS`** expanded: bash, patch, write_file, edit_code, custom_tool_manager, skill_manager.
- **`brain/tools.json`** updated: 21 tools, new `patch` schema, `edit_code` old_string/new_string/replace_all schema, `bash` timeout param.
- **`brain/system_prompt.txt`**: Added "File Editing — Choose the Right Tool" section.

## Earlier Changes
- **Smart History Compression**: Implemented LLM-based summarization of middle turns to preserve context.
- **Robustness Layer**: Added API error classification, retries, and tool loop guardrails.
- **Observability**: Implemented usage tracking (tokens/tools) and the `insights` command.
- **Repo Mapping**: Added global project awareness via `repo_map` tool.

## Immediate Tasks
- [x] Implement Telegram topic isolation, skill binding, and automated testing.
- [x] Add Subdirectory Context Discovery and Permission Management.
- [x] Support Gemini 3 thinking/reasoning levels.
- [x] Professionalize self-modification subsystem (multi-line edit, V4A patch, hardened bash, safety layer).
- [ ] Implement **Curator** background task for skill maintenance and state cleanup.
- [ ] Add **Trajectory Logging** for fine-tuning/debugging dataset collection.
- [ ] Implement **Rate Limit Tracker** to handle multi-provider quota management.
- [ ] Enhance **Reflection Core** to proactively optimize the system prompt based on usage insights.
