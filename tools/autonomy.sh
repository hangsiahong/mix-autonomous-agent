#!/bin/bash
# Tool: autonomy
# Action: schedule - Request the agent to continue in background after X seconds.
# Action: stop - Stop background continuation.

action="${TOOL_action}"
chat_id="${TOOL_chat_id}"
thread_id="${TOOL_thread_id}"
delay="${TOOL_delay:-10}"
message="${TOOL_message:-CONTINUE_AUTONOMOUSLY}"

SESSION_ID="tg_${chat_id}"
if [[ -n "$thread_id" && "$thread_id" != "null" ]]; then
    SESSION_ID="tg_${chat_id}_${thread_id}"
fi

case "$action" in
    schedule)
        echo "Scheduling continuation for $SESSION_ID in $delay seconds..."
        # We use a simple sleep + curl in the background to simulate a new message
        (
            sleep "$delay"
            # Send an internal message to the bot's own router if possible
            # But the bot is polling Telegram. So we actually need to send a TG message to the bot?
            # No, we can call run_agent directly if we have the right environment.
            
            # Better: Write a 'job' file that bot.sh picks up.
            mkdir -p brain/jobs
            echo "chat_id=$chat_id" > "brain/jobs/job_${SESSION_ID}.env"
            echo "thread_id=$thread_id" >> "brain/jobs/job_${SESSION_ID}.env"
            echo "text=$message" >> "brain/jobs/job_${SESSION_ID}.env"
            echo "user_id=AMA_INTERNAL" >> "brain/jobs/job_${SESSION_ID}.env"
            echo "session_id=$SESSION_ID" >> "brain/jobs/job_${SESSION_ID}.env"
        ) &
        echo "Continuation scheduled."
        ;;
    stop)
        rm -f "brain/jobs/job_${SESSION_ID}.env"
        echo "Background continuation stopped."
        ;;
    *)
        echo "Unknown action: $action"
        exit 1
        ;;
esac
