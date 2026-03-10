#!/usr/bin/env python3
"""
Apply MAGI consensus plans to rewrite articles.
Reads MAGI results and original articles, sends to Claude for rewriting.
"""

import json
import os
import sys
import glob
import time
import requests
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed

# Load API keys
env_file = Path(__file__).resolve().parent.parent.parent / "config" / "api_keys.env"
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip())

ARTICLES_DIR = "/home/hrmtz/project/content-forge/output/articles"
RESULTS_DIR = Path(__file__).resolve().parent / "results"
TIMEOUT = 120


def extract_magi_plans(result_file: str) -> str:
    """Extract consensus plans from MAGI result file."""
    content = open(result_file).read()
    json_start = content.rfind('\n{')
    if json_start == -1:
        return ""

    try:
        data = json.loads(content[json_start:])
    except json.JSONDecodeError:
        return ""

    phase2 = data.get("phase2", {})
    plans = []
    rewrites = []

    for unit in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        r = phase2.get(unit, {})

        # Consensus plans
        for item in r.get("consensus_plan", []):
            plans.append(f"P{item.get('priority', '?')}: {item.get('action', '')} (効果: {item.get('expected_impact', '')})")

        # Best rewrites
        best = r.get("best_rewrite", {})
        if best and best.get("improved"):
            rewrites.append(f"[{unit}]\nBefore: {best.get('original', '')}\nAfter: {best.get('improved', '')}")

    result = "=== 改善プラン ===\n"
    result += "\n".join(plans[:10])
    if rewrites:
        result += "\n\n=== ベストリライト例 ===\n"
        result += "\n\n".join(rewrites[:3])
    return result


def rewrite_article(article_dir: str, magi_plans: str) -> dict:
    """Send article + MAGI plans to Claude for rewriting."""
    draft_path = os.path.join(ARTICLES_DIR, article_dir, "nlm_draft.json")
    draft = json.loads(open(draft_path).read())
    original_content = draft.get("content", "")
    title = draft.get("title", "")

    system_prompt = """You are an expert medical content editor for a Japanese beauty clinic blog.
You will receive an article and improvement plans from a three-AI review panel (MAGI system).

Your task: Apply the improvement plans to rewrite the article.

Rules:
1. Keep the same HTML structure (p, h2, h3, ul, li, strong, a tags)
2. Keep all image placeholders (___IMGPH_*___) exactly as they are
3. Keep all existing internal links (<a href="...">) unchanged
4. Apply medical expression corrections: 断定→客観的表現 (「証明する」→「報告されている」等)
5. Strengthen SEO: naturally incorporate target keywords in title and intro
6. Improve CTAs: add concrete next steps
7. Add parenthetical explanations for technical terms
8. Balance intro hooks: don't just scare, also show solutions
9. Maintain the article's core message and evidence
10. Output ONLY the rewritten HTML content. No explanations, no markdown fencing.
11. Write in Japanese.
12. Do NOT add fictional statistics, clinic names, or fabricated data."""

    user_msg = f"""# Article Title: {title}

# Original Content:
{original_content}

# MAGI Review Panel Improvement Plans:
{magi_plans}

Rewrite the article applying these improvements. Output only the HTML content."""

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return {"error": "API key not set"}

    resp = requests.post(
        "https://api.anthropic.com/v1/messages",
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
        json={
            "model": "claude-sonnet-4-20250514",
            "max_tokens": 8192,
            "system": system_prompt,
            "messages": [{"role": "user", "content": user_msg}],
        },
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    data = resp.json()
    new_content = data["content"][0]["text"]

    return {
        "article_dir": article_dir,
        "title": title,
        "new_content": new_content,
        "original_length": len(original_content),
        "new_length": len(new_content),
    }


def save_rewrite(result: dict):
    """Save rewritten content back to nlm_draft.json."""
    draft_path = os.path.join(ARTICLES_DIR, result["article_dir"], "nlm_draft.json")
    draft = json.loads(open(draft_path).read())

    # Backup original content if not already backed up
    if not draft.get("_pre_magi_content"):
        draft["_pre_magi_content"] = draft["content"]

    draft["content"] = result["new_content"]
    draft["magi_rewrite_status"] = "rewritten_v2_magi"
    draft["magi_rewrite_date"] = time.strftime("%Y-%m-%d %H:%M")

    with open(draft_path, "w") as f:
        json.dump(draft, f, ensure_ascii=False, indent=2)


def main():
    articles = [
        "article_M1_メンズ鼻整形",
        "article_M2_男性鼻整形自然",
        "article_M3_メンズ鼻整形バレない",
        "article_M4_男性鼻整形ダウンタイム",
        "article_M5_メンズ団子鼻",
        "article_M6_男鼻低い",
        "article_M7_男性鼻整形費用",
        "article_M8_メンズ鼻整形おすすめ",
    ]

    print("◆ MAGI REWRITE — Applying consensus plans ◆\n")

    # Process 2 at a time to respect rate limits
    batch_size = 2
    for i in range(0, len(articles), batch_size):
        batch = articles[i:i + batch_size]
        batch_num = i // batch_size + 1

        print(f"── Batch {batch_num}/4 ──")

        with ThreadPoolExecutor(max_workers=2) as executor:
            futures = {}
            for art in batch:
                result_file = str(RESULTS_DIR / f"{art}.json")
                if not os.path.exists(result_file):
                    print(f"  SKIP {art} (no MAGI result)")
                    continue

                magi_plans = extract_magi_plans(result_file)
                futures[executor.submit(rewrite_article, art, magi_plans)] = art

            for future in as_completed(futures):
                art = futures[future]
                try:
                    result = future.result()
                    if "error" in result:
                        print(f"  ✗ {art}: {result['error']}")
                    else:
                        save_rewrite(result)
                        diff_pct = abs(result["new_length"] - result["original_length"]) / max(result["original_length"], 1) * 100
                        print(f"  ✓ {art} ({result['original_length']}→{result['new_length']} chars, {diff_pct:.0f}% change)")
                except Exception as e:
                    print(f"  ✗ {art}: {e}")

        if i + batch_size < len(articles):
            print("  cooling 10s...")
            time.sleep(10)

    print("\n◆ ALL REWRITES COMPLETE ◆")


if __name__ == "__main__":
    main()
