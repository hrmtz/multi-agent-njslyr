#!/usr/bin/env python3
"""
MAGI System — Backward-compatible entry point.

This file is a thin wrapper around cli.py.
All logic lives in core/ — see cli.py for the full CLI interface.

Usage (unchanged):
    python3 scripts/magi/magi.py "Should we deploy this feature?"
    python3 scripts/magi/magi.py --mode deliberate --session article_review --file article.html
    python3 scripts/magi/magi.py --mode judge --session strategy "Should we migrate to headless CMS?"
    python3 scripts/magi/magi.py --skip MELCHIOR --json --file article.html
"""

import sys
from pathlib import Path

# Ensure scripts/magi/ is in sys.path
_MAGI_DIR = Path(__file__).resolve().parent
if str(_MAGI_DIR) not in sys.path:
    sys.path.insert(0, str(_MAGI_DIR))

from cli import main

if __name__ == "__main__":
    main()
