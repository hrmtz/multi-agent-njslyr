#!/bin/bash
# MAGI Walkthrough — Run all 8 M articles for dropout simulation
# 2 parallel x 4 batches with cooling

set -euo pipefail
cd "$(dirname "$0")/../.."
export $(grep -v '^#' config/api_keys.env | grep -v '^$' | xargs)

ARTICLES_DIR="/home/hrmtz/project/content-forge/output/articles"
RESULTS_DIR="scripts/magi/results/walkthrough"
mkdir -p "$RESULTS_DIR"

articles=(
    "article_M1_メンズ鼻整形"
    "article_M2_男性鼻整形自然"
    "article_M3_メンズ鼻整形バレない"
    "article_M4_男性鼻整形ダウンタイム"
    "article_M5_メンズ団子鼻"
    "article_M6_男鼻低い"
    "article_M7_男性鼻整形費用"
    "article_M8_メンズ鼻整形おすすめ"
)

run_one() {
    local dir="$1"
    local name=$(basename "$dir")
    local json_file="$ARTICLES_DIR/$dir/nlm_draft.json"
    local out_file="$RESULTS_DIR/${name}.json"

    echo "━━━ $name ━━━"

    local content
    content=$(python3 -c "
import json
d = json.loads(open('$json_file').read())
print(d.get('content', ''))
")

    cd scripts/magi
    python3 magi.py \
        --mode walkthrough \
        --session article_review \
        --json \
        --context "メンズ美容クリニック記事。ターゲット: 鼻整形に興味がある20-40代男性" \
        "$content" \
        > "../../$out_file" 2>&1
    cd ../..

    echo "✓ $name → $out_file"
}

echo "◆ MAGI WALKTHROUGH — 8 M Articles ◆"
echo ""

for i in "${!articles[@]}"; do
    run_one "${articles[$i]}" &

    if (( (i + 1) % 2 == 0 )); then
        wait
        echo ""
        echo "--- batch $((i/2 + 1))/4 complete, cooling 10s ---"
        sleep 10
    fi
done

wait

echo ""
echo "◆ ALL 8 WALKTHROUGH COMPLETE ◆"
ls -la "$RESULTS_DIR/"
