"""
MAGI System — Persona & Session Prompts (backward-compatible re-export).

All logic lives in core/prompts.py.
"""

try:
    from core.prompts import (  # noqa: F401
        PERSONAS,
        SESSION_TYPES,
        JUDGE_OUTPUT_FORMAT,
        JUDGE_CROSS_REVIEW,
        DELIBERATE_OUTPUT_FORMAT,
        DELIBERATE_CROSS_REVIEW,
        WALKTHROUGH_OUTPUT_FORMAT,
        WALKTHROUGH_CROSS_REVIEW,
        get_walkthrough_personas,
        OUTPUT_FORMAT_INSTRUCTION,
        CROSS_REVIEW_INSTRUCTION,
    )
except ImportError as e:
    raise ImportError(
        "core/prompts.py not found. Run from scripts/magi/ directory "
        "or set PYTHONPATH to include it."
    ) from e

__all__ = [
    "PERSONAS",
    "SESSION_TYPES",
    "JUDGE_OUTPUT_FORMAT",
    "JUDGE_CROSS_REVIEW",
    "DELIBERATE_OUTPUT_FORMAT",
    "DELIBERATE_CROSS_REVIEW",
    "WALKTHROUGH_OUTPUT_FORMAT",
    "WALKTHROUGH_CROSS_REVIEW",
    "get_walkthrough_personas",
    "OUTPUT_FORMAT_INSTRUCTION",
    "CROSS_REVIEW_INSTRUCTION",
]
