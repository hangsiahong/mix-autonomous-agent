# AMA — Autonomous Mix Agent

> A self-evolving Telegram-native AI agent. ~10k lines of Bash + Python. Reads, writes, schedules, learns from itself, runs cheap models without losing quality.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
![Bash](https://img.shields.io/badge/bash-black?logo=gnubash)
![Python](https://img.shields.io/badge/python-3.11+-blue?logo=python)

---

## What it does

- **Talks to you in Telegram.** Long-poll bot, no webhook setup. Streams responses with live tool-call status.
- **Runs 36 tools** out of the box: bash, web search, fetch, file edits, AST edits, code patches, browser automation (Playwright), image generation, scheduler, vector + curated memory, sub-agent delegation, and more. See [`tools/README.md`](tools/README.md).
- **Picks the right skill automatically.** Domain-specific prompts (finance, design, code, ...) get keyword-routed in <1ms before the LLM is even called. See [docs/skills.md](docs/skills.md).
- **Learns from itself.** Async curator reads each session and bakes durable knowledge (API contracts, env quirks, user preferences) into `MEMORY.md` and skill prompts — without your intervention. See [docs/self_improvement.md](docs/self_improvement.md).
- **Schedules autonomous work.** `/schedule add every=12h "summarize transactions"` — fires on cron, can pin to a cheap model to save cost.
- **`/goal <prose>`** — autonomous goal loop. Judge decides DONE/CONTINUE/FAIL each turn. Walks away while the bot works.
- **`/btw <q>`** — ephemeral side-question. Uses session as context, doesn't pollute history, doesn't run tools.
- **Provider-agnostic.** Google Vertex AI (Gemini 3 native + thinking), Anthropic (with prompt caching), Groq, DeepSeek, KConsole, Ollama, GitHub Copilot OAuth, and more. Multi-provider pool with tier-based routing. See [docs/providers.md](docs/providers.md).
- **Production-aware.** 13-class error taxonomy with action-verb dispatch (rotate_pool, switch_model, disable_thinking, ...), background self-healing, audit logs, scheduled state cleanup.

Inspired by [hermes-agent](https://github.com/anysphere/hermes) (autonomy patterns) and [openclaw](https://github.com/openclaw) (plugin patterns).

---

## Quickstart

```bash
git clone https://github.com/hangsiahong/mix-autonomous-agent.git ama
cd ama
bash scripts/setup.sh   # interactive wizard: deps + provider + Telegram + run mode
bash bot.sh             # or: pm2 start pm2.config.js   |   docker compose up -d --build
```

The wizard installs Python deps into `./venv`, prompts for your Telegram bot token + admin ID, walks you through provider setup (Vertex AI / AI Studio / Copilot / KConsole / Anthropic / Ollama / OpenAI-compat), and writes `.env` + `brain/config.json`. Re-runnable any time — old configs are backed up.

Message your bot in Telegram. Send `/help` for commands, `/status` for session info.

Full setup (Docker, pm2, OAuth providers, troubleshooting) → [docs/setup.md](docs/setup.md).

---

## Docs

| Doc | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Turn flow, component map, state files, design choices |
| [docs/setup.md](docs/setup.md) | Detailed install + config + Docker + pm2 + troubleshooting |
| [docs/commands.md](docs/commands.md) | Every `/slash` command, reaction emojis, status-query circuit breaker |
| [docs/providers.md](docs/providers.md) | Per-provider config, provider pool, error taxonomy |
| [docs/skills.md](docs/skills.md) | Auto-router, frontmatter schema, authoring guide |
| [docs/self_improvement.md](docs/self_improvement.md) | Curator, `/goal`, `/btw`, scheduler, self-healing |
| [tools/README.md](tools/README.md) | Tool index (auto-generated from `brain/tools.json`) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to add a tool / skill / provider, code style, commits |

---

## Why this exists

Most agent frameworks bury you in abstractions or force you to use specific models. AMA is the opposite:

- **One Bash process, one Telegram bot, one persistent volume.** Read the source, change a tool, the change is live next turn — no compile step, no plugin registry.
- **The harness matters more than the model.** Good skill prompts + clean tool outputs + reliable error handling let cheap models do work that requires expensive models elsewhere.
- **Self-modification is a feature, not a hack.** The agent edits `MEMORY.md`, USER profile, and skill prompts via its own tools. Each session ends slightly smarter than it started.

If that resonates, see [docs/architecture.md](docs/architecture.md) for the full mental model.

---

## License

Apache 2.0 — see [LICENSE](LICENSE). Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
