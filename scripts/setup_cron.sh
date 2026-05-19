#!/bin/bash
(crontab -l 2>/dev/null | grep -v "extensions/cron/run.sh"; echo "* * * * * $(pwd)/extensions/cron/run.sh >> $(pwd)/brain/state/cron.log 2>&1") | crontab -
