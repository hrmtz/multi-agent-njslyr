# Cross-Machine Operation Protocol

> 参照条件: Kyoto/NeoSaitama 間の連携・ハンドオーバー・障害対応時のみ。

---

## マシン構成

| マシン | 役割 | Gryakuza | アクセス |
|--------|------|----------|---------|
| **Kyoto / Ryzen** | Primary (Master) | スミス | ローカル |
| **NeoSaitama / MBP** | Secondary (Slave) | ヤマヒロ | `ssh peer-hostname` (Tailscale) |

**重要**: 「ローカル/リモート」で判断するな。マシン名で判別せよ。

---

## 通信経路

```
Primary (送信)      →  SSH (優先)  →  Secondary受信
                   →  ntfy (フォールバック)
```

- SSH ファースト: `dispatch/aisatsu/suriken/heartbeat` 全て SSH → ntfy fallback
- NeoSaitama SSH: `ssh peer-hostname` (Tailscale 経由)
- Tailscale: `--unattended` 有効化済み（ログイン前接続維持）

---

## Slave Mode (NeoSaitama)

`config/settings.yaml` の `machine.role` が `neosaitama` の場合:

### 可能な操作
- ntfy/inbox 経由のサブタスク受信（Kyoto gryakuza から）
- ローカル yakuza1-3 への割り当て
- ローカル soukaiya への QC 依頼
- ntfy 経由の完了報告送信（`scripts/ntfy_send_report.sh` 使用）

### 禁止操作
- 独自 cmd 作成
- 独自タスク分解（Pre-decomposed tasks 受信のみ）
- Memory MCP write（Read-only）
- dashboard.md 更新
- active_machine.yaml 更新

### 完了報告（Slave → Master）

```bash
bash scripts/ntfy_send_report.sh <report_yaml_path>
```

Kyoto 側 ntfy_listener が受信 → gryakuza inbox に通知 → 正規レポートフローに合流。

---

## Emergency Degraded Mode

`queue/active_machine.yaml` の `mode: emergency_degraded` 時の制約:

トリガー: Kyoto 障害 + ラオモト 30分無応答 → `watcher_supervisor.sh` が自動設定

制約: 新規 cmd 採番禁止、新規タスク分解禁止
許可: 既存 in_progress タスクの継続のみ

解除条件:
1. Kyoto SSH 疎通回復 → 自動復帰
2. ラオモトが `handover:neosaitama` 送信 → full authority に昇格

---

## Handover 手順（Kyoto → NeoSaitama）

1. ラオモトが LINE で `handover:neosaitama` を送信
2. ntfy_listener.sh がキーワード検知
3. NeoSaitama gryakuza（ヤマヒロ）の権限を full authority に昇格
4. `queue/active_machine.yaml` の `mode: full_authority` に更新
5. 未完了タスクの引き継ぎ確認

---

## Guardian Scripts（自動監視）

### Kyoto: tortoise_guardian.sh

```bash
# watchdog.timer (60秒間隔) で実行
# multi-agent-njslyr.service と連携
```

### NeoSaitama: crane_guardian.sh

crontab で実行。macOS 特有の検出ロジック:

```bash
# pane_current_command="2.1.63" (claude起動中でも)
# pgrep 方式で検出:
# Case A: shell→claude子 → pgrep -P pane_pid
# Case B: respawn直接起動 → pane_pid 自体が claude
# ps -p pane_pid -o comm= で判定

CLAUDE_BIN=/Users/hrmtz/.local/bin/claude  # フルパス必須
```

障害パターン:
1. crane HB ループ停止 → crane_guardian.sh で自動再起動
2. tmux サーバー全停止 → 自然復旧待ち or 手動復旧
3. "Not logged in" → macOS Keychain lock → `~/.claude/.credentials.json` を SCP で解決

---

## デバッグ: 疎通確認

```bash
# SSH 疎通テスト
ssh peer-hostname echo "OK"

# ntfy 疎通テスト
bash scripts/ntfy_send_report.sh --test

# Tailscale ステータス
tailscale status
```

---

## ファイル同期

プロジェクトデータは git で同期（`git push` / `git pull`）。
`projects/` ディレクトリは gitignore（機密情報を含むため）。

credentials 同期（手動）:
```bash
scp ~/.claude/.credentials.json peer-hostname:~/.claude/.credentials.json
```
