# Active Context

## Current Status
- **Production-ready**: Running under pm2 with auto-restart. All systems stable.
- **24 tools** across 6 toolsets (core, search, memory, meta, inspect, media).
- **Browser automation**: Playwright Chromium headless added (`browser` tool in `search` toolset).
- **Memory system**: Chunked indexing, access tracking, monthly auto-pruning via cron.
- **Containerized**: Dockerfile + pm2.config.js for clean deployment.

## Recent Changes (2026-05-10 — Capabilities & Polish)

### Infrastructure
- **`pm2.config.js`**: Bot now runs under pm2 (`autorestart: true`). Logs to `logs/bot.log`.
- **`Dockerfile`**: Debian slim, installs all deps + Playwright Chromium, runs via `pm2-runtime`.
- **`requirements.txt`**: `requests`, `duckduckgo-search`, `lancedb`, `playwright`.
- **`.env.example`**: Template for all required env vars.
- **`/restart` command**: Admin Telegram command; delegates to `pm2 restart ama-bot`.

### Toolset System
- All 24 tools tagged with `toolset` field in `brain/tools.json`.
- Default toolsets (loaded every turn): `core`, `search`, `memory`, `meta`.
- On-demand: `inspect` (repo_map, sys_info, read_error_log, insights), `media` (image_generate).
- `brain/config.json`: `default_toolsets` field drives filtering in `16_api.sh`.
- Skill `_enabled_toolsets` mechanism for per-topic expansion.

### Browser Automation
- **`tools/_lib/browser.py`**: Playwright Chromium headless. SSRF guard, aria-snapshot text output, interactive element listing.
- **`tools/browser.sh`**: Shell wrapper. Actions: navigate, click, type, scroll, snapshot.
- Registered in `search` toolset — always loaded alongside `web_search` and `fetch_url`.

### Memory Improvements
- **Chunking**: `save_memory` splits texts >400 words into overlapping chunks (50-word overlap). Each chunk gets its own embedding.
- **Access tracking**: `search_memory` stamps `last_accessed` + increments `access_count` on every recall.
- **`saved_at`**: Injected automatically by `memory_remember.sh` at save time.
- **`prune_memory(days=30)`**: Removes entries unused for N days (keeps if recently saved or used >2x).
- **Monthly cron pruning**: `extensions/cron/run.sh` runs `prune 30` once a month via marker file.
- **New CLI modes**: `stats`, `prune [days] [--dry-run]`.

### Skill & Command UX
- `/skill` (no args): lists all skills with [core]/[user] labels.
- `/skills`: alias.
- `/skill <name>`: validates existence before activating; rejects unknown names.
- `/skill off`: clears active skill.
- `skill_manager create`: writes `prompt.md` + `tools.json`.
- `skill_manager list`: shows both `core/skills/` and `brain/skills/`.
- **Telegram command menu**: All 12 commands registered via `tg_set_commands`.

### File Format
- `brain/system_prompt.txt` → `brain/system_prompt.md`.
- All skill prompts use `.md`. Backward-compatible `.txt` fallback in `16_api.sh`.

### System Prompt Additions
- "Toolset System" section (6 toolsets, expansion mechanism).
- "Resilience & Retry Strategy" section (per-tool fallback rules).
- "Browser automation" rule (fetch_url first, then browser).
- Memory hygiene guidance (selective saving, pruning awareness).

## Immediate Next
- [ ] Enhance **Reflection Core** to optimize system prompt from usage insights.
- [ ] **Trajectory Logging** for fine-tuning dataset collection.
- [ ] File watcher extension for cron-triggered summarization tasks.

