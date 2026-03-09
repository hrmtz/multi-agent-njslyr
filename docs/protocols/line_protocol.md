# LINE Protocol (Darkninja 用)

> 参照条件: LINE 連携処理・cron 設定・ntfy_listener の挙動確認時のみ。

---

## 概要

Darkninja は LINE メッセージを受信・処理し、ラオモトに応答を返す。

```
ラオモト (LINE) → Cloudflare Worker → ntfy → ntfy_listener.sh → Darkninja inbox
Darkninja → scripts/line_push.sh → LINE API → ラオモト
```

---

## LINE 送信

```bash
bash scripts/line_push.sh "<本文>"
```

- credentials: `config/line.env` (LINE_CHANNEL_ACCESS_TOKEN + LINE_USER_ID)
- 日報ファイル保存先: `reports/daily/YYYY-MM-DD.md`

長文送信（140字制限の場合は複数回呼ぶ）:
```bash
bash scripts/line_push.sh "前半テキスト"
bash scripts/line_push.sh "後半テキスト"
```

---

## LINE 受信フロー

### Cloudflare Worker → ntfy

`services/line-ntfy-bridge/src/worker.js` が LINE Webhook を受信し ntfy に転送。

ntfy トピック: `laomoto`（CLAUDE.md の ntfy 設定参照）

### ntfy_listener.sh

cron で起動。ntfy からメッセージを受信し Darkninja inbox に書き込む。

```bash
# cron 例
* * * * * /path/to/scripts/ntfy_listener.sh
```

プレフィックス別処理:
| プレフィックス | 意味 |
|---------------|------|
| `lineimg:` | LINE 画像受信（`scripts/line_image_download.sh` で保存） |
| なし | テキストメッセージ → Darkninja inbox |

### 即時応答（推薦案 A: worker.js replyToLine）

`services/line-ntfy-bridge/src/worker.js` の `replyToLine()` を有効化すると受信即時に「受信しました。処理中...」を返送できる。
- `handleEvent()` 内で `replyToLine(replyToken, "受信しました。処理中...")` を呼ぶ
- `ctx.waitUntil(postToNtfy(...))` で ntfy 転送を非同期化

---

## LINE 画像処理

```bash
bash scripts/line_image_download.sh <message_id>
```

保存先: `reel/line_images/`
自動削除: cron で毎日3時に7日超ファイル削除

---

## 日報送信手順

1. 日報内容を作成（テンプレート: `reports/daily/TEMPLATE_NJSLYR.md`）
2. ファイル保存: `reports/daily/YYYY-MM-DD.md`
3. LINE 送信:
   ```bash
   bash scripts/line_push.sh "本文（140字程度ずつ）"
   ```

忍殺風日報スタイル:
- @NJSLYR原文準拠の三人称散文
- デッドパン + トンチキさ誇張
- 情景描写 → 内面 → 行動の散文構成
- 感嘆詞控えめ

---

## cron 設定（Kyoto）

```bash
# ntfy_listener: 毎分実行
* * * * * cd /home/hrmtz/project/multi-agent-njslyr && bash scripts/ntfy_listener.sh

# 日報送信: 毎日22時
0 22 * * * cd /home/hrmtz/project/multi-agent-njslyr && bash scripts/cron_njslyr_report.sh

# 画像クリーンアップ: 毎日3時
0 3 * * * find /home/hrmtz/project/multi-agent-njslyr/reel/line_images -mtime +7 -delete
```

---

## API キー管理

- LINE Channel Access Token + User ID: `config/line.env` (gitignored)
- Cloudflare Worker URL: `config/api_keys.env` の `CLOUDFLARE_WORKER_URL`

```bash
# line.env の形式
LINE_CHANNEL_ACCESS_TOKEN=your_token_here
LINE_USER_ID=Uxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```
