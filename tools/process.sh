#!/bin/bash
# Tool: process
# Run commands in the background and manage their lifecycle.
# Actions: run, list, output, kill

action="${TOOL_action}"
command="${TOOL_command:-}"
name="${TOOL_name:-}"

PROC_DIR="brain/state/processes"
mkdir -p "$PROC_DIR"

case "$action" in
    run)
        [[ -z "$command" ]] && { echo "Error: 'command' is required for 'run'."; exit 1; }
        [[ -z "$name" ]] && name="job_$(date +%s | tail -c 5)"

        log_file="$PROC_DIR/${name}.log"
        pid_file="$PROC_DIR/${name}.pid"

        if [[ -f "$pid_file" ]]; then
            old_pid=$(cat "$pid_file")
            if kill -0 "$old_pid" 2>/dev/null; then
                echo "Error: Process '$name' is already running (PID: $old_pid). Kill it first."
                exit 1
            fi
        fi

        bash -c "$command" > "$log_file" 2>&1 &
        bg_pid=$!
        echo "$bg_pid" > "$pid_file"
        echo "Started '$name' (PID: $bg_pid)"
        echo "Tail output with: process(action=output, name=$name)"
        ;;

    list)
        if [[ -z "$(ls "$PROC_DIR"/*.pid 2>/dev/null)" ]]; then
            echo "No tracked background processes."
        else
            for pid_file in "$PROC_DIR"/*.pid; do
                job=$(basename "$pid_file" .pid)
                pid=$(cat "$pid_file")
                if kill -0 "$pid" 2>/dev/null; then
                    status="RUNNING"
                else
                    status="DONE   "
                fi
                log_size=$(wc -c < "$PROC_DIR/${job}.log" 2>/dev/null || echo 0)
                echo "[$status] $job  PID=$pid  log=${log_size}B"
            done
        fi
        ;;

    output)
        [[ -z "$name" ]] && { echo "Error: 'name' is required for 'output'."; exit 1; }
        log_file="$PROC_DIR/${name}.log"
        if [[ -f "$log_file" ]]; then
            echo "=== Last 60 lines of '$name' ==="
            tail -60 "$log_file"
        else
            echo "No log found for '$name'."
        fi
        ;;

    kill)
        [[ -z "$name" ]] && { echo "Error: 'name' is required for 'kill'."; exit 1; }
        pid_file="$PROC_DIR/${name}.pid"
        if [[ -f "$pid_file" ]]; then
            pid=$(cat "$pid_file")
            if kill "$pid" 2>/dev/null; then
                echo "Killed '$name' (PID: $pid)."
            else
                echo "Process '$name' (PID: $pid) was already stopped."
            fi
            rm -f "$pid_file"
        else
            echo "No tracked process named '$name'."
        fi
        ;;

    *)
        echo "Unknown action: '$action'. Valid actions: run, list, output, kill"
        exit 1
        ;;
esac
