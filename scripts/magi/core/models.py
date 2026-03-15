"""
MAGI System — Model configuration + API callers.

MODEL_CONFIG is the single source of truth for model IDs, labels,
timeouts, and caller functions.
"""

import json
import os
import random
import subprocess
import sys
import requests
from concurrent.futures import ThreadPoolExecutor, as_completed

from core.schemas import _validate_schema  # noqa: F401 — re-exported
from core.utils import _extract_json, _sanitize_error  # noqa: F401 — re-exported

# Whitelist of environment variables passed to claude CLI subprocess
_CLAUDE_ENV_WHITELIST = frozenset({"PATH", "HOME", "LANG", "TERM"})


# ── Model Configuration (single source of truth) ─────────────────────────────

MODEL_CONFIG = {
    "MELCHIOR": {
        "caller": None,  # set below after function definitions
        "model_id": "claude-sonnet-5-20260203",
        "label": "Claude Sonnet 5",
        "timeout": 180,
        "max_retries": 2,
        "capabilities": {},
    },
    "BALTHASAR": {
        "caller": None,
        "model_id": "gpt-5.2",
        "label": "GPT-5.2",
        "timeout": 90,
        "max_retries": 2,
        "capabilities": {"json_response_format": True},
    },
    "CASPER": {
        "caller": None,
        "model_id": "gemini-3-pro-preview",
        "label": "Gemini 3 Pro",
        "timeout": 90,
        "max_retries": 2,
        "capabilities": {},
    },
}


def get_model_label(name: str) -> str:
    """Return display label for a MAGI unit."""
    return MODEL_CONFIG.get(name, {}).get("label", name)


# ── Retry Helper ──────────────────────────────────────────────────────────────

def _call_with_retry(fn, max_retries: int = 2, delay: float = 5):
    """Retry on rate limit / transient errors with exponential backoff + jitter."""
    import time as _time
    for attempt in range(max_retries + 1):
        try:
            return fn()
        except requests.exceptions.HTTPError as e:
            status = e.response.status_code if e.response is not None else 0
            if status in (429, 502, 503) and attempt < max_retries:
                sleep_time = delay * (2 ** attempt) + random.uniform(0, delay)
                _time.sleep(sleep_time)
                continue
            raise
        except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
            if attempt < max_retries:
                sleep_time = delay * (2 ** attempt) + random.uniform(0, delay)
                _time.sleep(sleep_time)
                continue
            raise


# ── Model Callers ─────────────────────────────────────────────────────────────

def call_claude(system_prompt: str, user_message: str) -> dict:
    """Call Claude via CLI (uses Max plan tokens, no API key needed)."""
    cfg = MODEL_CONFIG["MELCHIOR"]

    prompt = f"{system_prompt}\n\n---\n\n{user_message}"

    # Whitelist-only env: prevents leaking API keys / session tokens to subprocess
    env = {k: v for k, v in os.environ.items() if k in _CLAUDE_ENV_WHITELIST}

    result = subprocess.run(
        ["claude", "-p", "--output-format", "json"],
        input=prompt,
        capture_output=True,
        text=True,
        timeout=cfg["timeout"] + 60,
        env=env,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"claude CLI error (exit {result.returncode}): "
            f"{_sanitize_error(result.stderr[:500])}"
        )

    # CLI --output-format json returns {"result": "...", ...}
    try:
        cli_resp = json.loads(result.stdout)
        text = cli_resp.get("result", result.stdout)
    except (json.JSONDecodeError, ValueError):
        text = result.stdout

    return _extract_json(text)


def call_openai(system_prompt: str, user_message: str) -> dict:
    """Call OpenAI API via REST."""
    api_key = os.environ.get("OPENAI_API_KEY", "")
    if not api_key:
        raise ValueError("OPENAI_API_KEY not set")

    cfg = MODEL_CONFIG["BALTHASAR"]
    use_json_format = cfg.get("capabilities", {}).get("json_response_format", False)

    _openai_url = "https://api.openai.com/v1/chat/completions"
    _openai_headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    _base_payload = {
        "model": cfg["model_id"],
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        "max_completion_tokens": 4096,
    }

    def _do():
        session = requests.Session()
        if use_json_format:
            payload = {**_base_payload, "response_format": {"type": "json_object"}}
        else:
            payload = _base_payload

        resp = session.post(_openai_url, headers=_openai_headers, json=payload, timeout=cfg["timeout"])

        if resp.status_code == 400 and use_json_format:
            try:
                err_code = resp.json().get("error", {}).get("code", "")
            except Exception:
                err_code = ""
            if err_code in ("unsupported_response_format", "invalid_request_error", ""):
                resp = session.post(_openai_url, headers=_openai_headers, json=_base_payload, timeout=cfg["timeout"])

        resp.raise_for_status()
        return resp

    resp = _call_with_retry(_do, max_retries=cfg["max_retries"])
    data = resp.json()
    text = data["choices"][0]["message"]["content"]
    return _extract_json(text)


def call_gemini(system_prompt: str, user_message: str) -> dict:
    """Call Gemini API via REST."""
    api_key = os.environ.get("GEMINI_API_KEY", "")
    if not api_key:
        raise ValueError("GEMINI_API_KEY not set")

    cfg = MODEL_CONFIG["CASPER"]

    def _do():
        session = requests.Session()
        resp = session.post(
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

    # Guard: missing candidates or content
    candidates = data.get("candidates") or []
    if not candidates:
        return _extract_json("")
    content = candidates[0].get("content") or {}
    parts = content.get("parts") or []
    if not parts:
        return _extract_json("")

    for p in parts:
        if p.get("thought"):
            continue
        t = p.get("text", "").strip()
        if t:
            try:
                return json.loads(t)
            except (json.JSONDecodeError, ValueError):
                pass

    text = "".join(p.get("text", "") for p in parts if not p.get("thought")).strip()
    if text:
        result = _extract_json(text)
        if result.get("vote") != "abstain":
            return result

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
    prompts: "dict[str, tuple[str, str]]",
    skip: "list[str] | None" = None,
    *,
    mode: str,
    session: "str | None" = None,
) -> "dict[str, dict]":
    """Call all MAGI units in parallel.

    Args:
        prompts: {unit_name: (system_prompt, user_message)}
        skip: list of unit names to skip
        mode: deliberation mode ('judge' | 'deliberate' | 'walkthrough').
            Used for schema validation after all results are collected.
        session: optional session id passed to _validate_schema for
            session-specific required fields.

    Returns:
        {unit_name: response_dict}

    Raises:
        RuntimeError: if fewer than 2 non-skipped units return valid responses
    """
    skip = skip or []
    results = {}

    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {}
        for name, (sys_prompt, user_msg) in prompts.items():
            if name in skip:
                continue
            caller = MODEL_CALLERS.get(name)
            if caller is None:
                print(f"[MAGI WARNING] Unknown unit: '{name}' — skipping", file=sys.stderr)
                continue
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
                    "opinion": f"API Error {status}: {_sanitize_error(body or str(e))}",
                    "reasoning": "",
                    "vote": "abstain",
                    "conditions": "",
                }
            except subprocess.TimeoutExpired:
                results[name] = {
                    "opinion": "Error: claude CLI timed out",
                    "reasoning": "",
                    "vote": "abstain",
                    "conditions": "",
                }
            except Exception as e:
                results[name] = {
                    "opinion": f"Error: {type(e).__name__}: {_sanitize_error(str(e))}",
                    "reasoning": "",
                    "vote": "abstain",
                    "conditions": "",
                }

    if mode:
        for name in results:
            _validate_schema(results[name], mode, session=session)

    valid_count = sum(
        1 for name, r in results.items()
        if name not in skip and r.get("vote") != "abstain"
    )
    if valid_count < 2:
        raise RuntimeError("MAGI requires at least 2 valid responses")

    return results
