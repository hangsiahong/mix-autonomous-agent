# AMA: Autonomous Minimalist Agent

AMA is a self-evolving, autonomous AI agent built entirely in Bash. It uses a minimalist harness that allows it to modify its own code, expand its capabilities, and maintain a long-term memory.

> **Status**: Early Alpha (approx. 10% complete). Core architecture established.

## 🌟 Vision
Build a lean, "living" agent that lives in a shell but communicates via Telegram. AMA isn't just a bot; it's a self-improving entity that builds its own tools and refines its own logic.

## 🏗️ Core Architecture (Current)
- **Modular Bash Engine**: Pluggable provider system (Google, Copilot).
- **Telegram Interface**: Long-polling with real-time streaming (thinking -> output).
- **Long-Term Memory**: LanceDB-powered vector storage with automatic history archiving.
- **Identity & Soul**: Explicitly defined cognitive strategies and directives.
- **Conflict-Free Evolution**: Dedicated `extensions/` and `tools/custom/` directories for autonomous growth.

## 🛠️ Current Capabilities
- [x] Multi-provider LLM support.
- [x] Telegram streaming interactions.
- [x] Self-code modification (Search/Replace).
- [x] Automatic history compaction + vector archiving.
- [x] Persistent knowledge base (Memory Bank).

## 🚀 What's Next
- Live stability testing.
- Proactive "Knowledge Loops" (Agent reflecting on its own code).
- Advanced skill acquisition (Hermes-style).
- Multi-user session management.

---
*Built with minimalism and autonomy in mind.*
