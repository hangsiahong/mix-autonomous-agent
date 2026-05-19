#!/bin/bash
# tools/skill_install.sh — Install an external skill from a git repo in one shot.
# Usage: TOOL_skill=<name> TOOL_repo=<git_url> [TOOL_toolsets="space sep list"] bash tools/skill_install.sh
#
# What it does (replaces 5-6 agent tool calls with 1):
#   1. git clone <repo> into skills/<name>/
#   2. Reads SKILL.md (or README.md) to auto-generate a concise prompt
#   3. Creates brain/skills/<name>/prompt.md and tools.json
#   4. Reports success

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "${_TOOLS_DIR}/.." && pwd)"

skill="${TOOL_skill:-}"
repo="${TOOL_repo:-}"
toolsets="${TOOL_toolsets:-}"

if [[ -z "$skill" || -z "$repo" ]]; then
    echo "Error: 'skill' (name) and 'repo' (git URL) are required."
    exit 1
fi

# Validate repo URL — only allow https:// git repos (no file:// or ssh with arbitrary hosts)
if [[ ! "$repo" =~ ^https://[a-zA-Z0-9._/-]+\.git$ ]] && [[ ! "$repo" =~ ^https://github\.com/ ]] && [[ ! "$repo" =~ ^https://gitlab\.com/ ]] && [[ ! "$repo" =~ ^https://bitbucket\.org/ ]]; then
    # Still allow plain https URLs even without .git suffix (common for GitHub)
    if [[ ! "$repo" =~ ^https:// ]]; then
        echo "Error: Only https:// git URLs are allowed."
        exit 1
    fi
fi

clone_dir="${_ROOT_DIR}/skills/${skill}"
skill_dir="${_ROOT_DIR}/brain/skills/${skill}"

# Step 1: Clone (shallow)
if [[ -d "$clone_dir/.git" ]]; then
    echo "Repo already cloned at skills/${skill}/ — pulling latest..."
    git -C "$clone_dir" pull --ff-only --quiet 2>&1 | tail -3
else
    echo "Cloning ${repo} → skills/${skill}/ ..."
    git clone --depth=1 --quiet "$repo" "$clone_dir" 2>&1
    if [[ $? -ne 0 ]]; then
        echo "Error: git clone failed."
        exit 1
    fi
fi

# Step 2: Extract prompt from SKILL.md or README.md
skill_md=""
for candidate in "${clone_dir}/SKILL.md" "${clone_dir}/skill.md" "${clone_dir}/README.md"; do
    if [[ -f "$candidate" ]]; then
        skill_md="$candidate"
        break
    fi
done

prompt=""
if [[ -n "$skill_md" ]]; then
    # Take first 120 lines — enough for a good summary while staying concise
    prompt=$(head -120 "$skill_md")
fi

if [[ -z "$prompt" ]]; then
    prompt="# ${skill} skill\nInstalled from: ${repo}\n"
fi

# Step 3: Write brain/skills/<name>/
mkdir -p "$skill_dir"
printf '%s' "$prompt" > "${skill_dir}/prompt.md"

if [[ -n "$toolsets" ]]; then
    TS="$toolsets" python3 -c "
import json, os
ts = os.environ['TS'].split()
print(json.dumps([{'_enabled_toolsets': ts}], indent=2))
" > "${skill_dir}/tools.json"
else
    echo "[]" > "${skill_dir}/tools.json"
fi

echo "✅ Skill '${skill}' installed."
echo "   Clone  : skills/${skill}/"
echo "   Config : brain/skills/${skill}/"
echo "   Activate: /skill ${skill} in Telegram (or ask me to bind it to a topic)"
