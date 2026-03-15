"""
MAGI × Monju Adapter
MAGI deliberation result JSON → YAML task format conversion.

Equivalent to magi_to_tasks.py — converts consensus_plan items from a
MAGI deliberate/walkthrough result into queue-compatible task YAML entries.
"""

import json
from pathlib import Path
from datetime import datetime, timezone, timedelta

from core.utils import _jaccard_similarity


JST = timezone(timedelta(hours=9))


def magi_to_tasks(
    result: dict,
    article_id: str = "",
    output_dir: str | None = None,
) -> list[dict]:
    """Convert MAGI deliberation result to a list of task dicts.

    Args:
        result: MAGI output dict (from run_magi / run_deliberate)
        article_id: source article identifier (used in task IDs)
        output_dir: if set, write individual YAML files to this directory

    Returns:
        List of task dicts compatible with the queue YAML format.
    """
    tasks = []
    now = datetime.now(JST).isoformat()

    # Collect consensus_plan items from all units
    all_plans = []
    phase2 = result.get("phase2", {})
    for unit_name, unit_result in phase2.items():
        for item in unit_result.get("consensus_plan", []):
            all_plans.append({
                "from_unit": unit_name,
                "priority": item.get("priority", 99),
                "action": item.get("action", ""),
                "impact": item.get("expected_impact", ""),
            })

    # Fallback: top-level consensus_plan (some output formats)
    if not all_plans:
        for item in result.get("consensus_plan", []):
            all_plans.append({
                "from_unit": "MAGI",
                "priority": item.get("priority", 99),
                "action": item.get("action", ""),
                "impact": item.get("expected_impact", ""),
            })

    # Deduplicate by action text (Jaccard similarity)
    seen = []
    unique_plans = []
    for plan in sorted(all_plans, key=lambda x: x["priority"]):
        action = plan["action"]
        is_dup = any(_jaccard_similarity(action, s) >= 0.7 for s in seen)
        if not is_dup:
            seen.append(action)
            unique_plans.append(plan)

    # Build task dicts
    for i, plan in enumerate(unique_plans, 1):
        task_id = f"magi_{article_id}_{i:02d}" if article_id else f"magi_task_{i:02d}"
        task = {
            "task_id": task_id,
            "created": now,
            "source": "magi_deliberation",
            "article_id": article_id,
            "priority": plan["priority"],
            "from_unit": plan["from_unit"],
            "action": plan["action"],
            "expected_impact": plan["impact"],
            "status": "pending",
        }
        tasks.append(task)

    if output_dir:
        out_path = Path(output_dir)
        out_path.mkdir(parents=True, exist_ok=True)
        try:
            import yaml
            for task in tasks:
                fname = out_path / f"{task['task_id']}.yaml"
                with open(fname, "w", encoding="utf-8") as f:
                    yaml.dump(task, f, allow_unicode=True, default_flow_style=False)
        except ImportError:
            # yaml not available — write JSON
            for task in tasks:
                fname = out_path / f"{task['task_id']}.json"
                with open(fname, "w", encoding="utf-8") as f:
                    json.dump(task, f, ensure_ascii=False, indent=2)

    return tasks


def load_magi_result(json_path: str) -> dict:
    """Load a MAGI result JSON file."""
    with open(json_path, encoding="utf-8") as f:
        return json.load(f)


# ── CLI ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    import sys

    parser = argparse.ArgumentParser(description="Convert MAGI result JSON to task YAML files")
    parser.add_argument("result_json", help="Path to MAGI result JSON file")
    parser.add_argument("--article-id", default="", help="Article ID for task naming")
    parser.add_argument("--output-dir", default="tasks/", help="Output directory for YAML files")
    parser.add_argument("--dry-run", action="store_true", help="Print tasks without writing files")
    args = parser.parse_args()

    result = load_magi_result(args.result_json)
    tasks = magi_to_tasks(
        result,
        article_id=args.article_id,
        output_dir=None if args.dry_run else args.output_dir,
    )

    print(f"Generated {len(tasks)} tasks:")
    for t in tasks:
        print(f"  P{t['priority']} [{t['from_unit']}] {t['action'][:80]}")

    if not args.dry_run:
        print(f"\nWritten to: {args.output_dir}")
