#!/bin/bash
# extensions/cron/init.sh

# Run background cron every 5 minutes
(
    while true; do
        bash "${DIR}/extensions/cron/run.sh" > /tmp/ama_cron.log 2>&1
        sleep 300
    done
) &
