#!/usr/bin/env python3
"""
MAGI System — Three-way AI Deliberation
Inspired by NERV's MAGI: MELCHIOR / BALTHASAR / CASPER

Modes:
    judge:      approve/reject voting (original)
    deliberate: discussion producing actionable improvements (default)

Usage:
    python3 scripts/magi/magi.py "Should we deploy this feature?"
    python3 scripts/magi/magi.py --mode deliberate --session article_review --file article.html
    python3 scripts/magi/magi.py --mode judge --session strategy "Should we migrate to headless CMS?"
"""

import argparse
import json
import os
import sys
import time
from pathlib import Path

# Load API keys
_env_file = Path(__file__).resolve().parent.parent.parent / "config" / "api_keys.env"
if _env_file.exists():
    for line in _env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, val = line.partition("=")
            os.environ.setdefault(key.strip(), val.strip())

from prompts import (
    PERSONAS, SESSION_TYPES,
    JUDGE_OUTPUT_FORMAT, JUDGE_CROSS_REVIEW,
    DELIBERATE_OUTPUT_FORMAT, DELIBERATE_CROSS_REVIEW,
    WALKTHROUGH_OUTPUT_FORMAT, WALKTHROUGH_CROSS_REVIEW,
    get_walkthrough_personas,
)
from models import call_all_parallel


# ── ANSI Colors ──────────────────────────────────────────────────────────────

class C:
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"
    WHITE = "\033[37m"
    RESET = "\033[0m"

UNIT_COLORS = {
    "MELCHIOR": C.CYAN,
    "BALTHASAR": C.YELLOW,
    "CASPER": C.MAGENTA,
}

VOTE_DISPLAY = {
    "approve": f"{C.GREEN}{C.BOLD}APPROVE{C.RESET}",
    "reject": f"{C.RED}{C.BOLD}REJECT{C.RESET}",
    "conditional_approve": f"{C.YELLOW}{C.BOLD}CONDITIONAL{C.RESET}",
    "abstain": f"{C.DIM}ABSTAIN{C.RESET}",
}

SEVERITY_COLORS = {
    "high": C.RED,
    "medium": C.YELLOW,
    "low": C.DIM,
}


def print_header(mode: str):
    mode_label = {"judge": "JUDGE", "deliberate": "DELIBERATE", "walkthrough": "WALKTHROUGH"}.get(mode, mode.upper())
    print(f"""
{C.BOLD}{C.RED}╔══════════════════════════════════════════════════╗
║            M  A  G  I    S  Y  S  T  E  M         ║
║        MELCHIOR  ·  BALTHASAR  ·  CASPER           ║
║              [ {mode_label:^10} MODE ]                   ║
╚══════════════════════════════════════════════════╝{C.RESET}
""")


# ── Judge Mode Display ───────────────────────────────────────────────────────

def print_judge_result(name: str, result: dict):
    color = UNIT_COLORS[name]
    persona = PERSONAS[name]
    vote = VOTE_DISPLAY.get(result.get("vote", "abstain"), result.get("vote", "?"))

    print(f"{color}{C.BOLD}┌─ {persona['name']} ({persona['model_label']}) ─ {persona['perspective']} ─{C.RESET}")
    print(f"{color}│{C.RESET} Vote: {vote}")
    opinion = result.get("opinion", "")
    for line in opinion.split("\n"):
        print(f"{color}│{C.RESET} {line}")
    if result.get("conditions"):
        print(f"{color}│{C.RESET} {C.YELLOW}条件: {result['conditions']}{C.RESET}")
    reasoning = result.get("reasoning", "")
    if reasoning:
        print(f"{color}│{C.RESET} {C.DIM}根拠: {reasoning[:200]}{C.RESET}")
    print(f"{color}└{'─' * 50}{C.RESET}")
    print()


def aggregate_votes(results: dict[str, dict]) -> tuple[str, str]:
    votes = {}
    for name, r in results.items():
        v = r.get("vote", "abstain")
        if v == "conditional_approve":
            v = "approve"
        votes[name] = v

    approve = sum(1 for v in votes.values() if v == "approve")
    reject = sum(1 for v in votes.values() if v == "reject")
    active = sum(1 for v in votes.values() if v != "abstain")

    if active < 2:
        return "INSUFFICIENT", "投票数不足 — 判定不能"
    if approve >= 2:
        conditions = [r.get("conditions", "") for r in results.values()
                      if r.get("vote") == "conditional_approve" and r.get("conditions")]
        return "APPROVED", " / ".join(conditions) if conditions else ""
    elif reject >= 2:
        return "REJECTED", ""
    else:
        return "SPLIT", "意見分裂 — 合意に至らず"


def print_decision(decision: str, detail: str):
    colors = {"APPROVED": C.GREEN, "REJECTED": C.RED, "SPLIT": C.MAGENTA, "INSUFFICIENT": C.DIM}
    color = colors.get(decision, C.WHITE)
    print(f"{C.BOLD}{'━' * 52}{C.RESET}")
    print(f"  {color}{C.BOLD}██ MAGI DECISION: {decision} ██{C.RESET}")
    if detail:
        print(f"  {C.DIM}{detail}{C.RESET}")
    print(f"{C.BOLD}{'━' * 52}{C.RESET}")


# ── Deliberate Mode Display ──────────────────────────────────────────────────

def print_deliberate_result(name: str, result: dict, phase: int):
    color = UNIT_COLORS[name]
    persona = PERSONAS[name]
    score = result.get("score", "?")

    score_color = C.GREEN if isinstance(score, int) and score >= 70 else C.YELLOW if isinstance(score, int) and score >= 50 else C.RED
    print(f"{color}{C.BOLD}┌─ {persona['name']} ({persona['model_label']}) ─ {persona['perspective']} ─{C.RESET}")
    print(f"{color}│{C.RESET} Score: {score_color}{C.BOLD}{score}/100{C.RESET}")

    if phase == 1:
        # Strengths
        strengths = result.get("strengths", [])
        if strengths:
            print(f"{color}│{C.RESET} {C.GREEN}✓ 強み:{C.RESET}")
            for s in strengths[:3]:
                print(f"{color}│{C.RESET}   {C.GREEN}•{C.RESET} {s}")

        # Issues (handles both dict-array and string-array formats)
        issues = result.get("issues", [])
        if issues:
            print(f"{color}│{C.RESET} {C.RED}✗ 指摘:{C.RESET}")
            for issue in issues[:5]:
                if isinstance(issue, str):
                    print(f"{color}│{C.RESET}   {C.YELLOW}•{C.RESET} {issue[:150]}")
                elif isinstance(issue, dict):
                    sev = issue.get("severity", "medium")
                    sev_color = SEVERITY_COLORS.get(sev, C.WHITE)
                    loc = issue.get("location", "")
                    print(f"{color}│{C.RESET}   {sev_color}[{sev.upper()}]{C.RESET} {loc}: {issue.get('problem', '')}")
                    if issue.get("suggestion"):
                        print(f"{color}│{C.RESET}   {C.DIM}→ {issue['suggestion'][:120]}{C.RESET}")

        # Rewrite examples (handles both dict-array and string-array formats)
        rewrites = result.get("rewrite_examples", [])
        if rewrites:
            print(f"{color}│{C.RESET} {C.BLUE}✎ リライト例:{C.RESET}")
            for rw in rewrites[:2]:
                if isinstance(rw, str):
                    print(f"{color}│{C.RESET}   {C.GREEN}→{C.RESET} {rw[:120]}")
                elif isinstance(rw, dict):
                    print(f"{color}│{C.RESET}   {C.RED}Before:{C.RESET} {rw.get('original', '')[:80]}")
                    print(f"{color}│{C.RESET}   {C.GREEN}After:{C.RESET}  {rw.get('improved', '')[:80]}")
                    if rw.get("reason"):
                        print(f"{color}│{C.RESET}   {C.DIM}理由: {rw['reason'][:80]}{C.RESET}")

    elif phase == 2:
        # Agreements / Disagreements
        for a in result.get("agreements", [])[:2]:
            print(f"{color}│{C.RESET} {C.GREEN}✓ 同意:{C.RESET} {a[:100]}")
        for d in result.get("disagreements", [])[:2]:
            print(f"{color}│{C.RESET} {C.RED}✗ 反論:{C.RESET} {d[:100]}")
        for m in result.get("missed_issues", [])[:2]:
            print(f"{color}│{C.RESET} {C.YELLOW}+ 追加:{C.RESET} {m[:100]}")

        # Consensus plan
        plan = result.get("consensus_plan", [])
        if plan:
            print(f"{color}│{C.RESET} {C.BOLD}◆ 改善プラン:{C.RESET}")
            for item in plan[:5]:
                p = item.get("priority", "?")
                print(f"{color}│{C.RESET}   {C.BOLD}P{p}:{C.RESET} {item.get('action', '')[:100]}")
                print(f"{color}│{C.RESET}   {C.DIM}   効果: {item.get('expected_impact', '')[:80]}{C.RESET}")

        # Best rewrite
        best = result.get("best_rewrite", {})
        if best and best.get("improved"):
            print(f"{color}│{C.RESET} {C.BLUE}★ ベストリライト:{C.RESET}")
            print(f"{color}│{C.RESET}   {C.RED}Before:{C.RESET} {best.get('original', '')[:80]}")
            print(f"{color}│{C.RESET}   {C.GREEN}After:{C.RESET}  {best.get('improved', '')[:80]}")

    print(f"{color}└{'─' * 50}{C.RESET}")
    print()


def print_consensus_summary(phase2_results: dict[str, dict]):
    """Merge all consensus plans into a final summary."""
    print(f"\n{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}  ◆◆◆ MAGI CONSENSUS — 改善アクションプラン ◆◆◆{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}\n")

    # Collect scores
    scores = {}
    for name, r in phase2_results.items():
        s = r.get("score")
        if isinstance(s, (int, float)):
            scores[name] = s

    if scores:
        avg = sum(scores.values()) / len(scores)
        score_parts = [f"{PERSONAS[n]['name']}={s}" for n, s in scores.items()]
        avg_color = C.GREEN if avg >= 70 else C.YELLOW if avg >= 50 else C.RED
        print(f"  {C.BOLD}総合スコア: {avg_color}{avg:.0f}/100{C.RESET} ({', '.join(score_parts)})\n")

    # Merge all consensus plans
    all_actions = []
    for name, r in phase2_results.items():
        for item in r.get("consensus_plan", []):
            all_actions.append({
                "from": PERSONAS[name]["name"],
                "priority": item.get("priority", 99),
                "action": item.get("action", ""),
                "impact": item.get("expected_impact", ""),
            })

    # Sort by priority
    all_actions.sort(key=lambda x: x["priority"])

    # Deduplicate by similarity (simple)
    seen = []
    unique = []
    for a in all_actions:
        action_key = a["action"][:30]
        if action_key not in seen:
            seen.append(action_key)
            unique.append(a)

    if unique:
        for i, a in enumerate(unique[:7], 1):
            print(f"  {C.BOLD}{i}.{C.RESET} {a['action']}")
            print(f"     {C.DIM}効果: {a['impact']} (by {a['from']}){C.RESET}")
            print()

    # Best rewrites
    print(f"  {C.BOLD}{C.BLUE}── ベストリライト提案 ──{C.RESET}\n")
    for name, r in phase2_results.items():
        best = r.get("best_rewrite", {})
        if best and best.get("improved"):
            print(f"  {UNIT_COLORS[name]}{PERSONAS[name]['name']}:{C.RESET}")
            print(f"    {C.RED}Before:{C.RESET} {best.get('original', '')[:120]}")
            print(f"    {C.GREEN}After:{C.RESET}  {best.get('improved', '')[:120]}")
            print()

    print(f"{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}")


# ── Run Functions ────────────────────────────────────────────────────────────

def run_judge(question: str, session: str, skip: list[str], output_json: bool):
    """Judge mode: approve/reject voting."""
    session_context = SESSION_TYPES.get(session, SESSION_TYPES["general"])

    print(f"{C.BOLD}── Phase 1: Initial Deliberation ──{C.RESET}\n")
    t0 = time.time()

    phase1_prompts = {}
    for name, persona in PERSONAS.items():
        if name in skip:
            continue
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context + JUDGE_OUTPUT_FORMAT
        phase1_prompts[name] = (sys_prompt, question)

    phase1_results = call_all_parallel(phase1_prompts, skip)
    t1 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase1_results:
            print_judge_result(name, phase1_results[name])
    print(f"{C.DIM}  Phase 1 completed in {t1 - t0:.1f}s{C.RESET}\n")

    print(f"{C.BOLD}── Phase 2: Cross-Review ──{C.RESET}\n")
    t2 = time.time()

    phase2_prompts = {}
    for name, persona in PERSONAS.items():
        if name in skip or name not in phase1_results:
            continue
        others = []
        for other_name, other_result in phase1_results.items():
            if other_name == name:
                continue
            other_persona = PERSONAS[other_name]
            others.append(
                f"[{other_persona['name']} ({other_persona['perspective']})] "
                f"Vote: {other_result.get('vote', '?')} — "
                f"{other_result.get('opinion', '')}"
            )
        other_text = "\n\n".join(others)
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context
        user_msg = (
            f"Original question:\n{question}\n\n"
            f"Your initial assessment:\n{json.dumps(phase1_results[name], ensure_ascii=False)}\n\n"
            + JUDGE_CROSS_REVIEW.format(other_opinions=other_text)
        )
        phase2_prompts[name] = (sys_prompt, user_msg)

    phase2_results = call_all_parallel(phase2_prompts, skip)
    t3 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase2_results:
            print_judge_result(name, phase2_results[name])
    print(f"{C.DIM}  Phase 2 completed in {t3 - t2:.1f}s{C.RESET}\n")

    decision, detail = aggregate_votes(phase2_results)
    print_decision(decision, detail)

    if output_json:
        output = {
            "mode": "judge", "decision": decision, "detail": detail,
            "phase1": phase1_results, "phase2": phase2_results,
            "elapsed_seconds": round(t3 - t0, 1),
        }
        print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")

    return decision, phase2_results


def run_deliberate(question: str, session: str, skip: list[str], output_json: bool):
    """Deliberate mode: discussion producing actionable improvements."""
    session_context = SESSION_TYPES.get(session, SESSION_TYPES["general"])

    print(f"{C.BOLD}── Phase 1: Individual Analysis ──{C.RESET}\n")
    t0 = time.time()

    phase1_prompts = {}
    for name, persona in PERSONAS.items():
        if name in skip:
            continue
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context + DELIBERATE_OUTPUT_FORMAT
        phase1_prompts[name] = (sys_prompt, question)

    phase1_results = call_all_parallel(phase1_prompts, skip)
    t1 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase1_results:
            print_deliberate_result(name, phase1_results[name], phase=1)
    print(f"{C.DIM}  Phase 1 completed in {t1 - t0:.1f}s{C.RESET}\n")

    print(f"{C.BOLD}── Phase 2: Cross-Review & Consensus ──{C.RESET}\n")
    t2 = time.time()

    phase2_prompts = {}
    for name, persona in PERSONAS.items():
        if name in skip or name not in phase1_results:
            continue
        others = []
        for other_name, other_result in phase1_results.items():
            if other_name == name:
                continue
            other_persona = PERSONAS[other_name]
            others.append(
                f"[{other_persona['name']} ({other_persona['perspective']})]:\n"
                f"{json.dumps(other_result, ensure_ascii=False, indent=2)}"
            )
        other_text = "\n\n".join(others)
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context
        user_msg = (
            f"Original content:\n{question}\n\n"
            f"Your initial analysis:\n{json.dumps(phase1_results[name], ensure_ascii=False)}\n\n"
            + DELIBERATE_CROSS_REVIEW.format(other_opinions=other_text)
        )
        phase2_prompts[name] = (sys_prompt, user_msg)

    phase2_results = call_all_parallel(phase2_prompts, skip)
    t3 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase2_results:
            print_deliberate_result(name, phase2_results[name], phase=2)
    print(f"{C.DIM}  Phase 2 completed in {t3 - t2:.1f}s{C.RESET}\n")

    # Print consensus summary
    print_consensus_summary(phase2_results)

    if output_json:
        # Aggregate scores and consensus
        scores = {n: r.get("score") for n, r in phase2_results.items() if isinstance(r.get("score"), (int, float))}
        avg_score = sum(scores.values()) / len(scores) if scores else None
        output = {
            "mode": "deliberate",
            "avg_score": round(avg_score, 1) if avg_score else None,
            "scores": scores,
            "phase1": phase1_results, "phase2": phase2_results,
            "elapsed_seconds": round(t3 - t0, 1),
        }
        print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")

    return phase2_results


# ── Walkthrough Mode Display & Logic ─────────────────────────────────────────

import re as _re


def split_into_sections(html: str) -> list[dict]:
    """Split HTML article into sections by h2/h3 tags."""
    # Split by h2/h3 headers
    parts = _re.split(r'(<h[23][^>]*>.*?</h[23]>)', html, flags=_re.DOTALL)

    sections = []
    current_title = "冒頭（リード文）"
    current_content = ""

    for part in parts:
        h_match = _re.match(r'<h[23][^>]*>(.*?)</h[23]>', part, _re.DOTALL)
        if h_match:
            # Save previous section
            if current_content.strip():
                # Strip HTML tags for preview
                plain = _re.sub(r'<[^>]+>', '', current_content).strip()
                char_count = len(plain)
                sections.append({
                    "id": len(sections) + 1,
                    "title": current_title,
                    "content": current_content.strip(),
                    "plain_preview": plain[:80],
                    "char_count": char_count,
                    "read_time_sec": max(1, char_count // 10),  # ~600 chars/min
                })
            current_title = _re.sub(r'<[^>]+>', '', h_match.group(1)).strip()
            current_content = ""
        else:
            current_content += part

    # Last section
    if current_content.strip():
        plain = _re.sub(r'<[^>]+>', '', current_content).strip()
        char_count = len(plain)
        sections.append({
            "id": len(sections) + 1,
            "title": current_title,
            "content": current_content.strip(),
            "plain_preview": plain[:80],
            "char_count": char_count,
            "read_time_sec": max(1, char_count // 10),
        })

    return sections


def print_walkthrough_result(name: str, result: dict, w_personas: dict):
    """Display walkthrough results with dropout visualization."""
    color = UNIT_COLORS[name]
    persona = w_personas[name]

    print(f"{color}{C.BOLD}┌─ {persona['name']} ─ {persona['reader_type']} ─{C.RESET}")

    sections = result.get("sections", [])
    for sec in sections:
        prob = sec.get("dropout_probability", 0)
        keep = sec.get("keep_reading", True)
        emotion = sec.get("emotion", "?")

        # Dropout bar visualization
        bar_len = prob // 5
        bar = "█" * bar_len + "░" * (20 - bar_len)
        prob_color = C.GREEN if prob < 30 else C.YELLOW if prob < 60 else C.RED

        status = f"{C.GREEN}→読む{C.RESET}" if keep else f"{C.RED}✗離脱{C.RESET}"
        preview = sec.get("section_preview", "")[:30]

        print(f"{color}│{C.RESET} S{sec.get('section_id', '?')}: {preview}")
        print(f"{color}│{C.RESET}   {prob_color}{bar} {prob}%{C.RESET} {status}  [{emotion}]")

        voice = sec.get("inner_voice", "")
        if voice:
            print(f"{color}│{C.RESET}   {C.DIM}💭 「{voice[:100]}」{C.RESET}")

        pains = sec.get("pain_points", [])
        for p in pains[:2]:
            print(f"{color}│{C.RESET}   {C.RED}⚡{C.RESET} {p[:80]}")

    # Final verdict
    dropout = result.get("final_dropout_point", "?")
    engagement = result.get("overall_engagement", "?")
    killer = result.get("killer_issue", "")

    eng_color = C.GREEN if isinstance(engagement, int) and engagement >= 70 else C.YELLOW if isinstance(engagement, int) and engagement >= 40 else C.RED
    print(f"{color}│{C.RESET}")
    print(f"{color}│{C.RESET} {C.BOLD}離脱ポイント: セクション {dropout}{C.RESET}")
    print(f"{color}│{C.RESET} {C.BOLD}エンゲージメント: {eng_color}{engagement}/100{C.RESET}")
    if killer:
        print(f"{color}│{C.RESET} {C.RED}致命的問題: {killer[:120]}{C.RESET}")

    print(f"{color}└{'─' * 50}{C.RESET}")
    print()


def print_walkthrough_consensus(phase2_results: dict, w_personas: dict):
    """Print walkthrough consensus summary."""
    print(f"\n{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}  ◆◆◆ MAGI WALKTHROUGH — 離脱分析レポート ◆◆◆{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}\n")

    # Collect retention scores and dropout points
    dropouts = {}
    retentions = {}
    for name, r in phase2_results.items():
        d = r.get("consensus_dropout_point")
        if isinstance(d, int):
            dropouts[name] = d
        ret = r.get("retention_score")
        if isinstance(ret, (int, float)):
            retentions[name] = ret

    if retentions:
        avg_ret = sum(retentions.values()) / len(retentions)
        ret_color = C.GREEN if avg_ret >= 70 else C.YELLOW if avg_ret >= 40 else C.RED
        parts = [f"{w_personas[n]['reader_type']}={int(v)}%" for n, v in retentions.items()]
        print(f"  {C.BOLD}平均リテンション: {ret_color}{avg_ret:.0f}%{C.RESET} ({', '.join(parts)})")

    if dropouts:
        avg_drop = sum(dropouts.values()) / len(dropouts)
        parts = [f"{w_personas[n]['reader_type']}=S{v}" for n, v in dropouts.items()]
        print(f"  {C.BOLD}平均離脱ポイント: セクション {avg_drop:.1f}{C.RESET} ({', '.join(parts)})")

    print()

    # Agreements and fixes
    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        r = phase2_results.get(name, {})
        color = UNIT_COLORS[name]

        agreements = r.get("agreements", [])
        for a in agreements[:2]:
            print(f"  {color}■{C.RESET} {a[:120]}")

        unique = r.get("my_unique_perspective", "")
        if unique:
            print(f"  {color}★{C.RESET} {C.DIM}[{w_personas[name]['reader_type']}独自] {unique[:120]}{C.RESET}")

        fix = r.get("top_fix", {})
        if fix and fix.get("fix"):
            print(f"  {C.BOLD}修正案:{C.RESET} [{fix.get('location', '?')}] {fix.get('fix', '')[:120]}")

    print(f"\n{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}")


def run_walkthrough(question: str, session: str, skip: list[str], output_json: bool, context: str = ""):
    """Walkthrough mode: persona-based dropout simulation."""
    session_context = SESSION_TYPES.get(session, SESSION_TYPES["general"])
    w_personas = get_walkthrough_personas(context)

    # Split article into sections
    sections = split_into_sections(question)
    if not sections:
        print(f"{C.RED}Error: Could not split article into sections{C.RESET}")
        return {}

    total_chars = sum(s.get("char_count", 0) for s in sections)
    total_time = sum(s.get("read_time_sec", 0) for s in sections)
    print(f"{C.BOLD}── 記事構成: {len(sections)}セクション / {total_chars}文字 / 読了{total_time // 60}分{total_time % 60}秒 ──{C.RESET}\n")
    for s in sections:
        print(f"  S{s['id']}: {s['title']} ({s.get('char_count', '?')}字 / {s.get('read_time_sec', '?')}秒)")
    print()

    # Format sections for the prompt
    sections_text = ""
    for s in sections:
        sections_text += f"\n--- Section {s['id']}: {s['title']} ---\n{s['content']}\n"

    print(f"{C.BOLD}── Phase 1: Persona Walkthrough ──{C.RESET}\n")
    t0 = time.time()

    phase1_prompts = {}
    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in skip:
            continue
        persona = w_personas[name]
        sys_prompt = (
            persona["reader_prompt"] + "\n\n"
            + session_context + "\n\n"
            + WALKTHROUGH_OUTPUT_FORMAT
        )
        phase1_prompts[name] = (sys_prompt, sections_text)

    phase1_results = call_all_parallel(phase1_prompts, skip)
    t1 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase1_results:
            print_walkthrough_result(name, phase1_results[name], w_personas)
    print(f"{C.DIM}  Phase 1 completed in {t1 - t0:.1f}s{C.RESET}\n")

    # Phase 2: Cross-review
    print(f"{C.BOLD}── Phase 2: Consensus ──{C.RESET}\n")
    t2 = time.time()

    phase2_prompts = {}
    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in skip or name not in phase1_results:
            continue
        persona = w_personas[name]
        others = []
        for other_name, other_result in phase1_results.items():
            if other_name == name:
                continue
            other_p = w_personas[other_name]
            others.append(
                f"[{other_p['name']} ({other_p['reader_type']})]:\n"
                f"{json.dumps(other_result, ensure_ascii=False, indent=2)}"
            )
        other_text = "\n\n".join(others)
        sys_prompt = persona["reader_prompt"] + "\n\n" + session_context
        user_msg = (
            f"Article sections:\n{sections_text}\n\n"
            f"Your walkthrough result:\n{json.dumps(phase1_results[name], ensure_ascii=False)}\n\n"
            + WALKTHROUGH_CROSS_REVIEW.format(other_opinions=other_text)
        )
        phase2_prompts[name] = (sys_prompt, user_msg)

    phase2_results = call_all_parallel(phase2_prompts, skip)
    t3 = time.time()

    # Display Phase 2 briefly
    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase2_results:
            r = phase2_results[name]
            color = UNIT_COLORS[name]
            ret = r.get("retention_score", "?")
            dropout = r.get("consensus_dropout_point", "?")
            print(f"{color}{C.BOLD}{w_personas[name]['reader_type']}{C.RESET}: リテンション {ret}%, 合意離脱 S{dropout}")

    print(f"\n{C.DIM}  Phase 2 completed in {t3 - t2:.1f}s{C.RESET}\n")

    print_walkthrough_consensus(phase2_results, w_personas)

    if output_json:
        # Aggregate retention and dropout
        retentions = {n: r.get("retention_score") for n, r in phase2_results.items() if isinstance(r.get("retention_score"), (int, float))}
        dropouts = {n: r.get("consensus_dropout_point") for n, r in phase2_results.items() if isinstance(r.get("consensus_dropout_point"), int)}
        avg_retention = sum(retentions.values()) / len(retentions) if retentions else None
        output = {
            "mode": "walkthrough",
            "avg_retention": round(avg_retention, 1) if avg_retention else None,
            "retentions": retentions,
            "dropouts": dropouts,
            "total_chars": sum(s.get("char_count", 0) for s in sections),
            "total_read_time_sec": sum(s.get("read_time_sec", 0) for s in sections),
            "sections": [{"id": s["id"], "title": s["title"], "char_count": s.get("char_count", 0)} for s in sections],
            "phase1": phase1_results, "phase2": phase2_results,
            "elapsed_seconds": round(t3 - t0, 1),
        }
        print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")

    return phase2_results


# ── Main ─────────────────────────────────────────────────────────────────────

def run_magi(question: str, session: str = "general", mode: str = "deliberate",
             skip: list[str] | None = None, output_json: bool = False, context: str = ""):
    skip = skip or []
    print_header(mode)
    print(f"{C.BOLD}━━ Input ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{C.RESET}")
    display_q = question if len(question) < 500 else question[:200] + f"\n  ... ({len(question)} chars total)"
    print(f"  {display_q}")
    print(f"{C.DIM}  Session: {session} | Mode: {mode}{C.RESET}")
    print(f"{C.BOLD}{'━' * 52}{C.RESET}\n")

    if mode == "judge":
        return run_judge(question, session, skip, output_json)
    elif mode == "walkthrough":
        return run_walkthrough(question, session, skip, output_json, context=context)
    else:
        return run_deliberate(question, session, skip, output_json)


def main():
    parser = argparse.ArgumentParser(description="MAGI System — Three-way AI Deliberation")
    parser.add_argument("question", nargs="?", default="", help="Question or topic to deliberate")
    parser.add_argument("--mode", "-m", default="deliberate",
                        choices=["judge", "deliberate", "walkthrough"],
                        help="Mode: judge (vote), deliberate (improve), or walkthrough (dropout sim) (default: deliberate)")
    parser.add_argument("--session", "-s", default="general",
                        choices=list(SESSION_TYPES.keys()),
                        help="Session type (default: general)")
    parser.add_argument("--file", "-f", type=str, help="Read question/content from file")
    parser.add_argument("--stdin", action="store_true", help="Read from stdin")
    parser.add_argument("--json", action="store_true", help="Output full results as JSON")
    parser.add_argument("--skip", type=str, help="Skip unit (comma-separated: MELCHIOR,BALTHASAR,CASPER)")
    parser.add_argument("--context", "-c", type=str, default="",
                        help="Additional context (e.g. target audience, article goals)")
    args = parser.parse_args()

    question = args.question
    if args.file:
        question = Path(args.file).read_text(encoding="utf-8")
    elif args.stdin:
        question = sys.stdin.read()

    if not question.strip():
        parser.error("No question provided. Use positional arg, --file, or --stdin.")

    # Prepend context if given
    if args.context:
        question = f"[Context: {args.context}]\n\n{question}"

    skip = [s.strip().upper() for s in args.skip.split(",")] if args.skip else []
    run_magi(question, session=args.session, mode=args.mode, skip=skip,
             output_json=args.json, context=args.context)


if __name__ == "__main__":
    main()
