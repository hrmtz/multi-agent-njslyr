"""
MAGI System — Input/output JSON schema definitions + validation.

Mode-specific required fields and fallback defaults.
Session-specific overrides are loaded from SESSION_CONFIGS (sessions/*.yaml).
"""

import sys

from .prompts import SESSION_CONFIGS

_REQUIRED_FIELDS: dict[str, list[str]] = {
    "judge": ["vote", "opinion"],
    "deliberate": ["score", "issues"],
    "walkthrough": ["sections"],
}

_FIELD_DEFAULTS: dict[str, object] = {
    "vote": "abstain",
    "opinion": "",
    "score": 0,
    "issues": [],
    "sections": [],
    "reasoning": "",
    "conditions": "",
}


def _get_required_fields(mode: str, session: "str | None" = None) -> list[str]:
    """Return required fields for a mode, with session-specific override."""
    if session and session in SESSION_CONFIGS:
        session_rf = SESSION_CONFIGS[session].get("required_fields", {})
        if mode in session_rf:
            return session_rf[mode]
    return _REQUIRED_FIELDS.get(mode, [])


def _validate_schema(
    result: dict, mode: str, session: "str | None" = None
) -> dict:
    """Fill missing required fields, normalize types, and emit warnings.

    Args:
        result: parsed JSON response from a MAGI unit.
        mode: deliberation mode (judge/deliberate/walkthrough).
        session: optional session id for session-specific required fields.
    """
    for field in _get_required_fields(mode, session):
        if field not in result:
            print(
                f"[MAGI WARNING] Schema: missing field '{field}' for mode '{mode}'",
                file=sys.stderr,
            )
            result[field] = _FIELD_DEFAULTS.get(field, "")

    # Type normalization: score → int
    if "score" in result:
        try:
            result["score"] = int(result["score"])
        except (TypeError, ValueError):
            result["score"] = 0

    # Type normalization: issues → list[dict]
    if "issues" in result:
        if not isinstance(result["issues"], list):
            result["issues"] = []
        else:
            normalized = []
            for issue in result["issues"]:
                if isinstance(issue, dict):
                    normalized.append(issue)
                elif isinstance(issue, str):
                    normalized.append({
                        "severity": "medium",
                        "location": "",
                        "problem": issue,
                        "suggestion": "",
                    })
            result["issues"] = normalized

    return result
