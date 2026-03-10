"""
MAGI System — Model API Callers (backward-compatible re-export).

All logic lives in core/models.py.  This file re-exports public API only.
Internal utilities (_extract_json etc.) should be imported from core directly.
"""

try:
    from core.models import (  # noqa: F401
        MODEL_CONFIG,
        MODEL_CALLERS,
        get_model_label,
        call_claude,
        call_openai,
        call_gemini,
        call_all_parallel,
    )
except ImportError as e:
    raise ImportError(
        "core/models.py not found. Run from scripts/magi/ directory "
        "or set PYTHONPATH to include it."
    ) from e

__all__ = [
    "MODEL_CONFIG",
    "MODEL_CALLERS",
    "get_model_label",
    "call_claude",
    "call_openai",
    "call_gemini",
    "call_all_parallel",
]
