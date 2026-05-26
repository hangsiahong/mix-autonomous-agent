
# Fix for "grep: character code point value in \x{} or \o{} is too large"
# This happens in UTF-8 locales when grep processes binary data or large JSON history files.
export LC_ALL=C
# AMA - Autonomous Minimalist Agent
# Based on Mix Coding Agent

# Icons
I_BOT="◆"
I_USER="◇"
I_TOOL="⚒"
I_PLAN="📝"
I_OK="✅"
I_FAIL="❌"
I_WARN="⚠"
I_READ="📖"
I_WRITE="✍"
I_DIR="📁"
I_FIND="🔍"
I_MEMORY="🧠"
I_VERIFY="🩺"
I_MAIL="✉"
I_SEARCH="🔭"

# Date helper (for mac/linux compat)
_mix_date_nano() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    python3 -c 'import time; print(int(time.time() * 1000000000))'
  else
    date +%s%N
  fi
}

# Scratch tempfile helper. Pure-scratch buffers (build → consume → discard)
# go on tmpfs when available; saves disk I/O on the per-turn hot path
# (payload assembly, curl capture, reflection prompt staging, etc.).
#
# DO NOT use this for atomic-rename writes (mktemp "$FILE.XXXXXX" then mv
# to $FILE) — tmpfs is a different filesystem from the bind-mount, so the
# mv becomes copy+unlink and loses rename atomicity. Keep those co-located
# with their target.
_AMA_SCRATCH_DIR=""
_ama_scratch_dir() {
  if [[ -n "$_AMA_SCRATCH_DIR" ]]; then
    printf '%s' "$_AMA_SCRATCH_DIR"; return
  fi
  if [[ -d /dev/shm && -w /dev/shm ]] && mkdir -p /dev/shm/ama 2>/dev/null; then
    _AMA_SCRATCH_DIR=/dev/shm/ama
  else
    _AMA_SCRATCH_DIR="${TMPDIR:-/tmp}"
  fi
  printf '%s' "$_AMA_SCRATCH_DIR"
}

_ama_mktemp() {
  # Drop-in for `mktemp` when the file is pure scratch.
  mktemp --tmpdir="$(_ama_scratch_dir)" "${1:-ama.XXXXXX}"
}

