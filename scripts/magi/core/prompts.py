"""
MAGI System — Persona & Session Prompts

Personas and walkthrough personas are loaded from YAML at import time:
  - personas/default.yaml          → PERSONAS dict
  - personas/walkthrough_beauty.yaml → walkthrough personas

Sessions are loaded from sessions/*.yaml and merged with built-in defaults.
YAML sessions take precedence for overlapping keys.
"""

import sys
from pathlib import Path

try:
    import yaml as _yaml
    _YAML_AVAILABLE = True
except ImportError:
    _YAML_AVAILABLE = False

_MAGI_DIR = Path(__file__).resolve().parent.parent
_PERSONAS_DIR = _MAGI_DIR / "personas"
_SESSIONS_DIR = _MAGI_DIR / "sessions"
_DEFAULT_PERSONAS_PATH = _PERSONAS_DIR / "default.yaml"
_DEFAULT_WALKTHROUGH_PATH = _PERSONAS_DIR / "walkthrough_beauty.yaml"


# ── Persona Loading ───────────────────────────────────────────────────────────

def load_personas(path: "str | Path") -> dict:
    """Load PERSONAS dict from a YAML file.

    Args:
        path: path to a YAML file with MELCHIOR/BALTHASAR/CASPER keys.

    Returns:
        dict with unit names as keys and persona dicts as values.
    """
    if not _YAML_AVAILABLE:
        raise ImportError("PyYAML is required for persona loading. pip install pyyaml")
    with open(path, encoding="utf-8") as f:
        return _yaml.safe_load(f)


def _load_personas_safe(path: Path) -> dict:
    """Load personas with fallback error reporting."""
    try:
        return load_personas(path)
    except Exception as e:
        print(
            f"[MAGI WARNING] Failed to load personas from {path}: {e}",
            file=sys.stderr,
        )
        return {}


# Load default personas at import time
PERSONAS: dict = _load_personas_safe(_DEFAULT_PERSONAS_PATH)


# ── Session Loading ───────────────────────────────────────────────────────────

def _load_sessions_dir() -> tuple[dict[str, str], dict[str, dict]]:
    """Load session contexts and full configs from sessions/*.yaml files.

    Returns:
        Tuple of (session_types, session_configs) where:
        - session_types maps id -> context string (backward compat)
        - session_configs maps id -> full YAML dict
    """
    if not _YAML_AVAILABLE or not _SESSIONS_DIR.exists():
        return {}, {}
    sessions: dict[str, str] = {}
    configs: dict[str, dict] = {}
    for yaml_file in sorted(_SESSIONS_DIR.glob("*.yaml")):
        try:
            with open(yaml_file, encoding="utf-8") as f:
                data = _yaml.safe_load(f)
            if isinstance(data, dict) and "context" in data:
                sid = data.get("id", yaml_file.stem)
                sessions[sid] = data["context"]
                configs[sid] = data
        except Exception as e:
            print(
                f"[MAGI WARNING] Failed to load session {yaml_file.name}: {e}",
                file=sys.stderr,
            )
    return sessions, configs


# Built-in session types — kept as empty fallback; canonical definitions live in sessions/*.yaml
_BUILTIN_SESSION_TYPES: dict[str, str] = {}

# Merge: YAML sessions override built-ins for the same key
_yaml_sessions, _yaml_configs = _load_sessions_dir()
SESSION_TYPES: dict[str, str] = {**_BUILTIN_SESSION_TYPES, **_yaml_sessions}
SESSION_CONFIGS: dict[str, dict] = {**_yaml_configs}


# ── Mode 1: JUDGE (approve/reject voting) ────────────────────────────────────

JUDGE_OUTPUT_FORMAT = """

You MUST respond in the following JSON format (no markdown fencing, raw JSON only):
{
    "opinion": "Your assessment in 3-5 sentences",
    "reasoning": "Key evidence or logic supporting your position",
    "vote": "approve OR reject OR conditional_approve",
    "conditions": "If vote is conditional_approve, state the conditions. Otherwise empty string."
}
"""

JUDGE_CROSS_REVIEW = """

The other two MAGI units have given their initial opinions. Review them below:

{other_opinions}

Based on their perspectives, you may revise your assessment.
If you are persuaded, change your vote. If not, reaffirm your position with additional reasoning.

Respond in the same JSON format:
{{
    "opinion": "Your revised or reaffirmed assessment",
    "reasoning": "Why you changed or maintained your position",
    "vote": "approve OR reject OR conditional_approve",
    "conditions": "If conditional_approve, state conditions. Otherwise empty string."
}}
"""

# ── Mode 2: DELIBERATE (discussion producing improvements) ───────────────────

DELIBERATE_OUTPUT_FORMAT = """

You are participating in a deliberation to IMPROVE this content, not just judge it.
Analyze from your unique perspective and provide concrete, actionable suggestions.

You MUST respond in the following JSON format (no markdown fencing, raw JSON only):
{
    "score": 75,
    "strengths": ["Strong point 1", "Strong point 2"],
    "issues": [
        {"severity": "high", "location": "冒頭", "problem": "What's wrong", "suggestion": "Concrete fix with example text"},
        {"severity": "medium", "location": "h2第3セクション", "problem": "What's wrong", "suggestion": "Concrete fix"},
        {"severity": "low", "location": "まとめ", "problem": "What's wrong", "suggestion": "Concrete fix"}
    ],
    "rewrite_examples": [
        {"original": "Original sentence or paragraph", "improved": "Your improved version", "reason": "Why this is better"}
    ]
}

Rules:
- score: 0-100 quality rating
- issues: at least 2, max 5. Include severity (high/medium/low), specific location, and a CONCRETE suggestion (not vague advice)
- rewrite_examples: at least 1. Show don't tell — provide actual rewritten text
- strengths: 2-3 things the article does well
"""

DELIBERATE_CROSS_REVIEW = """

The other two MAGI units have analyzed this content. Review their findings below:

{other_opinions}

Now do the following:
1. Identify which suggestions from the others you AGREE with and which you DISAGREE with
2. Add any issues they missed
3. Propose a CONSENSUS improvement plan — the top 3-5 most impactful changes, prioritized
4. 自分自身の初期提案のうち、他の意見を踏まえて「最も捨てるべき脆弱な部分」を1つ必ず挙げること（自己肯定バイアスを排除し、真の合意形成を促進するため）

You MUST respond in the following JSON format (no markdown fencing, raw JSON only):
{{
    "score": 78,
    "agreements": ["I agree with UNIT_NAME's point about X because..."],
    "disagreements": ["I disagree with UNIT_NAME's point about X because..."],
    "missed_issues": ["Additional issue not mentioned: ..."],
    "consensus_plan": [
        {{"priority": 1, "action": "Concrete action to take", "expected_impact": "What this fixes"}},
        {{"priority": 2, "action": "...", "expected_impact": "..."}},
        {{"priority": 3, "action": "...", "expected_impact": "..."}}
    ],
    "best_rewrite": {{"original": "Most impactful sentence to change", "improved": "Consensus best version", "reason": "Why"}},
    "weakest_own_point": "あなた自身の初期提案の中で最も脆弱だった点（他の意見を踏まえて撤回・修正すべき部分）"
}}
"""

# ── Mode 3: WALKTHROUGH (persona-based dropout simulation) ───────────────────

def get_walkthrough_personas(
    target_context: str = "",
    personas_path: "str | Path | None" = None,
) -> dict:
    """Load walkthrough reader personas from YAML.

    Args:
        target_context: article content or context hint. If it contains male
            keywords, returns male personas.
        personas_path: path to a walkthrough YAML file. Defaults to
            personas/walkthrough_beauty.yaml.

    Returns:
        dict with MELCHIOR/BALTHASAR/CASPER as keys, each having
        name/reader_type/reader_prompt fields.
    """
    if not _YAML_AVAILABLE:
        raise ImportError("PyYAML is required. pip install pyyaml")
    path = Path(personas_path) if personas_path else _DEFAULT_WALKTHROUGH_PATH
    with open(path, encoding="utf-8") as f:
        data = _yaml.safe_load(f)
    target_lower = target_context.lower()
    male_kws = data.get("male_keywords", ["男性", "メンズ", "male", "男"])
    gender = "male" if any(kw in target_lower for kw in male_kws) else "female"
    return data[gender]


WALKTHROUGH_OUTPUT_FORMAT = """
You will receive an article split into sections. Read each section as your persona would.

For EACH section, evaluate:
1. Would your persona keep reading or drop off at this point?
2. What is their emotional state? (interested, confused, bored, anxious, excited, skeptical)
3. What are they thinking?

You MUST respond in the following JSON format (no markdown fencing, raw JSON only):
{
    "sections": [
        {
            "section_id": 1,
            "section_preview": "First 30 chars of section...",
            "keep_reading": true,
            "dropout_probability": 15,
            "emotion": "interested",
            "inner_voice": "What they're thinking at this point",
            "pain_points": ["specific issues that push them toward leaving"]
        }
    ],
    "final_dropout_point": "Section number where they most likely leave (0 if they finish)",
    "overall_engagement": 65,
    "killer_issue": "The single biggest reason they would leave this article"
}

Rules:
- dropout_probability: 0-100 for each section (cumulative feel — should generally increase)
- Be brutally honest from your persona's perspective
- inner_voice should be casual, realistic internal monologue in Japanese
- Respond in Japanese
"""

WALKTHROUGH_CROSS_REVIEW = """
The other two reader personas have walked through this article. Compare your experience:

{other_opinions}

Now provide a consensus view:
1. Where do ALL reader types agree the article loses them?
2. What ONE change would retain the most readers?

You MUST respond in the following JSON format (no markdown fencing, raw JSON only):
{{
    "agreements": ["All readers agree that..."],
    "my_unique_perspective": "What only my persona type noticed",
    "consensus_dropout_point": 3,
    "top_fix": {{"location": "Section N", "problem": "Why readers leave", "fix": "Concrete change to retain them"}},
    "retention_score": 60
}}
"""

# ── Legacy aliases for backward compatibility ────────────────────────────────
OUTPUT_FORMAT_INSTRUCTION = JUDGE_OUTPUT_FORMAT
CROSS_REVIEW_INSTRUCTION = JUDGE_CROSS_REVIEW
