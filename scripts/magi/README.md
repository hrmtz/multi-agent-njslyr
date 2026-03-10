# MAGI System — Three-way AI Deliberation

3つの異なるAI（Claude / GPT / Gemini）に同一の議題を並列で分析させ、クロスレビューで合意形成する審議システム。

## Architecture

```
              ┌─────────────────────────────────────────────┐
              │              MAGI System                     │
              │                                             │
  Question ──►│  Phase 1: Independent Analysis (parallel)   │
              │    ┌───────────┬───────────┬───────────┐    │
              │    │ MELCHIOR  │ BALTHASAR │  CASPER   │    │
              │    │ Claude    │ GPT       │ Gemini    │    │
              │    │ 科学者     │ 実用主義者  │ ビジョナリー│    │
              │    └─────┬─────┴─────┬─────┴─────┬─────┘    │
              │          │           │           │          │
              │  Phase 2: Cross-Review (each reviews others)│
              │    ┌─────▼─────┬─────▼─────┬─────▼─────┐    │
              │    │ Revised   │ Revised   │ Revised   │    │
              │    │ opinion   │ opinion   │ opinion   │    │
              │    └─────┬─────┴─────┬─────┴─────┬─────┘    │
              │          └───────────┼───────────┘          │
              │                      ▼                      │
              │             Consensus Summary               │
              └─────────────────────────────────────────────┘
```

## Units

| Unit | Model | Perspective | Role |
|------|-------|-------------|------|
| MELCHIOR-1 | Claude Sonnet 5 | 科学者 | 論理・正確性・エビデンス重視。データ不足なら「不足」と言う |
| BALTHASAR-2 | GPT-5.2 | 実用主義者 | 実用性・UX・現実世界での実行可能性重視 |
| CASPER-3 | Gemini 3 Pro | ビジョナリー | 直感・創造性・見落とされたリスクと機会の発見 |

モデル設定は `core/models.py` の `MODEL_CONFIG` に一元管理。

## Modes

### judge — 承認/却下投票
```bash
python3 scripts/magi/magi.py --mode judge "Should we deploy feature X?"
```
各ユニットが `approve` / `reject` / `conditional_approve` で投票。Phase 2で他ユニットの意見を見て修正可能。

### deliberate — 改善提案（デフォルト）
```bash
python3 scripts/magi/magi.py --mode deliberate --session article_review --file article.html
```
スコアリング + 具体的改善提案 + リライト例を生成。Phase 2で合意形成し `consensus_plan` を出力。

### walkthrough — 読者離脱シミュレーション
```bash
python3 scripts/magi/magi.py --mode walkthrough --file article.html --context "メンズ鼻整形"
```
3つの読者ペルソナ（慎重型/衝動型/懐疑型）が記事を読み進め、セクションごとの離脱確率・感情・内心の声を出力。`--context` に男性系キーワードがあれば男性ペルソナに自動切替。

## Session Types

| Session | Use Case |
|---------|----------|
| `general` | 汎用的な質問・戦略判断 |
| `article_review` | ブログ記事のSEO・医療正確性・読者エンゲージメント評価 |
| `strategy` | 経営・技術戦略の意思決定 |
| `code_review` | コードの正確性・セキュリティ・保守性レビュー |

## Usage

```bash
# Basic question
python3 scripts/magi/magi.py "Is this architecture decision sound?"

# Article review with file input
python3 scripts/magi/magi.py --mode deliberate --session article_review --file article.html

# Skip a unit (e.g. API key unavailable)
python3 scripts/magi/magi.py --skip MELCHIOR "Evaluate this strategy"

# JSON output for programmatic use
python3 scripts/magi/magi.py --json --mode deliberate --file content.html

# Stdin input
cat article.html | python3 scripts/magi/magi.py --stdin --mode walkthrough

# Custom output directory
python3 scripts/magi/magi.py --output-dir results/sprint42/ --file review_target.html
```

### Options

| Flag | Description |
|------|-------------|
| `--mode`, `-m` | `judge` / `deliberate` / `walkthrough` (default: `deliberate`) |
| `--session`, `-s` | `general` / `article_review` / `strategy` / `code_review` |
| `--file`, `-f` | Read input from file |
| `--stdin` | Read input from stdin |
| `--json` | Output raw JSON results |
| `--skip` | Skip unit(s), comma-separated: `MELCHIOR,BALTHASAR,CASPER` |
| `--context`, `-c` | Additional context (audience, goals, etc.) |
| `--profile` | `fast` / `balanced` / `deep` (default: `balanced`, stub) |
| `--output-dir` | Result save directory (default: `results/`) |

## Directory Structure

```
scripts/magi/
├── magi.py                  # Backward-compatible entry point (wrapper)
├── cli.py                   # CLI entrypoint (argparse + orchestration)
├── models.py                # Legacy location (imports from core/)
├── prompts.py               # Legacy location (imports from core/)
├── core/
│   ├── orchestrator.py      # run_judge / run_deliberate / run_walkthrough
│   ├── models.py            # MODEL_CONFIG, API callers, call_all_parallel
│   ├── prompts.py           # Personas, session types, output format templates
│   ├── schemas.py           # JSON schema definitions + validation
│   └── utils.py             # JSON extraction, section splitting, deduplication
├── adapters/
│   └── monju_adapter.py     # MAGI result → YAML task conversion
├── sessions/                # Session definitions (future expansion)
├── results/                 # Saved deliberation results
├── apply_magi_rewrites.py   # Apply rewrite suggestions from results
├── run_m_articles.sh        # Batch article review runner
└── run_m_walkthrough.sh     # Batch walkthrough runner
```

## Key Design Decisions

- **SDK-free**: All API calls via raw REST (`requests`). No anthropic/openai/google SDK dependencies.
- **Fail-fast on missing keys**: API key not set → immediate `ValueError`. No silent abstain.
- **2-body minimum**: `call_all_parallel` raises `RuntimeError` if fewer than 2 units return valid responses. 1 unit abstaining (or `--skip`) is OK; 2+ abstaining halts execution.
- **Exponential backoff**: Retries on 429/502/503/ConnectionError with `delay * 2^attempt`.
- **Cross-review compression**: Phase 2 receives summarized (not full) Phase 1 results — score + high-severity issues + best rewrite only.
- **Deduplication**: `consensus_plan` items are deduplicated by Jaccard similarity (threshold 0.7), not naive prefix matching.

## Environment

Required env vars (loaded from `config/api_keys.env`):
- `ANTHROPIC_API_KEY` — for MELCHIOR (Claude)
- `OPENAI_API_KEY` — for BALTHASAR (GPT)
- `GEMINI_API_KEY` — for CASPER (Gemini)

Use `--skip` to run with fewer than 3 keys available.

## Monju Adapter

`adapters/monju_adapter.py` converts MAGI deliberation results into YAML task format compatible with the multi-agent queue system. This bridges MAGI analysis output to actionable work items for the agent fleet.

```python
from adapters.monju_adapter import magi_to_tasks

tasks = magi_to_tasks(result, article_id="article_45")
```
