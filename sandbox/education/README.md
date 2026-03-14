# 体験型ハッキング教育プログラム
## 攻撃と防御で学ぶセキュリティの勘所

---

## このプログラムについて

このプログラムは、**攻撃者の視点を経験することで、防御側の穴を見抜く力を養う**ハンズオン教育です。

単なる「ハッキング手法」の学習ではなく、以下の循環を実践します：

```
[Attack Phase] 実際に脆弱性を突く
        ↓
[Understanding] なぜこの穴が生まれたのか理解する
        ↓
[Defense Phase] その穴をどう防ぐか実装する
        ↓
[Reflection] 防御側の視点で次の狙われ方を考える
        ↓
[Next Level へ]
```

---

## 学習ゴール

このプログラム完了時に以下が身につきます：

- ✅ **セキュリティホール探索の思考法**
  - なぜこの穴が生まれるのか
  - どこを探れば穴が見つかるか
  - 攻撃者は何を狙うのか

- ✅ **防御側の視点**
  - ネットワーク層から Application 層まで何が防ぐべきか
  - 各層の責任範囲の理解
  - 層の組み合わせ（Defense-in-Depth）の重要性

- ✅ **セキュリティ思考の獲得**
  - 「つくったら終わり」ではなく「永遠の猫ネズミゲーム」の理解
  - リスク評価・優先順位付けの勘所

---

## プログラム構成

### Level 1 - Potato（基礎・土台）
**目標**: サーバーの基本情報取得と偵察

- Nmap でのポートスキャン
- Banner grabbing
- HTTP ヘッダ情報取得
- WordPress version 特定

**攻撃時間**: 5～10分
**防御対策**: 情報公開の最小化

---

### Level 2 - Vegetable（初級・野菜）
**目標**: 未認証のデータ漏洩ベクトル発見

- REST API ユーザー列挙
- WPScan でプラグイン脆弱性検出
- XML-RPC 問題確認
- バージョン情報からの CVE 検索

**攻撃時間**: 10～15分
**防御対策**: API 制限、情報隠蔽、プラグイン管理

---

### Level 3 - Intermediate（中級・野菜炒め）
**目標**: 認証情報なしで管理者権限接近

- FTP ブルートフォース攻撃
- SQL injection（mw-wp-form プラグイン）
- XML-RPC ブルートフォース
- Admin 認証突破

**攻撃時間**: 15～30分
**防御対策**: IP 制限、入力検証、レート制限

---

### Level 4 - Advanced（上級・本格的）
**目標**: Remote Code Execution (RCE) → www-data shell 獲得

- WordPress admin 認証
- Theme/Plugin editor から PHP injection
- Malicious plugin アップロード
- www-data shell での任意コマンド実行

**攻撃時間**: 5～10分（認証後）
**防御対策**: ファイル編集禁止、権限管理、disable_functions

---

### Level 5 - Expert（エキスパート・奥義）
**目標**: www-data → root privilege escalation

- PHP disable_functions の理解と検証
- Kernel CVE の確認
- Privilege escalation techniques
- Root shell 獲得

**攻撃時間**: 10～20分
**防御対策**: Kernel パッチ、権限分離、AppArmor/SELinux

---

## 環境セットアップ

### 前提条件
- Docker コンテナ (localhost:8080) で実行中の WordPress
  ```bash
  # コンテナID確認
  docker ps | grep wordpress

  # コンテナへのアクセス
  docker exec -it <container_id> bash
  ```

- Kali Linux または以下のツール:
  - `nmap`
  - `curl`
  - `jq`
  - `wpscan`（オプション）
  - `hydra`（Level 3 以降）

### 環境確認
```bash
# 目標サーバーへの接続確認
curl -I http://localhost:8080

# WordPress が起動していることを確認
curl -s http://localhost:8080 | grep -i wordpress
```

---

## 対話形式での進め方

### 各 Level での流れ

**Step 1: ファイルを読む**
- `level_X_[name].md` を開く
- 背景知識と Attack Phase を理解

**Step 2: Attack を実行**
- 提示されたコマンドを実行
- 結果をスクリーンショット or テキストで報告

**Step 3: Claude に対話**
```
「実行してみました。このような結果が出ました↓」
[出力結果をペースト]

「次はどうします？」
```

**Step 4: Defense と Reflection**
- Claude の解説を聞く
- 防御側の実装を試す
- 思考問題に答える

**Step 5: 次 Level へ**

---

## 学習時間の目安

| Level | 所要時間 | 難易度 |
|-------|---------|--------|
| 1 | 20～30分 | ⭐ |
| 2 | 30～40分 | ⭐⭐ |
| 3 | 45～60分 | ⭐⭐⭐ |
| 4 | 60～90分 | ⭐⭐⭐⭐ |
| 5 | 90～120分 | ⭐⭐⭐⭐⭐ |
| **合計** | **4～6時間** | |

---

## 記録の取り方

`reflection_sheet.md` に以下を記録しながら進めます：

- 各 Level で発見したこと
- 防御実装で工夫したこと
- 攻撃者の思考プロセス
- 「これなら防げたのでは」という気付き

---

## 何か疑問がでたら

各 Level を読む中で：
- 「これはなぜ？」
- 「こうしたらどうなる？」
- 「実行がうまくいかない」

など、いつでも Claude に質問してください。

対話形式で、あなたの理解度に合わせてサポートします。

---

## さあ、始めよう

まずは **Level 1 - Potato** から開始します。

```bash
cat level_1_potato.md
```

準備ができたら返信してください！

---

**作成日**: 2026-03-13
**対象環境**: Docker WordPress (localhost:8080)
**学習モード**: 対話型ハンズオン
