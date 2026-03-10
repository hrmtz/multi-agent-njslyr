"""
MAGI System — Model API Callers
All models accessed via REST (no SDK dependencies)
"""

import json
import os
import re
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed


TIMEOUT = 90


def _extract_json(text: str) -> dict:
    """Extract JSON from model response text, handling markdown fences."""
    # Strip BOM and whitespace
    text = text.strip().lstrip('\ufeff')

    # Try direct parse first
    try:
        return json.loads(text)
    except (json.JSONDecodeError, ValueError):
        pass

    # Try extracting from markdown code block
    m = re.search(r'```(?:json)?\s*\n?(.*?)\n?```', text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(1).strip())
        except (json.JSONDecodeError, ValueError):
            pass

    # Try finding first { ... } block (greedy — outermost braces)
    m = re.search(r'\{.*\}', text, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(0))
        except (json.JSONDecodeError, ValueError):
            pass

    # Try stripping control characters that break JSON parsing
    cleaned = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', text)
    if cleaned != text:
        try:
            return json.loads(cleaned)
        except (json.JSONDecodeError, ValueError):
            pass

    # Fallback: return raw text as opinion
    # But first — if text looks like it starts with valid JSON, try harder
    for start in range(min(50, len(text))):
        if text[start] == '{':
            try:
                return json.loads(text[start:])
            except (json.JSONDecodeError, ValueError):
                break

    return {
        "opinion": text[:500],
        "reasoning": "JSON parse failed — raw response",
        "vote": "abstain",
        "conditions": "",
    }


def _call_with_retry(fn, max_retries=1, delay=5):
    """Retry on 429 rate limit errors."""
    import time as _time
    for attempt in range(max_retries + 1):
        try:
            return fn()
        except requests.exceptions.HTTPError as e:
            if e.response is not None and e.response.status_code == 429 and attempt < max_retries:
                _time.sleep(delay * (attempt + 1))
                continue
            raise


def call_claude(system_prompt: str, user_message: str) -> dict:
    """Call Claude API via REST."""
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return {"opinion": "API key not set", "reasoning": "", "vote": "abstain", "conditions": ""}

    def _do():
        resp = requests.post(
            "https://api.anthropic.com/v1/messages",
            headers={
                "x-api-key": api_key,
                "anthropic-version": "2023-06-01",
                "content-type": "application/json",
            },
            json={
                "model": "claude-sonnet-5-20260203",
                "max_tokens": 4096,
                "system": system_prompt,
                "messages": [{"role": "user", "content": user_message}],
            },
            timeout=TIMEOUT,
        )
        resp.raise_for_status()
        return resp

    resp = _call_with_retry(_do)
    data = resp.json()
    text = data["content"][0]["text"]
    return _extract_json(text)


def call_openai(system_prompt: str, user_message: str) -> dict:
    """Call OpenAI API via REST."""
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        return {"opinion": "API key not set", "reasoning": "", "vote": "abstain", "conditions": ""}

    def _do():
        resp = requests.post(
            "https://api.openai.com/v1/chat/completions",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": "gpt-5.2",
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_message},
                ],
                "max_tokens": 4096,
                "response_format": {"type": "json_object"},
            },
            timeout=TIMEOUT,
        )
        resp.raise_for_status()
        return resp

    resp = _call_with_retry(_do)
    data = resp.json()
    text = data["choices"][0]["message"]["content"]
    return _extract_json(text)


def call_gemini(system_prompt: str, user_message: str) -> dict:
    """Call Gemini API via REST.

    Gemini 3 Flash (upgraded from 2.5-flash which had thinking mode JSON corruption).
    thinkingConfig kept at 0 as precaution for JSON mode compatibility.
    """
    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        return {"opinion": "API key not set", "reasoning": "", "vote": "abstain", "conditions": ""}

    def _do():
        resp = requests.post(
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-preview:generateContent",
            headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
            json={
                "systemInstruction": {"parts": [{"text": system_prompt}]},
                "contents": [{"parts": [{"text": user_message}]}],
                "generationConfig": {
                    "maxOutputTokens": 4096,
                    "responseMimeType": "application/json",
                    "thinkingConfig": {"thinkingBudget": 0},
                },
            },
            timeout=TIMEOUT,
        )
        resp.raise_for_status()
        return resp

    resp = _call_with_retry(_do)
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


# Model dispatcher
MODEL_CALLERS = {
    "MELCHIOR": call_claude,
    "BALTHASAR": call_openai,
    "CASPER": call_gemini,
}


def call_all_parallel(prompts: dict[str, tuple[str, str]], skip: list[str] | None = None) -> dict[str, dict]:
    """Call all MAGI units in parallel.

    Args:
        prompts: {unit_name: (system_prompt, user_message)}
        skip: list of unit names to skip

    Returns:
        {unit_name: response_dict}
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

    return results
