
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

