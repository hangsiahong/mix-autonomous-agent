#!/bin/bash
# Tool: delegate
# Delegate a task to a specialized coding sub-agent.
# Automatically picks the best available backend:
#   - Claude Code CLI (claude -p) — if installed
#   - OpenAI Codex CLI (codex exec) — if installed
#   - Self (mini AMA sub-agent) — always available
#
# Inputs:
#   TOOL_goal     — task goal (required). Be specific.
#   TOOL_context  — additional context, file paths, constraints (optional)
#   TOOL_backend  — claude | codex | self | auto (default: auto)
#   TOOL_timeout  — seconds before giving up (default: 300)
#   TOOL_max_turns — max turns for self backend (default: 20)
#   TOOL_workdir  — working directory (default: project root)

AMA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AMA_DIR

python3 "${AMA_DIR}/tools/delegate.py"
