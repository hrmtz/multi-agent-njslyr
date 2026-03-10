#!/bin/bash
# MAGI Deliberate — Run all 8 M articles
# Processes 2 at a time with 10s gap between batches to avoid rate limits

set -euo pipefail
cd "$(dirname "$0")/../.."
export $(grep -v '^#' config/api_keys.env | grep -v '^$' | xargs)

ARTICLES_DIR="/home/hrmtz/project/content-forge/output/articles"
RESULTS_DIR="scripts/magi/results"
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

    # Extract content from nlm_draft.json
    local content
    content=$(python3 -c "
import json, sys
d = json.loads(open('$json_file').read())
title = d.get('title', '')
content = d.get('content', '')
print(f'Title: {title}\n\n{content}')
")

    # Run MAGI deliberate
    cd scripts/magi
    python3 magi.py \
        --mode deliberate \
        --session article_review \
        --json \
        --context "メンズ美容クリニック記事。ターゲット: 鼻整形に興味がある20-40代男性" \
        "$content" \
        > "../../$out_file" 2>&1
    cd ../..

    echo "✓ $name → $out_file"
}

echo "◆ MAGI DELIBERATE — 8 M Articles ◆"
echo ""

for i in "${!articles[@]}"; do
    run_one "${articles[$i]}" &

    # Run 2 in parallel, then wait
    if (( (i + 1) % 2 == 0 )); then
        wait
        echo ""
        echo "--- batch $((i/2 + 1))/4 complete, cooling 10s ---"
        sleep 10
    fi
done

# Wait for any remaining
wait

echo ""
echo "◆ ALL 8 COMPLETE ◆"
echo "Results in: $RESULTS_DIR/"
ls -la "$RESULTS_DIR/"
