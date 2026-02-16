#!/usr/bin/env python3
"""
YAML Slimming Utility

Removes completed/archived items from YAML queue files to maintain performance.
- For all agents: Archives read: true messages from inbox files
- Archives completed task YAMLs (7+ days old)
- Archives old report YAMLs (7+ days old)
"""

import sys
import yaml
import shutil
from pathlib import Path
from datetime import datetime, timedelta


def load_yaml(filepath):
    """Safely load YAML file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return yaml.safe_load(f) or {}
    except FileNotFoundError:
        return {}
    except yaml.YAMLError as e:
        print(f"Error parsing {filepath}: {e}", file=sys.stderr)
        return {}


def save_yaml(filepath, data):
    """Safely save YAML file."""
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            yaml.dump(data, f, allow_unicode=True, sort_keys=False, default_flow_style=False)
        return True
    except Exception as e:
        print(f"Error writing {filepath}: {e}", file=sys.stderr)
        return False


def get_timestamp():
    """Generate archive filename timestamp."""
    return datetime.now().strftime('%Y%m%d%H%M%S')


def parse_timestamp(ts_str):
    """Parse ISO timestamp string to datetime object."""
    if not ts_str:
        return None
    try:
        # Handle various ISO formats
        for fmt in ['%Y-%m-%dT%H:%M:%S', '%Y-%m-%dT%H:%M:%S%z', '%Y-%m-%d %H:%M:%S']:
            try:
                return datetime.strptime(ts_str.split('+')[0].split('.')[0], fmt)
            except ValueError:
                continue
        return None
    except Exception:
        return None


def is_old_enough(timestamp_str, days=7):
    """Check if timestamp is older than specified days."""
    ts = parse_timestamp(timestamp_str)
    if not ts:
        return False
    cutoff = datetime.now() - timedelta(days=days)
    return ts < cutoff


def slim_tasks(agent_id):
    """Archive completed task YAMLs that are 7+ days old."""
    queue_dir = Path(__file__).resolve().parent.parent / 'queue'
    archive_dir = queue_dir / 'archive' / 'tasks'
    archive_dir.mkdir(parents=True, exist_ok=True)

    tasks_dir = queue_dir / 'tasks'
    if not tasks_dir.exists():
        return True

    archived_count = 0

    # Process yakuza{N}.yaml task files
    for task_file in tasks_dir.glob('yakuza*.yaml'):
        data = load_yaml(task_file)
        if not data or 'task' not in data:
            continue

        task = data['task']
        status = task.get('status', '')
        timestamp = task.get('timestamp', '')

        # Archive if completed AND 7+ days old
        if status == 'completed' and is_old_enough(timestamp, days=7):
            archive_file = archive_dir / f'{task_file.stem}_{get_timestamp()}.yaml'
            try:
                shutil.move(str(task_file), str(archive_file))
                archived_count += 1
                print(f"Archived task: {task_file.name} -> {archive_file.name}", file=sys.stderr)
            except Exception as e:
                print(f"Error archiving {task_file}: {e}", file=sys.stderr)

    if archived_count > 0:
        print(f"Archived {archived_count} completed task(s)", file=sys.stderr)
    return True


def slim_reports():
    """Archive report YAMLs that are 7+ days old."""
    queue_dir = Path(__file__).resolve().parent.parent / 'queue'
    archive_dir = queue_dir / 'archive' / 'reports'
    archive_dir.mkdir(parents=True, exist_ok=True)

    reports_dir = queue_dir / 'reports'
    if not reports_dir.exists():
        return True

    archived_count = 0

    # Process all report YAML files
    for report_file in reports_dir.glob('*.yaml'):
        data = load_yaml(report_file)
        if not data:
            continue

        timestamp = data.get('timestamp', '')

        # Archive if 7+ days old
        if is_old_enough(timestamp, days=7):
            archive_file = archive_dir / f'{report_file.stem}_{get_timestamp()}.yaml'
            try:
                shutil.move(str(report_file), str(archive_file))
                archived_count += 1
                print(f"Archived report: {report_file.name} -> {archive_file.name}", file=sys.stderr)
            except Exception as e:
                print(f"Error archiving {report_file}: {e}", file=sys.stderr)

    if archived_count > 0:
        print(f"Archived {archived_count} report(s)", file=sys.stderr)
    return True


def slim_inbox(agent_id):
    """Archive read: true messages from inbox file."""
    queue_dir = Path(__file__).resolve().parent.parent / 'queue'
    archive_dir = queue_dir / 'archive'
    inbox_file = queue_dir / 'inbox' / f'{agent_id}.yaml'

    if not inbox_file.exists():
        # Inbox doesn't exist yet - that's fine
        return True

    data = load_yaml(inbox_file)
    if not data or 'messages' not in data:
        return True

    messages = data.get('messages', [])
    if not isinstance(messages, list):
        print("Error: messages is not a list", file=sys.stderr)
        return False

    # Separate unread and archived messages
    unread = []
    archived = []

    for msg in messages:
        is_read = msg.get('read', False)
        if is_read:
            archived.append(msg)
        else:
            unread.append(msg)

    # If nothing to archive, return success without writing
    if not archived:
        return True

    # Write archived messages to timestamped file
    archive_timestamp = get_timestamp()
    archive_file = archive_dir / f'inbox_{agent_id}_{archive_timestamp}.yaml'

    archive_data = {'messages': archived}
    if not save_yaml(archive_file, archive_data):
        return False

    # Update main file with unread messages only
    data['messages'] = unread
    if not save_yaml(inbox_file, data):
        print(f"Error: Failed to update {inbox_file}, but archive was created", file=sys.stderr)
        return False

    if archived:
        print(f"Archived {len(archived)} messages from {agent_id} to {archive_file.name}", file=sys.stderr)
    return True


def main():
    """Main entry point."""
    if len(sys.argv) < 2:
        print("Usage: slim_yaml.py <agent_id>", file=sys.stderr)
        sys.exit(1)

    agent_id = sys.argv[1]

    # Ensure archive directories exist
    archive_dir = Path(__file__).resolve().parent.parent / 'queue' / 'archive'
    archive_dir.mkdir(parents=True, exist_ok=True)
    (archive_dir / 'tasks').mkdir(parents=True, exist_ok=True)
    (archive_dir / 'reports').mkdir(parents=True, exist_ok=True)

    # Process inbox
    if not slim_inbox(agent_id):
        sys.exit(1)

    # Process tasks (for yakuza agents only)
    if agent_id.startswith('yakuza'):
        if not slim_tasks(agent_id):
            sys.exit(1)

    # Process reports (run once for any agent)
    if not slim_reports():
        sys.exit(1)

    sys.exit(0)


if __name__ == '__main__':
    main()
