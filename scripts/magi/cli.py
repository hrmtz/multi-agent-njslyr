#!/usr/bin/env python3
"""
MAGI System — CLI entrypoint.

Usage:
    python3 scripts/magi/cli.py "Should we deploy this feature?"
    python3 scripts/magi/cli.py --mode deliberate --session article_review --file article.html
    python3 scripts/magi/cli.py --mode judge --session strategy "Should we migrate to headless CMS?"
    python3 scripts/magi/cli.py --mode walkthrough --file article.html --skip MELCHIOR
    python3 scripts/magi/cli.py --profile deep --output-dir results/custom/ --json --file content.html
"""

import argparse
import os
import sys
from pathlib import Path

# Ensure scripts/magi/ is in sys.path for core.* imports
_MAGI_DIR = Path(__file__).resolve().parent
if str(_MAGI_DIR) not in sys.path:
    sys.path.insert(0, str(_MAGI_DIR))

# Load API keys before imports that might need them
_env_file = _MAGI_DIR.parent.parent / "config" / "api_keys.env"
if _env_file.exists():
    for line in _env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip())

from core.orchestrator import run_magi
from core.prompts import SESSION_TYPES


def main():
    parser = argparse.ArgumentParser(
        description="MAGI System — Three-way AI Deliberation",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 magi.py "Should we deploy this feature?"
  python3 magi.py --mode deliberate --session article_review --file article.html
  python3 magi.py --mode judge --skip MELCHIOR --json "Is this strategy sound?"
  python3 magi.py --profile deep --output-dir results/sprint42/ --file content.html
        """,
    )
    parser.add_argument("question", nargs="?", default="", help="Question or topic to deliberate")
    parser.add_argument(
        "--mode", "-m", default="deliberate",
        choices=["judge", "deliberate", "walkthrough"],
        help="Mode: judge (vote), deliberate (improve), or walkthrough (dropout sim) (default: deliberate)",
    )
    parser.add_argument(
        "--session", "-s", default="general",
        choices=list(SESSION_TYPES.keys()),
        help="Session type (default: general)",
    )
    parser.add_argument("--file", "-f", type=str, help="Read question/content from file")
    parser.add_argument("--stdin", action="store_true", help="Read from stdin")
    parser.add_argument("--json", action="store_true", help="Output full results as JSON")
    parser.add_argument(
        "--skip", type=str,
        help="Skip unit(s) comma-separated: MELCHIOR,BALTHASAR,CASPER",
    )
    parser.add_argument(
        "--context", "-c", type=str, default="",
        help="Additional context (e.g. target audience, article goals)",
    )
    parser.add_argument(
        "--profile",
        choices=["fast", "balanced", "deep"],
        default="balanced",
        help="Execution profile: fast | balanced | deep (default: balanced; Phase1 stub — no behavior change yet)",
    )
    parser.add_argument(
        "--output-dir", type=str, default="results/",
        help="Directory to save result JSON files (default: results/)",
    )
    args = parser.parse_args()

    question = args.question
    if args.file:
        question = Path(args.file).read_text(encoding="utf-8")
    elif args.stdin:
        question = sys.stdin.read()

    if not question.strip():
        parser.error("No question provided. Use positional arg, --file, or --stdin.")

    if args.context:
        question = f"[Context: {args.context}]\n\n{question}"

    skip = [s.strip().upper() for s in args.skip.split(",")] if args.skip else []

    run_magi(
        question,
        session=args.session,
        mode=args.mode,
        skip=skip,
        output_json=args.json,
        context=args.context,
        output_dir=args.output_dir,
        profile=args.profile,
    )


if __name__ == "__main__":
    main()
