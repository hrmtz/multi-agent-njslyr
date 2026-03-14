"""
MAGI System — Core orchestration logic.

run_judge / run_deliberate / run_walkthrough + ANSI display functions.
"""

import json
import time
from datetime import datetime
from pathlib import Path

from core.models import call_all_parallel, MODEL_CONFIG
from core.prompts import (
    PERSONAS, SESSION_TYPES,
    JUDGE_OUTPUT_FORMAT, JUDGE_CROSS_REVIEW,
    DELIBERATE_OUTPUT_FORMAT, DELIBERATE_CROSS_REVIEW,
    WALKTHROUGH_OUTPUT_FORMAT, WALKTHROUGH_CROSS_REVIEW,
    get_walkthrough_personas,
)
from core.utils import _summarize_for_crossreview, _jaccard_similarity, split_into_sections


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


def _save_result(output: dict, output_dir: str, session: str, mode: str) -> None:
    """Save MAGI result JSON to output_dir/{session}_{mode}_{timestamp}.json"""
    out_path = Path(output_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    fname = out_path / f"{session}_{mode}_{ts}.json"
    with open(fname, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)
    print(f"{C.DIM}Result saved: {fname}{C.RESET}")


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

    model_label = MODEL_CONFIG.get(name, {}).get("label", persona.get("model_label", "?"))
    print(f"{color}{C.BOLD}┌─ {persona['name']} ({model_label}) ─ {persona['perspective']} ─{C.RESET}")
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
    model_label = MODEL_CONFIG.get(name, {}).get("label", persona.get("model_label", "?"))
    print(f"{color}{C.BOLD}┌─ {persona['name']} ({model_label}) ─ {persona['perspective']} ─{C.RESET}")
    print(f"{color}│{C.RESET} Score: {score_color}{C.BOLD}{score}/100{C.RESET}")

    if phase == 1:
        strengths = result.get("strengths", [])
        if strengths:
            print(f"{color}│{C.RESET} {C.GREEN}✓ 強み:{C.RESET}")
            for s in strengths[:3]:
                print(f"{color}│{C.RESET}   {C.GREEN}•{C.RESET} {s}")

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
        for a in result.get("agreements", [])[:2]:
            print(f"{color}│{C.RESET} {C.GREEN}✓ 同意:{C.RESET} {a[:100]}")
        for d in result.get("disagreements", [])[:2]:
            print(f"{color}│{C.RESET} {C.RED}✗ 反論:{C.RESET} {d[:100]}")
        for m in result.get("missed_issues", [])[:2]:
            print(f"{color}│{C.RESET} {C.YELLOW}+ 追加:{C.RESET} {m[:100]}")

        plan = result.get("consensus_plan", [])
        if plan:
            print(f"{color}│{C.RESET} {C.BOLD}◆ 改善プラン:{C.RESET}")
            for item in plan[:5]:
                p = item.get("priority", "?")
                print(f"{color}│{C.RESET}   {C.BOLD}P{p}:{C.RESET} {item.get('action', '')[:100]}")
                print(f"{color}│{C.RESET}   {C.DIM}   効果: {item.get('expected_impact', '')[:80]}{C.RESET}")

        best = result.get("best_rewrite", {})
        if best and best.get("improved"):
            print(f"{color}│{C.RESET} {C.BLUE}★ ベストリライト:{C.RESET}")
            print(f"{color}│{C.RESET}   {C.RED}Before:{C.RESET} {best.get('original', '')[:80]}")
            print(f"{color}│{C.RESET}   {C.GREEN}After:{C.RESET}  {best.get('improved', '')[:80]}")

    print(f"{color}└{'─' * 50}{C.RESET}")
    print()


def print_consensus_summary(phase2_results: dict[str, dict], dedup_threshold: float = 0.7):
    print(f"\n{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}  ◆◆◆ MAGI CONSENSUS — 改善アクションプラン ◆◆◆{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}\n")

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

    all_actions = []
    for name, r in phase2_results.items():
        for item in r.get("consensus_plan", []):
            all_actions.append({
                "from": PERSONAS[name]["name"],
                "priority": item.get("priority", 99),
                "action": item.get("action", ""),
                "impact": item.get("expected_impact", ""),
            })

    all_actions.sort(key=lambda x: x["priority"])

    seen_actions = []
    unique = []
    for a in all_actions:
        is_dup = any(_jaccard_similarity(a["action"], s) >= dedup_threshold for s in seen_actions)
        if not is_dup:
            seen_actions.append(a["action"])
            unique.append(a)

    if unique:
        for i, a in enumerate(unique[:7], 1):
            print(f"  {C.BOLD}{i}.{C.RESET} {a['action']}")
            print(f"     {C.DIM}効果: {a['impact']} (by {a['from']}){C.RESET}")
            print()

    print(f"  {C.BOLD}{C.BLUE}── ベストリライト提案 ──{C.RESET}\n")
    for name, r in phase2_results.items():
        best = r.get("best_rewrite", {})
        if best and best.get("improved"):
            print(f"  {UNIT_COLORS[name]}{PERSONAS[name]['name']}:{C.RESET}")
            print(f"    {C.RED}Before:{C.RESET} {best.get('original', '')[:120]}")
            print(f"    {C.GREEN}After:{C.RESET}  {best.get('improved', '')[:120]}")
            print()

    print(f"{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}")


# ── Walkthrough Mode Display ─────────────────────────────────────────────────

def print_walkthrough_result(name: str, result: dict, w_personas: dict):
    color = UNIT_COLORS[name]
    persona = w_personas[name]

    print(f"{color}{C.BOLD}┌─ {persona['name']} ─ {persona['reader_type']} ─{C.RESET}")

    sections = result.get("sections", [])
    for sec in sections:
        prob = sec.get("dropout_probability", 0)
        keep = sec.get("keep_reading", True)
        emotion = sec.get("emotion", "?")

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
    print(f"\n{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}  ◆◆◆ MAGI WALKTHROUGH — 離脱分析レポート ◆◆◆{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}{'═' * 52}{C.RESET}\n")

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


# ── Run Functions ────────────────────────────────────────────────────────────

def run_judge(
    question: str,
    session: str,
    skip: list[str],
    output_json: bool,
    output_dir: str = "results/",
    personas: dict | None = None,
    profile: str = "balanced",
) -> tuple[str, dict]:
    """Judge mode: approve/reject voting."""
    _personas = personas or PERSONAS
    session_context = SESSION_TYPES.get(session, SESSION_TYPES["general"])

    print(f"{C.BOLD}── Phase 1: Initial Deliberation ──{C.RESET}\n")
    t0 = time.time()

    phase1_prompts = {}
    for name, persona in _personas.items():
        if name in skip:
            continue
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context + JUDGE_OUTPUT_FORMAT
        phase1_prompts[name] = (sys_prompt, question)

    phase1_results = call_all_parallel(phase1_prompts, skip, mode="judge", session=session)
    t1 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase1_results:
            print_judge_result(name, phase1_results[name])
    print(f"{C.DIM}  Phase 1 completed in {t1 - t0:.1f}s{C.RESET}\n")

    # ── Fast profile: skip Phase 2 entirely ──
    if profile == "fast":
        print(f"{C.DIM}  [fast profile] Skipping Phase 2 cross-review{C.RESET}\n")
        decision, detail = aggregate_votes(phase1_results)
        print_decision(decision, detail)
        output = {
            "mode": "judge", "session": session, "decision": decision, "detail": detail,
            "profile": profile,
            "phase1": phase1_results, "phase2": None,
            "elapsed_seconds": round(t1 - t0, 1),
        }
        if output_json:
            print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")
        if output_dir:
            _save_result(output, output_dir, session, "judge")
        return decision, phase1_results

    if profile == "deep":
        print(f"{C.YELLOW}⚠ Deep profile: full cross-review — higher token cost{C.RESET}")

    print(f"{C.BOLD}── Phase 2: Cross-Review ──{C.RESET}\n")
    t2 = time.time()

    phase2_prompts = {}
    for name, persona in _personas.items():
        if name in skip or name not in phase1_results:
            continue
        others = []
        for other_name, other_result in phase1_results.items():
            if other_name == name:
                continue
            other_persona = _personas[other_name]
            if profile == "deep":
                other_summary = json.dumps(other_result, ensure_ascii=False)
            else:
                other_summary = _summarize_for_crossreview(other_result, "judge")
            others.append(
                f"[{other_persona['name']} ({other_persona['perspective']})] "
                + other_summary
            )
        other_text = "\n\n".join(others)
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context
        user_msg = (
            f"Original question:\n{question}\n\n"
            f"Your initial assessment:\n{json.dumps(phase1_results[name], ensure_ascii=False)}\n\n"
            + JUDGE_CROSS_REVIEW.format(other_opinions=other_text)
        )
        phase2_prompts[name] = (sys_prompt, user_msg)

    phase2_results = call_all_parallel(phase2_prompts, skip, mode="judge", session=session)
    t3 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase2_results:
            print_judge_result(name, phase2_results[name])
    print(f"{C.DIM}  Phase 2 completed in {t3 - t2:.1f}s{C.RESET}\n")

    decision, detail = aggregate_votes(phase2_results)
    print_decision(decision, detail)

    output = {
        "mode": "judge", "session": session, "decision": decision, "detail": detail,
        "profile": profile,
        "phase1": phase1_results, "phase2": phase2_results,
        "elapsed_seconds": round(t3 - t0, 1),
    }
    if output_json:
        print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")
    if output_dir:
        _save_result(output, output_dir, session, "judge")

    return decision, phase2_results


def run_deliberate(
    question: str,
    session: str,
    skip: list[str],
    output_json: bool,
    output_dir: str = "results/",
    personas: dict | None = None,
    dedup_threshold: float = 0.7,
    profile: str = "balanced",
) -> dict:
    """Deliberate mode: discussion producing actionable improvements."""
    _personas = personas or PERSONAS
    session_context = SESSION_TYPES.get(session, SESSION_TYPES["general"])

    print(f"{C.BOLD}── Phase 1: Individual Analysis ──{C.RESET}\n")
    t0 = time.time()

    phase1_prompts = {}
    for name, persona in _personas.items():
        if name in skip:
            continue
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context + DELIBERATE_OUTPUT_FORMAT
        phase1_prompts[name] = (sys_prompt, question)

    phase1_results = call_all_parallel(phase1_prompts, skip, mode="deliberate", session=session)
    t1 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase1_results:
            print_deliberate_result(name, phase1_results[name], phase=1)
    print(f"{C.DIM}  Phase 1 completed in {t1 - t0:.1f}s{C.RESET}\n")

    # ── Fast profile: skip Phase 2 entirely ──
    if profile == "fast":
        print(f"{C.DIM}  [fast profile] Skipping Phase 2 cross-review{C.RESET}\n")
        print_consensus_summary(phase1_results, dedup_threshold=dedup_threshold)
        scores = {n: r.get("score") for n, r in phase1_results.items() if isinstance(r.get("score"), (int, float))}
        avg_score = sum(scores.values()) / len(scores) if scores else None
        output = {
            "mode": "deliberate",
            "session": session,
            "avg_score": round(avg_score, 1) if avg_score else None,
            "scores": scores,
            "profile": profile,
            "phase1": phase1_results, "phase2": None,
            "elapsed_seconds": round(t1 - t0, 1),
        }
        if output_json:
            print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")
        if output_dir:
            _save_result(output, output_dir, session, "deliberate")
        return phase1_results

    if profile == "deep":
        print(f"{C.YELLOW}⚠ Deep profile: full cross-review — higher token cost{C.RESET}")

    print(f"{C.BOLD}── Phase 2: Cross-Review & Consensus ──{C.RESET}\n")
    t2 = time.time()

    phase2_prompts = {}
    for name, persona in _personas.items():
        if name in skip or name not in phase1_results:
            continue
        others = []
        for other_name, other_result in phase1_results.items():
            if other_name == name:
                continue
            other_persona = _personas[other_name]
            if profile == "deep":
                other_summary = json.dumps(other_result, ensure_ascii=False)
            else:
                other_summary = _summarize_for_crossreview(other_result, "deliberate")
            others.append(
                f"[{other_persona['name']} ({other_persona['perspective']})]:\n"
                + other_summary
            )
        other_text = "\n\n".join(others)
        sys_prompt = persona["system_prompt"] + "\n\n" + session_context
        user_msg = (
            f"Original content:\n{question}\n\n"
            f"Your initial analysis:\n{json.dumps(phase1_results[name], ensure_ascii=False)}\n\n"
            + DELIBERATE_CROSS_REVIEW.format(other_opinions=other_text)
        )
        phase2_prompts[name] = (sys_prompt, user_msg)

    phase2_results = call_all_parallel(phase2_prompts, skip, mode="deliberate", session=session)
    t3 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase2_results:
            print_deliberate_result(name, phase2_results[name], phase=2)
    print(f"{C.DIM}  Phase 2 completed in {t3 - t2:.1f}s{C.RESET}\n")

    print_consensus_summary(phase2_results, dedup_threshold=dedup_threshold)

    scores = {n: r.get("score") for n, r in phase2_results.items() if isinstance(r.get("score"), (int, float))}
    avg_score = sum(scores.values()) / len(scores) if scores else None
    output = {
        "mode": "deliberate",
        "session": session,
        "avg_score": round(avg_score, 1) if avg_score else None,
        "scores": scores,
        "profile": profile,
        "phase1": phase1_results, "phase2": phase2_results,
        "elapsed_seconds": round(t3 - t0, 1),
    }
    if output_json:
        print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")
    if output_dir:
        _save_result(output, output_dir, session, "deliberate")

    return phase2_results


def run_walkthrough(
    question: str,
    session: str,
    skip: list[str],
    output_json: bool,
    context: str = "",
    output_dir: str = "results/",
    personas: dict | None = None,
    profile: str = "balanced",
) -> dict:
    """Walkthrough mode: persona-based dropout simulation."""
    session_context = SESSION_TYPES.get(session, SESSION_TYPES["general"])
    w_personas = get_walkthrough_personas(context)

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

    phase1_results = call_all_parallel(phase1_prompts, skip, mode="walkthrough", session=session)
    t1 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase1_results:
            print_walkthrough_result(name, phase1_results[name], w_personas)
    print(f"{C.DIM}  Phase 1 completed in {t1 - t0:.1f}s{C.RESET}\n")

    # ── Fast profile: skip Phase 2 entirely ──
    if profile == "fast":
        print(f"{C.DIM}  [fast profile] Skipping Phase 2 cross-review{C.RESET}\n")
        # Compute summary from Phase 1 results directly
        retentions = {n: r.get("overall_engagement") for n, r in phase1_results.items() if isinstance(r.get("overall_engagement"), (int, float))}
        dropouts = {n: r.get("final_dropout_point") for n, r in phase1_results.items() if isinstance(r.get("final_dropout_point"), int)}
        avg_retention = sum(retentions.values()) / len(retentions) if retentions else None
        output = {
            "mode": "walkthrough",
            "session": session,
            "avg_retention": round(avg_retention, 1) if avg_retention else None,
            "retentions": retentions,
            "dropouts": dropouts,
            "total_chars": total_chars,
            "total_read_time_sec": total_time,
            "sections": [{"id": s["id"], "title": s["title"], "char_count": s.get("char_count", 0)} for s in sections],
            "profile": profile,
            "phase1": phase1_results, "phase2": None,
            "elapsed_seconds": round(t1 - t0, 1),
        }
        if output_json:
            print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")
        if output_dir:
            _save_result(output, output_dir, session, "walkthrough")
        return phase1_results

    if profile == "deep":
        print(f"{C.YELLOW}⚠ Deep profile: full cross-review — higher token cost{C.RESET}")

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
            if profile == "deep":
                other_summary = json.dumps(other_result, ensure_ascii=False)
            else:
                other_summary = _summarize_for_crossreview(other_result, "walkthrough")
            others.append(
                f"[{other_p['name']} ({other_p['reader_type']})]:\n"
                + other_summary
            )
        other_text = "\n\n".join(others)
        sys_prompt = persona["reader_prompt"] + "\n\n" + session_context
        user_msg = (
            f"Article sections:\n{sections_text}\n\n"
            f"Your walkthrough result:\n{json.dumps(phase1_results[name], ensure_ascii=False)}\n\n"
            + WALKTHROUGH_CROSS_REVIEW.format(other_opinions=other_text)
        )
        phase2_prompts[name] = (sys_prompt, user_msg)

    phase2_results = call_all_parallel(phase2_prompts, skip, mode="walkthrough", session=session)
    t3 = time.time()

    for name in ["MELCHIOR", "BALTHASAR", "CASPER"]:
        if name in phase2_results:
            r = phase2_results[name]
            color = UNIT_COLORS[name]
            ret = r.get("retention_score", "?")
            dropout = r.get("consensus_dropout_point", "?")
            print(f"{color}{C.BOLD}{w_personas[name]['reader_type']}{C.RESET}: リテンション {ret}%, 合意離脱 S{dropout}")

    print(f"\n{C.DIM}  Phase 2 completed in {t3 - t2:.1f}s{C.RESET}\n")

    print_walkthrough_consensus(phase2_results, w_personas)

    retentions = {n: r.get("retention_score") for n, r in phase2_results.items() if isinstance(r.get("retention_score"), (int, float))}
    dropouts = {n: r.get("consensus_dropout_point") for n, r in phase2_results.items() if isinstance(r.get("consensus_dropout_point"), int)}
    avg_retention = sum(retentions.values()) / len(retentions) if retentions else None
    output = {
        "mode": "walkthrough",
        "session": session,
        "avg_retention": round(avg_retention, 1) if avg_retention else None,
        "retentions": retentions,
        "dropouts": dropouts,
        "total_chars": total_chars,
        "total_read_time_sec": total_time,
        "sections": [{"id": s["id"], "title": s["title"], "char_count": s.get("char_count", 0)} for s in sections],
        "profile": profile,
        "phase1": phase1_results, "phase2": phase2_results,
        "elapsed_seconds": round(t3 - t0, 1),
    }
    if output_json:
        print(f"\n{json.dumps(output, ensure_ascii=False, indent=2)}")
    if output_dir:
        _save_result(output, output_dir, session, "walkthrough")

    return phase2_results


# ── Top-level entry ──────────────────────────────────────────────────────────

def run_magi(
    question: str,
    session: str = "general",
    mode: str = "deliberate",
    skip: list[str] | None = None,
    output_json: bool = False,
    context: str = "",
    output_dir: str = "results/",
    profile: str = "balanced",
    personas: dict | None = None,
    dedup_threshold: float = 0.7,
):
    """Run MAGI deliberation.

    Args:
        profile: 'fast' (Phase 1 only) | 'balanced' (default, summarized cross-review) | 'deep' (full cross-review).
        output_dir: directory to save results (used by --output-dir CLI arg).
    """
    if profile not in ("fast", "balanced", "deep"):
        raise ValueError(f"Invalid profile: {profile!r}. Must be 'fast', 'balanced', or 'deep'.")
    skip = skip or []
    print_header(mode)
    print(f"{C.BOLD}━━ Input ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{C.RESET}")
    display_q = question if len(question) < 500 else question[:200] + f"\n  ... ({len(question)} chars total)"
    print(f"  {display_q}")
    print(f"{C.DIM}  Session: {session} | Mode: {mode} | Profile: {profile}{C.RESET}")
    print(f"{C.BOLD}{'━' * 52}{C.RESET}\n")

    if mode == "judge":
        return run_judge(question, session, skip, output_json, output_dir=output_dir, personas=personas, profile=profile)
    elif mode == "walkthrough":
        return run_walkthrough(question, session, skip, output_json, context=context, output_dir=output_dir, personas=personas, profile=profile)
    else:
        return run_deliberate(question, session, skip, output_json, output_dir=output_dir, personas=personas, dedup_threshold=dedup_threshold, profile=profile)
