## Agent skills

### Issue tracker

Issues are tracked in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context layout. See `docs/agents/domain.md`.

## macOS アプリの起動確認

- Syncstr のビルドを起動・再起動するときは、先に実行中の Syncstr の実行パスを確認し、別 worktree の旧ビルドを含む既存インスタンスを通常終了する。終了を確認してから対象ビルドを1つだけ起動する。
- 起動後は、Syncstr のプロセスが1つだけで、その実行パスが対象ビルドと一致することを確認する。同じ bundle ID のアプリが複数存在しうるため、アプリの選択には絶対パスを使う。
