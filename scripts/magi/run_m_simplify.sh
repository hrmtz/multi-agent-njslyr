#!/usr/bin/env bash
# run_m_simplify.sh — MAGI-powered code review (simplify mode)
#
# Usage:
#   bash run_m_simplify.sh                          # review uncommitted changes
#   bash run_m_simplify.sh HEAD~5 HEAD              # review last 5 commits
#   bash run_m_simplify.sh main feature-branch      # review branch diff
#   bash run_m_simplify.sh --file findings.json     # review pre-collected findings
#   bash run_m_simplify.sh --auto-cmd               # also generate cmd YAML via monju_adapter
#
# Pipes git diff output through MAGI deliberate mode with simplify session.
# Each model reviews from a different perspective:
#   MELCHIOR = code reuse, BALTHASAR = code quality, CASPER = efficiency
#
# With --auto-cmd:
#   1. Runs MAGI with --json and captures output to reel/magi_simplify_latest.json
#   2. Passes JSON to monju_adapter to generate task YAMLs in queue/tasks/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR%/scripts/magi}"

# Default: diff of uncommitted + staged changes
FROM_REF=""
TO_REF=""
FILE_INPUT=""
AUTO_CMD=false
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            FILE_INPUT="$2"
            shift 2
            ;;
        --json)
            EXTRA_ARGS+=(--json)
            shift
            ;;
        --skip)
            EXTRA_ARGS+=(--skip "$2")
            shift 2
            ;;
        --no-skip-melchior)
            EXTRA_ARGS=()
            shift
            ;;
        --output-dir)
            EXTRA_ARGS+=(--output-dir "$2")
            shift 2
            ;;
        --auto-cmd)
            AUTO_CMD=true
            shift
            ;;
        *)
            if [[ -z "$FROM_REF" ]]; then
                FROM_REF="$1"
            elif [[ -z "$TO_REF" ]]; then
                TO_REF="$1"
            fi
            shift
            ;;
    esac
done

# Build the input content
if [[ -n "$FILE_INPUT" ]]; then
    if [[ ! -f "$FILE_INPUT" ]]; then
        echo "Error: File not found: $FILE_INPUT" >&2
        exit 1
    fi
    INPUT=$(cat "$FILE_INPUT")
    echo "Reading findings from: $FILE_INPUT"
elif [[ -n "$FROM_REF" && -n "$TO_REF" ]]; then
    INPUT=$(cd "$PROJECT_ROOT" && git diff "$FROM_REF" "$TO_REF" 2>/dev/null)
    STAT=$(cd "$PROJECT_ROOT" && git diff --shortstat "$FROM_REF" "$TO_REF" 2>/dev/null)
    echo "Reviewing diff: $FROM_REF..$TO_REF ($STAT)"
elif [[ -n "$FROM_REF" ]]; then
    INPUT=$(cd "$PROJECT_ROOT" && git diff "$FROM_REF" 2>/dev/null)
    STAT=$(cd "$PROJECT_ROOT" && git diff --shortstat "$FROM_REF" 2>/dev/null)
    echo "Reviewing diff from: $FROM_REF ($STAT)"
else
    INPUT=$(cd "$PROJECT_ROOT" && git diff HEAD 2>/dev/null)
    if [[ -z "$INPUT" ]]; then
        INPUT=$(cd "$PROJECT_ROOT" && git diff HEAD~1 HEAD 2>/dev/null)
        STAT=$(cd "$PROJECT_ROOT" && git diff --shortstat HEAD~1 HEAD 2>/dev/null)
        echo "Reviewing last commit ($STAT)"
    else
        STAT=$(cd "$PROJECT_ROOT" && git diff --shortstat HEAD 2>/dev/null)
        echo "Reviewing uncommitted changes ($STAT)"
    fi
fi

if [[ -z "$INPUT" ]]; then
    echo "No changes to review." >&2
    exit 0
fi

# Truncate if too large (API token limits)
CHAR_COUNT=${#INPUT}
MAX_CHARS=80000
if [[ $CHAR_COUNT -gt $MAX_CHARS ]]; then
    echo "Diff too large (${CHAR_COUNT} chars). Truncating to ${MAX_CHARS} chars."
    INPUT="${INPUT:0:$MAX_CHARS}

... [TRUNCATED — ${CHAR_COUNT} total chars, showing first ${MAX_CHARS}]"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ "$AUTO_CMD" == "true" ]]; then
    # --auto-cmd: capture JSON output, then generate task YAMLs via monju_adapter
    REEL_DIR="$PROJECT_ROOT/reel"
    mkdir -p "$REEL_DIR"
    RESULT_JSON="$REEL_DIR/magi_simplify_latest.json"

    echo "Running MAGI with --json (auto-cmd mode)..."
    echo ""

    MAGI_OUTPUT=$(echo "$INPUT" | python3 "$SCRIPT_DIR/cli.py" \
        --mode deliberate \
        --session simplify \
        --stdin \
        --json \
        "${EXTRA_ARGS[@]}" | tee /dev/stderr)

    # Extract JSON block sequentially (no race condition)
    echo "$MAGI_OUTPUT" | python3 -c "
import sys, json, re
out_path = sys.argv[1]
content = sys.stdin.read()
# Find the last JSON object in the output
matches = list(re.finditer(r'\{', content))
for m in reversed(matches):
    try:
        data = json.loads(content[m.start():])
        if 'phase1' in data or 'phase2' in data:
            with open(out_path, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            print(f'Saved MAGI result to: {out_path}', file=sys.stderr)
            break
    except (json.JSONDecodeError, ValueError):
        continue
" "$RESULT_JSON"

    if [[ -f "$RESULT_JSON" ]] && python3 -c "import json; json.load(open('$RESULT_JSON'))" 2>/dev/null; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Generating cmd YAML tasks via monju_adapter..."
        TASKS_OUT="$PROJECT_ROOT/queue/tasks"
        python3 "$SCRIPT_DIR/adapters/monju_adapter.py" \
            "$RESULT_JSON" \
            --article-id "simplify_$(date +%Y%m%d_%H%M%S)" \
            --output-dir "$TASKS_OUT"
        echo "Tasks written to: $TASKS_OUT"
    else
        echo "Warning: Could not extract JSON from MAGI output. No tasks generated." >&2
    fi
else
    # Normal mode: stream output directly
    echo "$INPUT" | python3 "$SCRIPT_DIR/cli.py" \
        --mode deliberate \
        --session simplify \
        --stdin \
        "${EXTRA_ARGS[@]}"
fi
