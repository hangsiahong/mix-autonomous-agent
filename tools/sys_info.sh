#!/bin/bash
# tools/sys_info.sh - Get system state (disk, cpu, memory, time)

echo "--- System State ---"
echo "Time: $(date)"
echo "Uptime: $(uptime -p)"
echo "Memory: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
echo "Disk: $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
echo "Load: $(cat /proc/loadavg | awk '{print $1 ", " $2 ", " $3}')"
echo "--------------------"
