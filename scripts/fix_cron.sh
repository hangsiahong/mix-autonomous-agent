#!/bin/bash
# fix_cron.sh — re-install the cron entry that fires due scheduled tasks every
# minute. Safe to re-run; replaces any prior entry pointing at this repo's
# extensions/cron/run.sh.
#
# Why this exists: setup_cron.sh uses $(pwd) so it only works when invoked from
# the repo root. fix_cron.sh hard-pins the absolute path so it works from
# anywhere (and from a recovery agent that may not be in the right cwd).
#
# Earlier version of this script tried to OVERWRITE extensions/cron/run.sh
# via a single-quoted heredoc with \$VAR escapes — but single-quoted heredocs
# don't interpret backslash escapes, so every `\$DIR` was written literally,
# producing a cron script bash couldn't run. The canonical run.sh lives at
# extensions/cron/run.sh; this installer no longer rewrites it.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="${DIR}/extensions/cron/run.sh"
LOG_FILE="${DIR}/brain/state/cron_system.log"

if [[ ! -f "$RUN_SCRIPT" ]]; then
    echo "fix_cron: $RUN_SCRIPT not found" >&2
    exit 1
fi
chmod +x "$RUN_SCRIPT" 2>/dev/null || true
mkdir -p "$(dirname "$LOG_FILE")"

# Install: strip any pre-existing entry pointing at this run.sh, then append a
# fresh one. Cron tick = 1 min; scheduler.sh checks next_run > now so most
# ticks are no-ops.
( crontab -l 2>/dev/null | grep -vF "$RUN_SCRIPT"
  echo "* * * * * $RUN_SCRIPT >> $LOG_FILE 2>&1"
) | crontab -

echo "fix_cron: installed crontab entry"
crontab -l | grep -F "$RUN_SCRIPT"
