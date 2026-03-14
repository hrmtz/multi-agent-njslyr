"""
MAGI System — Shared utilities.

- load_env_file: load key=value env file into os.environ
- _sanitize_error: mask sensitive values in error strings
- _extract_json: parse JSON from LLM response text
- split_into_sections: split HTML article into sections
- _jaccard_similarity: string similarity for deduplication
- _summarize_for_crossreview: summarize unit result for Phase2
"""

import json
import os
import re
import sys
from pathlib import Path

from core.schemas import _validate_schema


def load_env_file(env_path: "str | Path | None" = None) -> None:
    """Load key=value pairs from an env file into os.environ (setdefault)."""
    if env_path is None:
        env_path = Path(__file__).resolve().parent.parent.parent.parent / "config" / "api_keys.env"
    env_path = Path(env_path)
    if not env_path.exists():
        return
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip())


def _sanitize_error(text: str) -> str:
    """Mask sensitive values in error/debug text.

    Masks:
    - API key patterns: sk-*, key-* prefixes
    - Bearer tokens
    - Long alphanumeric strings (32+ chars, likely tokens or keys)
    """
    # sk-*, key-* style API keys
    text = re.sub(r'\b(sk|key)-[A-Za-z0-9_\-]{10,}', r'\1-***', text)
    # Bearer tokens
    text = re.sub(r'(Bearer\s+)[A-Za-z0-9._\-]{10,}', r'\1***', text, flags=re.IGNORECASE)
    # Long alphanumeric strings (32+ chars)
    text = re.sub(r'[A-Za-z0-9+/=]{32,}', '***', text)
    return text


def _extract_json(text: str, mode: "str | None" = None) -> dict:
    """Extract JSON from model response text, handling markdown fences.

    If mode is provided, validates required fields and fills missing with fallbacks.
    Callers (call_claude/openai/gemini) do NOT pass mode — validation is done
    in call_all_parallel after collecting all results.
    """
    text = text.strip().lstrip('\ufeff')

    result = None
    _unexpected_type: "str | None" = None

    # Pass 1: direct parse
    try:
        parsed = json.loads(text)
        if isinstance(parsed, dict):
            result = parsed
        else:
            _unexpected_type = type(parsed).__name__
    except (json.JSONDecodeError, ValueError):
        pass

    # Pass 2: markdown code fence
    if result is None:
        m = re.search(r'```(?:json)?\s*\n?(.*?)\n?```', text, re.DOTALL)
        if m:
            try:
                parsed = json.loads(m.group(1).strip())
                if isinstance(parsed, dict):
                    result = parsed
                elif _unexpected_type is None:
                    _unexpected_type = type(parsed).__name__
            except (json.JSONDecodeError, ValueError):
                pass

    # Pass 3: control-char cleanup
    if result is None:
        cleaned = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', text)
        if cleaned != text:
            try:
                parsed = json.loads(cleaned)
                if isinstance(parsed, dict):
                    result = parsed
                elif _unexpected_type is None:
                    _unexpected_type = type(parsed).__name__
            except (json.JSONDecodeError, ValueError):
                pass

    # Pass 4: brace-count method — find the first complete JSON object
    if result is None:
        start = text.find('{')
        if start != -1:
            depth = 0
            for i, ch in enumerate(text[start:], start):
                if ch == '{':
                    depth += 1
                elif ch == '}':
                    depth -= 1
                    if depth == 0:
                        try:
                            parsed = json.loads(text[start:i + 1])
                            if isinstance(parsed, dict):
                                result = parsed
                            elif _unexpected_type is None:
                                _unexpected_type = type(parsed).__name__
                        except (json.JSONDecodeError, ValueError):
                            pass
                        break

    if result is None:
        type_hint = f" (Unexpected type: {_unexpected_type})" if _unexpected_type else ""
        result = {
            "raw_response": _sanitize_error(text[:2000]) + type_hint,
            "opinion": text[:500],
            "reasoning": "JSON parse failed — raw response",
            "vote": "abstain",
            "conditions": "",
        }

    if mode:
        _validate_schema(result, mode)

    return result


def _make_section(sections: list, title: str, content: str, section_type: str) -> dict:
    """Build a section dict with all required fields."""
    plain = re.sub(r'<[^>]+>', '', content).strip()
    char_count = len(plain)
    return {
        "id": len(sections) + 1,
        "title": title,
        "content": content.strip(),
        "plain_preview": plain[:80],
        "char_count": char_count,
        "read_time_sec": max(1, char_count // 10),
        "section_type": section_type,
    }


def split_into_sections(html: str) -> list:
    """Split HTML article into sections by h2/h3/h4, table, and blockquote tags."""
    # Split on headings (h2-h4), tables, and blockquotes — capture the delimiter
    parts = re.split(
        r'(<h[234][^>]*>.*?</h[234]>|<table[^>]*>.*?</table>|<blockquote[^>]*>.*?</blockquote>)',
        html,
        flags=re.DOTALL,
    )

    sections = []
    current_title = "冒頭（リード文）"
    current_type = "text"
    current_content = ""

    for part in parts:
        # Check heading (h2/h3/h4) — split pattern guarantees only h2/h3/h4 tags
        if part.startswith('<h'):
            h_match = re.match(r'<h[234][^>]*>(.*?)</h[234]>', part, re.DOTALL)
            if h_match:
                # Flush accumulated content
                if current_content.strip():
                    sections.append(_make_section(
                        sections, current_title, current_content, current_type,
                    ))
                current_title = re.sub(r'<[^>]+>', '', h_match.group(1)).strip()
                current_type = "heading"
                current_content = ""
                continue

        # Check table
        if part.startswith('<table'):
            # Flush accumulated content
            if current_content.strip():
                sections.append(_make_section(
                    sections, current_title, current_content, current_type,
                ))
            # Extract caption for title if present
            cap_match = re.search(r'<caption[^>]*>(.*?)</caption>', part, re.DOTALL)
            tbl_title = re.sub(r'<[^>]+>', '', cap_match.group(1)).strip() if cap_match else "Table"
            sections.append(_make_section(
                sections, tbl_title, part, "table",
            ))
            current_title = "冒頭（リード文）"
            current_type = "text"
            current_content = ""
            continue

        # Check blockquote
        if part.startswith('<blockquote'):
            # Flush accumulated content
            if current_content.strip():
                sections.append(_make_section(
                    sections, current_title, current_content, current_type,
                ))
            sections.append(_make_section(
                sections, "Quote", part, "blockquote",
            ))
            current_title = "冒頭（リード文）"
            current_type = "text"
            current_content = ""
            continue

        # Regular content — accumulate
        current_content += part

    # Flush remaining content
    if current_content.strip():
        sections.append(_make_section(
            sections, current_title, current_content, current_type,
        ))

    return sections


def _jaccard_similarity(s1: str, s2: str) -> float:
    """Compute Jaccard similarity between two normalized strings."""
    set1 = set(s1.lower().split())
    set2 = set(s2.lower().split())
    if not set1 or not set2:
        return 0.0
    return len(set1 & set2) / len(set1 | set2)


def _summarize_for_crossreview(result: dict, mode: str) -> str:
    """Summarize Phase1 unit result for Phase2 cross-review (token compression)."""
    if mode == "judge":
        return json.dumps({
            "vote": result.get("vote"),
            "opinion": result.get("opinion", "")[:200],
        }, ensure_ascii=False)
    elif mode == "deliberate":
        summary = {
            "score": result.get("score"),
            "issues": [i for i in result.get("issues", []) if isinstance(i, dict) and i.get("severity") == "high"],
        }
        rewrites = result.get("rewrite_examples", [])
        if rewrites:
            summary["top_rewrite"] = rewrites[0] if isinstance(rewrites[0], dict) else {"text": rewrites[0]}
        return json.dumps(summary, ensure_ascii=False)
    elif mode == "walkthrough":
        return json.dumps({
            "final_dropout_point": result.get("final_dropout_point"),
            "overall_engagement": result.get("overall_engagement"),
            "killer_issue": result.get("killer_issue", ""),
        }, ensure_ascii=False)
    return json.dumps(result, ensure_ascii=False)[:500]
