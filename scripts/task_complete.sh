#!/bin/bash
# task_complete.sh — ヤクザ完了報告の4ステップを1コマンドで実行
# Usage: bash scripts/task_complete.sh <task_id> <yakuza_number> <project_path>
# Example: bash scripts/task_complete.sh subtask_360a 1 /home/hrmtz/project/multi-agent-njslyr
#
# Steps:
#   1. Report YAML 生成 (queue/reports/yakuza{N}_report_{task_id}.yaml)
#   2. cmd YAML status → completed 更新
#   3. git add + commit (project_path 内の変更)
#   4. inbox_write to soukaiya

set -e

SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"

TASK_ID="${1:-}"
YAKUZA_NUM="${2:-}"
PROJECT_PATH="${3:-}"

# Argument validation
if [ -z "$TASK_ID" ] || [ -z "$YAKUZA_NUM" ] || [ -z "$PROJECT_PATH" ]; then
    echo "Usage: bash scripts/task_complete.sh <task_id> <yakuza_number> <project_path>" >&2
    echo "Example: bash scripts/task_complete.sh subtask_360a 1 /home/hrmtz/project/multi-agent-njslyr" >&2
    exit 1
fi

WORKER_ID="yakuza${YAKUZA_NUM}"
REPORT_FILE="queue/reports/${WORKER_ID}_report_${TASK_ID}.yaml"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Find parent_cmd from task YAML
PARENT_CMD=""
TASK_YAML=$(ls -t "${SCRIPT_DIR}/queue/tasks/${WORKER_ID}_${TASK_ID}.yaml" \
                "${SCRIPT_DIR}/queue/tasks/${WORKER_ID}.yaml" 2>/dev/null | head -1 || true)

if [ -n "$TASK_YAML" ] && [ -f "$TASK_YAML" ]; then
    PARENT_CMD=$(grep -E "^\s*parent_cmd:" "$TASK_YAML" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' || true)
fi

echo "[task_complete] === STEP 1: Report YAML 作成 ===" >&2

# Collect modified files from git (if in a git repo)
MODIFIED_FILES="[]"
if [ -d "${PROJECT_PATH}/.git" ]; then
    CHANGED=$(cd "$PROJECT_PATH" && git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null) || true
    if [ -n "$CHANGED" ]; then
        MODIFIED_FILES=$(echo "$CHANGED" | python3 -c "
import sys, json
files = [f.strip() for f in sys.stdin.read().strip().split('\n') if f.strip()]
print(json.dumps(files))
")
    fi
fi

# Generate report YAML
python3 -c "
import yaml, os, sys

report = {
    'worker_id': '${WORKER_ID}',
    'task_id': '${TASK_ID}',
    'parent_cmd': '${PARENT_CMD}' if '${PARENT_CMD}' else None,
    'timestamp': '${TIMESTAMP}',
    'status': 'done',
    'result': {
        'summary': '${TASK_ID} 完了 (task_complete.sh による自動報告)',
        'files_modified': ${MODIFIED_FILES},
        'notes': ''
    },
    'skill_candidate': {
        'found': False
    }
}

# Remove None values
report = {k: v for k, v in report.items() if v is not None}

report_path = os.path.join('${SCRIPT_DIR}', '${REPORT_FILE}')
os.makedirs(os.path.dirname(report_path), exist_ok=True)

with open(report_path, 'w') as f:
    yaml.dump(report, f, default_flow_style=False, allow_unicode=True, indent=2)

print(f'[task_complete] Report written: ${REPORT_FILE}', file=sys.stderr)
"

echo "[task_complete] === STEP 2: cmd YAML status 更新 ===" >&2

# Update parent cmd YAML status if found
if [ -n "$PARENT_CMD" ]; then
    CMD_YAML="${SCRIPT_DIR}/queue/tasks/${PARENT_CMD}.yaml"
    if [ -f "$CMD_YAML" ]; then
        python3 -c "
import yaml, sys

with open('${CMD_YAML}', 'r') as f:
    data = yaml.safe_load(f)

if isinstance(data, dict):
    # Handle both top-level status and nested task.status
    if 'status' in data:
        data['status'] = 'completed'
    elif 'task' in data and isinstance(data['task'], dict):
        data['task']['status'] = 'completed'

with open('${CMD_YAML}', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)

print(f'[task_complete] Updated status in ${CMD_YAML}', file=sys.stderr)
" 2>&1 || echo "[task_complete] WARN: Could not update ${CMD_YAML}" >&2
    else
        echo "[task_complete] WARN: cmd YAML not found: ${CMD_YAML}" >&2
    fi
else
    echo "[task_complete] INFO: parent_cmd not found, skipping cmd YAML update" >&2
fi

echo "[task_complete] === STEP 3: git commit ===" >&2

if [ -d "${PROJECT_PATH}/.git" ]; then
    cd "$PROJECT_PATH"
    # Stage and commit if there are changes
    STAGED=$(git diff --name-only HEAD 2>/dev/null || true)
    UNSTAGED=$(git diff --name-only 2>/dev/null || true)
    UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null || true)

    if [ -n "$STAGED" ] || [ -n "$UNSTAGED" ] || [ -n "$UNTRACKED" ]; then
        git add -A
        git commit -m "feat: ${TASK_ID} 完了 (${WORKER_ID})"
        echo "[task_complete] git commit done" >&2
    else
        echo "[task_complete] INFO: No changes to commit" >&2
    fi
    cd "$SCRIPT_DIR"
else
    echo "[task_complete] INFO: Not a git repo or no .git found at ${PROJECT_PATH}, skipping commit" >&2
fi

echo "[task_complete] === STEP 4: inbox_write to soukaiya ===" >&2

bash "${SCRIPT_DIR}/scripts/inbox_write.sh" soukaiya \
    "${WORKER_ID}号、ニンム・コンプリート。品質チェックを仰ぐ。ドーモ。" \
    report_received \
    "$WORKER_ID" \
    "${SCRIPT_DIR}/${REPORT_FILE}"

echo "[task_complete] === 全4ステップ完了 ===" >&2
echo "[task_complete] Report: ${SCRIPT_DIR}/${REPORT_FILE}" >&2
