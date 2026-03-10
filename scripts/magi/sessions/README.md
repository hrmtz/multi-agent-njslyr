# MAGI Sessions

セッション定義の外部化ディレクトリ（Phase 2実装予定）。

## 概要

Phase 2では、セッション設定をYAMLファイルとして外部化し、
コードを変更せずに新しい審議コンテキストを追加できるようにする。

## 予定フォーマット (Phase 2)

```yaml
# sessions/article_review.yaml
id: article_review
description: 美容クリニックブログ記事レビュー
context_prompt: |
  Review the following blog article for a beauty clinic website.
  ...
personas:
  MELCHIOR:
    override_perspective: "医療精度重視"
  BALTHASAR:
    override_perspective: "ユーザー体験重視"
```

## 現状

Phase 1では `core/prompts.py` の `SESSION_TYPES` dict で定義。
外部YAMLへの移行は Phase 2 で実施。
