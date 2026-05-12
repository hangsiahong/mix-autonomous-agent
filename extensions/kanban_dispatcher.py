import os
import time
import subprocess
import json
import logging
from tools.kanban.db import get_db, update_task_status

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger("kanban-dispatcher")

PROJECT_ROOT = os.path.expanduser("~/projects/funs/building/autonomous-agent")
AGENT_RUN_CMD = ["python3", os.path.join(PROJECT_ROOT, "agent.py")]

def get_ready_tasks():
    with get_db() as conn:
        rows = conn.execute("SELECT * FROM tasks WHERE status = 'ready'").fetchall()
        return [dict(row) for row in rows]

def spawn_worker(task):
    task_id = task['id']
    assignee = task['assignee']
    skills = json.loads(task['skills'] or "[]")
    
    logger.info(f"Spawning worker for task {task_id} (assignee: {assignee})")
    
    # Mark as running immediately to prevent double-spawning
    update_task_status(task_id, "running")
    
    # Prepare environment for the worker
    env = os.environ.copy()
    env["AMA_KANBAN_TASK_ID"] = task_id
    env["AMA_KANBAN_MODE"] = "worker"
    
    # Create a specialized prompt for the worker
    worker_prompt = f"""
[KANBAN WORKER MODE]
You are working on Task ID: {task_id}
Title: {task['title']}
Description: {task['body']}

Your goal is to complete this specific task. 
Use 'kanban_show' to see full context if needed.
When finished, you MUST use 'kanban_complete' to report your results and hand off work.
If you are stuck and need human input, use 'kanban_block'.
"""
    
    # Run the agent in a non-blocking way (background process)
    # Note: In a real multi-agent system, this might involve calling a specific skill or endpoint.
    # For AMA, we'll simulate a self-spawn or a handoff via the current agent logic.
    
    try:
        # We use 'nohup' or similar to ensure it survives if dispatcher restarts
        # This is a simplified version; real dispatcher would track PIDs
        cmd = AGENT_RUN_CMD + ["--task-id", task_id, "--prompt-override", worker_prompt]
        if skills:
            for s in skills:
                cmd.extend(["--skill", s])
        
        subprocess.Popen(
            cmd,
            env=env,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        logger.info(f"Worker process started for {task_id}")
        
    except Exception as e:
        logger.error(f"Failed to spawn worker for {task_id}: {e}")
        update_task_status(task_id, "blocked") # Block it so it doesn't loop fail

def run_dispatcher():
    logger.info("Kanban Dispatcher started.")
    while True:
        try:
            ready_tasks = get_ready_tasks()
            for task in ready_tasks:
                spawn_worker(task)
            
            time.sleep(30)
        except KeyboardInterrupt:
            break
        except Exception as e:
            logger.error(f"Dispatcher error: {e}")
            time.sleep(10)

if __name__ == "__main__":
    run_dispatcher()
