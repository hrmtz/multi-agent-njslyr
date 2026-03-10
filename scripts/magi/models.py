"""
MAGI System — Model API Callers
All models accessed via REST (no SDK dependencies)
"""

import json
import os
import re
import sys
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed


# ── Model Configuration (single source of truth) ─────────────────────────────

MODEL_CONFIG = {
    "MELCHIOR": {
        "caller": None,  # set below after function definitions
        "model_id": "claude-sonnet-5-20260203",
        "label": "Claude Sonnet 5",
        "timeout": 90,
        "max_retries": 2,
    },
    "BALTHASAR": {
        "caller": None,
        "model_id": "gpt-5.2",
        "label": "GPT-5.2",
        "timeout": 90,
        "max_retries": 2,
    },
    "CASPER": {
        "caller": None,
        "model_id": "gemini-3-pro-preview",
        "label": "Gemini 3 Pro",
        "timeout": 90,
        "max_retries": 2,
    },
}


def get_model_label(name: str) -> str:
    """Return display label for a MAGI unit."""
    return MODEL_CONFIG.get(name, {}).get("label", name)


# ── Schema Validation ─────────────────────────────────────────────────────────

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


def _validate_schema(result: dict, mode: str) -> dict:
    """Fill missing required fields and emit warnings to stderr."""
    for field in _REQUIRED_FIELDS.get(mode, []):
        if field not in result:
            print(
                f"[MAGI WARNING] Schema: missing field '{field}' for mode '{mode}'",
                file=sys.stderr,
            )
            result[field] = _FIELD_DEFAULTS.get(field, "")
    return result


# ── JSON Extraction ───────────────────────────────────────────────────────────

def _extract_json(text: str, mode: str | None = None) -> dict:
    """Extract JSON from model response text, handling markdown fences.

    If mode is provided, validates required fields and fills missing with fallbacks.
    Callers (call_claude/openai/gemini) do NOT pass mode — validation is done
    in call_all_parallel after collecting all results.
    """
    # Strip BOM and whitespace
    text = text.strip().lstrip('\ufeff')

    result = None

    # Try direct parse first
    try:
        result = json.loads(text)
    except (json.JSONDecodeError, ValueError):
        pass

    if result is None:
        # Try extracting from markdown code block
        m = re.search(r'```(?:json)?\s*\n?(.*?)\n?```', text, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(1).strip())
            except (json.JSONDecodeError, ValueError):
                pass

    if result is None:
        # Try finding first { ... } block (greedy — outermost braces)
        m = re.search(r'\{.*\}', text, re.DOTALL)
        if m:
            try:
                result = json.loads(m.group(0))
            except (json.JSONDecodeError, ValueError):
                pass

    if result is None:
        # Try stripping control characters that break JSON parsing
        cleaned = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', text)
        if cleaned != text:
            try:
                result = json.loads(cleaned)
            except (json.JSONDecodeError, ValueError):
                pass

    if result is None:
        # Last resort: scan for opening brace
        for start in range(min(50, len(text))):
            if text[start] == '{':
                try:
                    result = json.loads(text[start:])
                    break
                except (json.JSONDecodeError, ValueError):
                    break

    if result is None:
        result = {
            "opinion": text[:500],
            "reasoning": "JSON parse failed — raw response",
            "vote": "abstain",
            "conditions": "",
        }

    if mode:
        _validate_schema(result, mode)

    return result


# ── Retry Helper ──────────────────────────────────────────────────────────────

def _call_with_retry(fn, max_retries: int = 2, delay: float = 5):
    """Retry on rate limit / transient errors with exponential backoff."""
    import time as _time
    for attempt in range(max_retries + 1):
        try:
            return fn()
        except requests.exceptions.HTTPError as e:
            status = e.response.status_code if e.response is not None else 0
            if status in (429, 502, 503) and attempt < max_retries:
                _time.sleep(delay * (2 ** attempt))
                continue
            raise
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
            if attempt < max_retries:
                _time.sleep(delay * (2 ** attempt))
                continue
            raise


# ── Model Callers ─────────────────────────────────────────────────────────────

def call_claude(system_prompt: str, user_message: str) -> dict:
    """Call Claude API via REST."""
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        raise ValueError("ANTHROPIC_API_KEY not set")

    cfg = MODEL_CONFIG["MELCHIOR"]

    def _do():
        resp = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": cfg["model_id"],
                "max_tokens": 4096,
                "system": system_prompt,
                "messages": [{"role": "user", "content": user_message}],
            },
            timeout=cfg["timeout"],
        )
        resp.raise_for_status()
        return resp

    resp = _call_with_retry(_do, max_retries=cfg["max_retries"])
    data = resp.json()
    text = data["content"][0]["text"]
    return _extract_json(text)


def call_openai(system_prompt: str, user_message: str) -> dict:
    """Call OpenAI API via REST."""
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        raise ValueError("OPENAI_API_KEY not set")

    cfg = MODEL_CONFIG["BALTHASAR"]

    def _do():
        resp = requests.post(
            "https://api.openai.com/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": cfg["model_id"],
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_message},
                ],
                "max_completion_tokens": 4096,
                "response_format": {"type": "json_object"},
            },
            timeout=cfg["timeout"],
        )
        resp.raise_for_status()
        return resp

    resp = _call_with_retry(_do, max_retries=cfg["max_retries"])
    data = resp.json()
    text = data["choices"][0]["message"]["content"]
    return _extract_json(text)


def call_gemini(system_prompt: str, user_message: str) -> dict:
    """Call Gemini API via REST.

    Gemini 3 Pro. Thinking mode is mandatory for this model.
    """
    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        raise ValueError("GEMINI_API_KEY not set")

    cfg = MODEL_CONFIG["CASPER"]

    def _do():
        resp = requests.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/{cfg['model_id']}:generateContent",
            headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
            json={
                "systemInstruction": {"parts": [{"text": system_prompt}]},
                "contents": [{"parts": [{"text": user_message}]}],
                "generationConfig": {
                    "maxOutputTokens": 4096,
                    "responseMimeType": "application/json",
                },
            },
            timeout=cfg["timeout"],
        )
        resp.raise_for_status()
        return resp

    resp = _call_with_retry(_do, max_retries=cfg["max_retries"])
    data = resp.json()
    parts = data["candidates"][0]["content"]["parts"]

    # With thinking disabled, parts should be clean JSON
    # Strategy 1: Try each part individually (most reliable)
    for p in parts:
        if p.get("thought"):
            continue
        t = p.get("text", "").strip()
        if t:
            try:
                return json.loads(t)
            except (json.JSONDecodeError, ValueError):
                pass

    # Strategy 2: Concat all non-thought parts
    text = "".join(p.get("text", "") for p in parts if not p.get("thought")).strip()
    if text:
        result = _extract_json(text)
        if result.get("vote") != "abstain":
            return result

    # Strategy 3: Try all parts (last resort)
    text = "".join(p.get("text", "") for p in parts).strip()
    return _extract_json(text)


# ── Wire callers into MODEL_CONFIG ────────────────────────────────────────────

MODEL_CONFIG["MELCHIOR"]["caller"] = call_claude
MODEL_CONFIG["BALTHASAR"]["caller"] = call_openai
MODEL_CONFIG["CASPER"]["caller"] = call_gemini

# Model dispatcher (derived from MODEL_CONFIG)
MODEL_CALLERS = {k: v["caller"] for k, v in MODEL_CONFIG.items()}


# ── Parallel Dispatcher ───────────────────────────────────────────────────────

def call_all_parallel(
    prompts: dict[str, tuple[str, str]],
    skip: list[str] | None = None,
    mode: str | None = None,
) -> dict[str, dict]:
    """Call all MAGI units in parallel.

    Args:
        prompts: {unit_name: (system_prompt, user_message)}
        skip: list of unit names to skip (intentional — excluded from valid count)
        mode: if provided, validate schema of each result after collection

    Returns:
        {unit_name: response_dict}

    Raises:
        RuntimeError: if fewer than 2 non-skipped units return valid (non-abstain) responses
    """
    skip = skip or []
    results = {}

    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {}
        for name, (sys_prompt, user_msg) in prompts.items():
            if name in skip:
                continue
            caller = MODEL_CALLERS[name]
            futures[executor.submit(caller, sys_prompt, user_msg)] = name

        for future in as_completed(futures):
            name = futures[future]
            try:
                results[name] = future.result()
            except requests.exceptions.HTTPError as e:
                status = e.response.status_code if e.response is not None else "?"
                body = ""
                if e.response is not None:
                    try:
                        body = e.response.json().get("error", {}).get("message", "")[:200]
                    except Exception:
                        body = e.response.text[:200]
                results[name] = {
                    "opinion": f"API Error {status}: {body or str(e)}",
                    "reasoning": "",
                    "vote": "abstain",
                    "conditions": "",
                }
            except Exception as e:
                results[name] = {
                    "opinion": f"Error: {type(e).__name__}: {e}",
                    "reasoning": "",
                    "vote": "abstain",
                    "conditions": "",
                }

    # Schema validation
    if mode:
        for name in results:
            _validate_schema(results[name], mode)

    # Check valid response count (skipped units excluded)
    valid_count = sum(
        1 for name, r in results.items()
        if name not in skip and r.get("vote") != "abstain"
    )
    if valid_count < 2:
        raise RuntimeError("MAGI requires at least 2 valid responses")

    return results
