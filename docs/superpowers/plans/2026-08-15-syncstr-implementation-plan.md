# syncstr Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development or executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** NASを正本とするsyncstrのサーバー、移行処理、macOS/iPhoneクライアントを独立したテストサイクルで実装する。

**Architecture:** サーバーはSQLiteトランザクションで操作イベントと正本状態を管理し、クライアントはOpenAPIと機械可読な同期ベクトルへ適合する。Navidromeはメディア配信の補助アダプターに限定し、Rust共有同期コアは製品へ組み込まない。

**Tech Stack:** サーバーはRust + Axumを第一候補とし、Task 1でGoとTypeScriptの最小実装を比較して固定する。DBはSQLite、APIはOpenAPI v1、配布はDocker Compose、macOS/iPhoneはSwiftとSwiftUI、WindowsはC#とWinUI 3、AndroidはKotlinとJetpack Composeを使用する。この計画のserver配下のファイル名はRust + Axumを採用した場合のものとし、別候補を選ぶ場合はTask 2の開始前にADRと計画のパスを更新する。

**Spec:** docs/design-spec.md

## Global Constraints

- NAS上のサーバーをライブラリ、メタデータ、プレイリスト、評価、履歴の正本にする。
- 初回移行はDRM-freeのiTunesまたはMusic XMLとローカル音源だけを対象にする。
- MP3、AAC、M4A、ALAC、WAV、AIFFを登録対象とし、原音を変更しない。
- WAVとAIFFのメタデータはDBとsidecarに保存し、原音のSHA-256を移行前後で比較する。
- オフライン操作はoperation_id、device_id、device_counter、server_seqを持つ。
- パスキーを既定の認証方式とし、端末失効、復旧、レート制限、監査ログを実装する。
- macOSとiPhoneを先行し、WindowsとAndroidは同じOpenAPIと同期ベクトルを通過してから対応済みとする。
- Navidromeの認証済みAPI適合は未測定であり、製品の履歴と同期の正本にはしない。
- AppleのXCTest未提供とiPhone実機未接続によるBLOCKEDを、PASSとして扱わない。

---

### Task 1: リポジトリ基盤とサーバー実装言語を決める

**Files:**
- Create: docs/decisions/ADR-0001-server-runtime.md
- Create: .gitignore
- Create: LICENSE
- Create: server/README.md
- Create: server/Cargo.toml
- Create: server/src/main.rs
- Create: infra/compose.yaml
- Test: scripts/check-foundation.sh

**Interfaces:**
- Consumes: docs/design-spec.md、docs/decisions.md、docs/validation/sync-core-report.md
- Produces: サーバー実装言語、Docker起動契約、秘密情報をコミットしない基盤

- [ ] **Step 1: サーバー候補の比較条件をテストへ固定する**

scripts/check-foundation.shで、Docker Composeが固定された内部ネットワークを使い、検証用資格情報と音源を本番イメージへマウントしないことを確認する。

- [ ] **Step 2: Rustサーバーと代替候補を比較する**

同じhealthz、SQLite接続、コンテナ起動の最小実装を候補ごとに作り、起動時間、イメージサイズ、ビルド時間、エラー分類を記録する。

- [ ] **Step 3: ADRへ選択理由と不採用理由を記録する**

選択した実装言語、Webフレームワーク、SQLiteドライバー、非同期ランタイム、最小サポートOSをADR-0001-server-runtime.mdへ記録する。

- [ ] **Step 4: 基盤検査を実行する**

Run: sh scripts/check-foundation.sh

Expected: 秘密情報の検出、Compose設定、healthz応答、選択言語のバージョン検査が成功する。

- [ ] **Step 5: Commit**

~~~sh
git add .gitignore LICENSE server infra scripts docs/decisions/ADR-0001-server-runtime.md
git commit -m "Establish syncstr server foundation"
~~~

### Task 2: OpenAPIと同期契約を固定する

**Files:**
- Create: contracts/openapi/openapi.yaml
- Create: contracts/sync/schema.json
- Create: contracts/sync/vectors/convergence-basic.json
- Create: contracts/sync/vectors/convergence-conflicts.json
- Create: contracts/sync/vectors/history-events.json
- Create: contracts/sync/vectors/rejections/device-counter-regression.json
- Create: contracts/sync/vectors/rejections/unknown-operation.json
- Create: contracts/sync/vectors/rejections/missing-required-field.json
- Create: contracts/sync/vectors/rejections/missing-server-seq.json
- Test: contracts/tests/contract_test.py
- Create: scripts/contract-test

**Interfaces:**
- Consumes: 技術検証で固定した7ベクトルとdocs/design-spec.md
- Produces: /v1/auth、/v1/catalog、/v1/media、/v1/sync、/v1/backupsの型と同期適合テスト

- [ ] **Step 1: 既存ベクトルを新しい契約パスへ移し、JSON Schemaで検証する**

operation_id、device_id、device_counter、server_seq、entity_type、entity_id、operation_type、payloadを必須にし、未知の操作と不正なpayloadを拒否する。

- [ ] **Step 2: OpenAPIのエラー形式を固定する**

認証失敗、権限不足、競合、カーソル不正、音源欠損、Range不正を、code、message、request_id、必要なdetailsを持つJSONへ正規化する。

- [ ] **Step 3: 失敗テストを先に実行する**

Run: scripts/contract-test

Expected: 必須フィールド欠落、server_seq欠落、未知操作、重複再送、壊れたJSON、互換性のないAPI変更が失敗する。

- [ ] **Step 4: OpenAPIとベクトルの検証を実行する**

Run: scripts/contract-test

Expected: 全ベクトルが読み込まれ、OpenAPIのスキーマ参照とエラーコードが一致する。

- [ ] **Step 5: Commit**

~~~sh
git add contracts scripts/contract-test
git commit -m "Define syncstr service contracts"
~~~

### Task 3: 認証、ライブラリ、メディア配信を実装する

**Files:**
- Create: server/src/auth.rs
- Create: server/src/catalog.rs
- Create: server/src/media.rs
- Create: server/migrations/
- Test: server/tests/auth_tests.rs
- Test: server/tests/catalog_tests.rs
- Test: server/tests/media_tests.rs

**Interfaces:**
- Consumes: contracts/openapi/openapi.yaml、contracts/sync/schema.json
- Produces: パスキー登録、端末失効、スキャン済みカタログ、GET /v1/tracks/{id}/stream

- [ ] **Step 1: SQLite migrationと認証失敗テストを作る**

devices、passkey_credentials、refresh_tokens、audit_events、tracks、metadata_valuesを作り、期限切れ、失効済み、別端末のトークンを拒否する。

- [ ] **Step 2: パスキー登録と端末失効を実装する**

登録チャレンジ、検証、トークン更新、端末一覧、端末失効を実装し、秘密鍵やchallengeをログへ出力しない。

- [ ] **Step 3: 安定ファイルのスキャンと欠損状態を実装する**

一時ファイルを読み飛ばし、サイズとmtimeが安定したファイルだけをハッシュ、形式、再生時間、タグへ進める。外部削除は履歴とプレイリストを消さず、欠損状態へ変更する。

- [ ] **Step 4: 原音優先のRange配信を実装する**

206 Partial Content、Content-Range、Content-Length、SHA-256検証、認証、失効URLをテストする。端末が失敗を報告するまで変換しない。

- [ ] **Step 5: Commit**

~~~sh
git add server
git commit -m "Implement syncstr auth catalog and media boundaries"
~~~

### Task 4: iTunesまたはMusic XML移行を実装する

**Files:**
- Create: server/src/migration/xml_reader.rs
- Create: server/src/migration/inventory.rs
- Create: server/src/migration/matcher.rs
- Create: server/src/migration/report.rs
- Create: server/tests/fixtures/migration/
- Test: server/tests/migration_tests.rs

**Interfaces:**
- Consumes: XML、取り込み領域の音源、tracksとメタデータのmigration staging tables
- Produces: 候補、確認待ち、確定済み行、失敗レポート、WAV/AIFF sidecar

- [ ] **Step 1: XMLと音源の読み取り失敗テストを書く**

XMLのみ、欠損パス、複数候補、DRM、クラウド専用、WAV、AIFF、プレイリスト順序、壊れたXMLをfixtureへ固定する。

- [ ] **Step 2: 非破壊インベントリを実装する**

移行前後の音源SHA-256、サイズ、再生時間を比較し、移動、削除、上書きが発生した場合はテストを失敗させる。

- [ ] **Step 3: 決定的な照合と確認待ちを実装する**

完全一致のパス、サイズ、再生時間、ハッシュの順に候補を絞り、複数候補は自動確定しない。

- [ ] **Step 4: メタデータ、評価、履歴、プレイリストを確定後に取り込む**

タグを書き込める形式はMetadataStoreへ渡し、WAV、AIFF、タグ書き込み失敗はsidecarへ保存する。

- [ ] **Step 5: Commit**

~~~sh
git add server/src/migration server/tests/fixtures/migration server/tests/migration_tests.rs
git commit -m "Add non-destructive music library migration"
~~~

### Task 5: SyncServiceとProjectionUpdaterを実装する

**Files:**
- Create: server/src/sync.rs
- Create: server/src/projections.rs
- Create: server/migrations/0005_sync_operations.sql
- Test: server/tests/sync_tests.rs
- Create: scripts/sync-conformance-test

**Interfaces:**
- Consumes: /v1/syncの操作batchとTask 2の7ベクトル
- Produces: POST /v1/sync、カーソル取得、スナップショット、履歴集計、プレイリスト墓標

- [ ] **Step 1: 失敗テストを作る**

未知操作、必須フィールド欠落、server_seq欠落、device_counter回帰、同一operation_idの再送、プレイリスト移動と削除の衝突をテストする。

- [ ] **Step 2: 操作の一意性と受理順を実装する**

SQLiteの一意制約でoperation_idを重複排除し、単一トランザクションでserver_seqを採番してからProjectionUpdaterへ渡す。

- [ ] **Step 3: scalar、playlist、historyのprojectionを実装する**

お気に入りと評価、項目ID単位の追加、移動、削除、再生開始、進捗、完了、スキップをserver_seq順に適用する。

- [ ] **Step 4: snapshot、cursor、tombstone圧縮を実装する**

長期未接続端末にはスナップショットを返し、全端末の確認条件を満たすまで墓標を90日保持する。

- [ ] **Step 5: 共通ベクトルを実行する**

Run: scripts/sync-conformance-test

Expected: Swift基準実装、Rust候補、サーバー実装が成功状態、履歴、拒否エラーを同じJSONへ正規化する。

- [ ] **Step 6: Commit**

~~~sh
git add server/src/sync.rs server/src/projections.rs server/migrations/0005_sync_operations.sql server/tests/sync_tests.rs
git commit -m "Implement syncstr server synchronization"
~~~

### Task 6: macOSとiPhoneのネイティブクライアントを実装する

**Files:**
- Create: clients/apple/SyncstrApp/
- Create: clients/apple/SyncstrCore/
- Create: clients/apple/SyncstrTests/
- Modify: docs/validation/apple-playback-report.md
- Test: clients/apple/SyncstrTests/

**Interfaces:**
- Consumes: OpenAPI、同期ベクトル、PlaybackProbeのケース契約
- Produces: SwiftUIカタログ、SQLiteローカルストア、Keychain資格情報、オフライン操作、AVFoundation再生

- [ ] **Step 1: ローカルDBとKeychainの失敗テストを書く**

未送信操作、カーソル、ダウンロード状態、端末資格情報を保存し、アプリ強制終了後に再送対象が失われないことを検証する。

- [ ] **Step 2: OpenAPI clientとSyncClientを実装する**

batch再送、指数バックオフ、重複応答、snapshot復元、認証更新、端末失効を共通ベクトルで検証する。

- [ ] **Step 3: SwiftUIのカタログ、プレイリスト、設定を実装する**

VoiceOver、Dynamic Type、キーボード操作、フォーカス順、空状態、エラー再試行をアクセシビリティ識別子で検証する。

- [ ] **Step 4: ダウンロードと原音優先再生を実装する**

Range再開、部分ファイル隔離、SHA-256検証、容量上限、明示ダウンロードの保護を実装する。

- [ ] **Step 5: Apple実機の再生ケースを検証する**

macOSとiPhoneで同じ11ケースのJSONを保存し、ギャップレス、バックグラウンド、メディアキー、HTTPS Rangeを実機結果で判定する。

- [ ] **Step 6: Commit**

~~~sh
git add clients/apple docs/validation/apple-playback-report.md
git commit -m "Build syncstr Apple clients"
~~~

### Task 7: 運用、バックアップ、ゴミ箱を実装する

**Files:**
- Create: infra/compose.yaml
- Create: infra/reverse-proxy/
- Create: ops/backup/
- Create: ops/runbooks/
- Test: ops/tests/

**Interfaces:**
- Consumes: AuthService、CatalogService、SyncService、TrashService、BackupService
- Produces: HTTPS前段、ヘルスチェック、暗号化バックアップ、復元手順、監査ログ、OSSライセンス監査

- [ ] **Step 1: 本番Composeと設定検査を作る**

検証用Navidromeの資格情報、音源、DB、ポートを本番Composeへ持ち込まないことを設定テストで確認する。

- [ ] **Step 2: HTTPS、レート制限、監査ログを実装する**

外部公開はHTTPSだけにし、管理エンドポイントを内部ネットワークへ閉じ、資格情報をログへ出さない。

- [ ] **Step 3: バックアップと隔離復元を実装する**

DB、イベント、sidecar、設定、音源インベントリのマニフェストを暗号化し、別環境で復元してハッシュとカーソルを検証する。

- [ ] **Step 4: ゴミ箱、墓標保持、イベント圧縮を実装する**

90日ルール、端末失効、完全削除の再認証、復元操作を監査ログへ記録する。

- [ ] **Step 5: Commit**

~~~sh
git add infra ops
git commit -m "Add syncstr operations and recovery"
~~~

### Task 8: MVPの受け入れと日常利用を検証する

**Files:**
- Create: docs/acceptance/mvp-checklist.md
- Create: docs/acceptance/failure-log.md
- Modify: docs/design-spec.md
- Create: scripts/mvp-test

**Interfaces:**
- Consumes: サーバー、macOS、iPhone、移行、運用の全成果物
- Produces: 4週間の日常利用結果、障害記録、Windows/Android着手判定

- [ ] **Step 1: NAS停止、回線切替、アプリ終了、重複再送のシナリオを固定する**

各シナリオで、音源再生、未送信操作、復旧後のserver_seq、履歴の重複が期待結果と一致することを記録する。

- [ ] **Step 2: 移行と復元の非破壊性を確認する**

XML移行前後の音源SHA-256、WAV/AIFF sidecar、バックアップ復元後のプレイリストと履歴を比較する。

- [ ] **Step 3: macOS/iPhoneの未解決BLOCKEDを判定する**

XCTest未提供、iPhone実機未接続、ギャップレス、メディアキー、HTTPS Rangeの未検証項目を、実測結果なしに合格へ変更しない。

- [ ] **Step 4: Windows/Androidの開始条件を確認する**

共通OpenAPI、同期ベクトル、メディア形式、認証、オフライン操作の全契約が確定してから適合実装を始める。

- [ ] **Step 5: Commit**

~~~sh
git add docs/acceptance docs/design-spec.md scripts/mvp-test
git commit -m "Define syncstr MVP acceptance"
~~~
