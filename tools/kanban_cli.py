#!/usr/bin/env python3
import sys
import argparse
from tools.kanban.db import create_task, list_tasks, update_task_status, init_db

def main():
    parser = argparse.ArgumentParser(description="AMA Kanban CLI")
    subparsers = parser.add_subparsers(dest="command")

    # Add
    add_parser = subparsers.add_parser("add", help="Add a new task")
    add_parser.add_argument("title", help="Task title")
    add_parser.add_argument("--body", "-b", help="Task description")
    add_parser.add_argument("--assignee", "-a", help="Profile to assign")
    add_parser.add_argument("--parents", "-p", nargs="+", help="Parent task IDs")

    # List
    list_parser = subparsers.add_parser("list", help="List tasks")
    list_parser.add_argument("--status", "-s", help="Filter by status")
    list_parser.add_argument("--assignee", "-a", help="Filter by assignee")

    # Status
    status_parser = subparsers.add_parser("status", help="Update task status")
    status_parser.add_argument("id", help="Task ID")
    status_parser.add_argument("status", choices=['todo', 'ready', 'running', 'done', 'blocked'], help="New status")

    args = parser.parse_args()

    if args.command == "add":
        tid = create_task(args.title, body=args.body, assignee=args.assignee, parents=args.parents)
        print(f"Created task: {tid}")
    
    elif args.command == "list":
        tasks = list_tasks(status=args.status, assignee=args.assignee)
        if not tasks:
            print("No tasks found.")
            return
        
        for t in tasks:
            print(f"[{t['id']}] {t['status'].upper():<8} | {t['assignee'] or 'unassigned':<12} | {t['title']}")
    
    elif args.command == "status":
        update_task_status(args.id, args.status)
        print(f"Updated {args.id} to {args.status}")
    
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
