# 個人向けクロスプラットフォーム音楽プレイヤー設計仕様書

作成日：2026-08-14
対象フェーズ：設計完了、技術検証完了、製品実装未着手
想定利用者：当面は単一利用者、将来はオープンソースとして公開

## 概要

このシステムは、NASに集約したローカル音源をmacOS、Windows、iPhone、Androidで再生する個人向け音楽プレイヤーである。

NAS上のライブラリ、メタデータ、プレイリスト、評価、再生履歴を正本とし、各端末は必要な音源を保存してオフラインでも再生する。

既存のiTunesまたはMusicライブラリは初回移行の入力として扱う。

初回移行後にAppleのアプリケーションと継続的な双方向同期は行わない。

既存のiTunesまたはMusicのXML書き出しは曲情報とプレイリストを含むが、音源本体を含まないため、XMLと音源ファイルを別々に取り込んで対応づける。

Apple Musicのクラウド上だけに存在する曲と、DRMで保護された音源は対象外とする。

## 設計原則

- **UIの状態表現**：選択・再生などの状態は色、背景、アイコンで表す。見た目から明らかな状態を「選択中」「再生中」などの説明テキストで重ねることは禁止する。スクリーンリーダーにはアクセシビリティ属性で状態を伝える。
- **NAS正本**：サーバーがライブラリ状態を保持し、端末はキャッシュと操作の送信元になる。
- **原音優先**：音源を原音のまま保存、配信し、端末が再生できない場合だけ互換コピーを生成する。
- **操作の損失防止**：オフライン操作を一意な操作として記録し、再送しても重複適用しない。
- **最終収束**：複数端末が別々に操作しても、同期完了後にすべての端末が同じ状態へ収束する。
- **ネイティブ実装**：UIの情報設計とデザインは共通化するが、UIコード、音声再生、バックグラウンド動作、OS連携は各OSのAPIを使う。
- **可搬性**：サーバーはDocker Composeを標準配布形式とし、単一バイナリ配布も検証対象とする。
- **復元可能性**：音源だけでなくDB、履歴イベント、sidecar、設定を復元対象とする。

## 用語

- **ライブラリ**：サーバーが管理する音源とそのメタデータの集合。
- **トラック**：ライブラリへ登録した一つの音源ファイルを表す内部エンティティ。同じ内容の別ファイル、別ミックス、別マスター、別形式は別トラックとして扱う。
- **音源ファイル**：NASのメディア領域に保存される原音ファイル。
- **sidecar**：音源ファイルにタグを書き込めない場合に、同じ音源を補足するメタデータファイル。
- **操作イベント**：端末またはサーバーが状態変更を表すために発行する一意なイベント。
- **正本状態**：サーバーが操作イベントを適用して得た現在の状態。
- **端末キャッシュ**：端末がオフライン再生のために保持する音源、メタデータ、操作イベント。

## 対象範囲

### 対象機能

- DRMなしのローカル音源の初回移行
- MP3、AAC、M4A、ALAC、WAV、AIFFの登録と再生
- 形式追加を可能にする音声デコーダー境界
- 曲名、アーティスト、アルバム、アルバムアーティスト、ジャンル、年、ディスク番号、トラック番号、作曲者、コメント、アートワークの管理
- タグが存在する音源へのタグ書き込み
- タグを書き込めない音源へのDB保存とsidecar保存
- アルバム、アーティスト、曲、プレイリスト、お気に入り、履歴の閲覧
- 全文検索とメタデータによる絞り込み
- 通常再生、キュー、ギャップレス再生、音量正規化
- 原音のストリーミングとオフラインダウンロード
- 指定プレイリストとお気に入りの自動ダウンロード
- 再生開始、一定進捗到達、完了、スキップの履歴記録
- 評価、お気に入り、プレイリスト編集のオフライン操作
- 操作イベントの再送、重複排除、競合解決
- HTTPSによるリモートアクセス
- パスキーによる認証と端末単位の資格情報失効
- NAS音源の追加、スキャン、欠損検出、重複候補検出
- ゴミ箱を経由した音源の削除
- DB、履歴、設定、sidecarを含むバックアップと復元
- macOSとiPhoneを初期縦切りとするネイティブアプリ
- WindowsとAndroidを後続のネイティブアプリとする適合実装

### 対象外

- Apple MusicまたはiTunesとの継続的な双方向同期
- Apple Musicのクラウド上だけに存在する曲
- DRM保護された音源の汎用プレイヤーでの再生
- 定額配信サービスとの連携
- Chromecast、AirPlayなど外部機器へのキャスト
- 歌詞
- レコメンド
- スマートプレイリスト
- EQ
- 排他出力とサンプルレート自動切替
- Last.fm、ListenBrainzなどへの外部scrobble
- 複数ユーザー向けのロール分割
- Webプレイヤー

## 利用シナリオ

### 初回移行

1. 利用者がMusicまたはiTunesからXMLを書き出す。
2. 利用者が音源をNASの取り込み領域へコピーする。
3. サーバーがXMLと音源ファイルを読み取り、パス、ファイル名、サイズ、再生時間を使って候補を作る。
4. 候補が一意に定まる曲を登録し、候補が複数ある曲を確認待ちにする。
5. XMLから読み取れるプレイリスト、評価、再生回数、最終再生日時を初期値として取り込む。
6. DRM保護された曲、クラウド上だけの曲、照合できない曲を移行結果へ記録する。
7. 取り込みは音源の移動や削除を行わず、利用者が結果を確認してからライブラリを確定する。

### 音源スキャン

1. サーバーは監視フォルダと手動実行の両方でスキャンを開始する。
2. スキャンは一時状態のファイルを読み飛ばし、ファイルが安定してからメタデータと音声情報を抽出する。
3. ファイル内容のSHA-256、サイズ、形式、再生時間、サンプルレート、チャンネル数を保存する。
4. 既存トラックのパス変更は同一内容のハッシュ候補として提示する。
5. 同一内容または類似メタデータの重複候補は自動統合せず、別トラックとして保持するか利用者が確認する。
6. 外部操作で消えたファイルは欠損状態へ変更し、履歴とプレイリストから直ちに削除しない。

### 再生

1. クライアントはメタデータと再生URLを取得する。
2. 端末に完全な音源が保存されていればローカル音源を優先する。
3. 保存されていなければHTTPSで原音をストリーミングする。
4. 端末が原音形式を扱えない場合はサーバーに互換コピーを要求する。
5. 再生エンジンはOSのメディアセッション、バックグラウンド再生、メディアキー、通知へ統合する。
6. 再生エンジンはギャップレス再生を提供する。
7. 音量正規化は原音ファイルを変更せず、再生経路で適用する。
8. 再生操作は端末へ永続化し、ネットワークが復旧した時点で履歴イベントを送信する。

### オフライン再生とダウンロード

1. 利用者は曲、アルバム、プレイリスト、お気に入りを明示的にダウンロードできる。
2. 自動ダウンロードはお気に入りと指定プレイリストを対象とする。
3. 自動キャッシュは利用者が設定した容量上限内で管理し、明示ダウンロードを自動削除しない。
4. ダウンロードはHTTP Rangeで再開し、完了後にSHA-256を検証する。
5. 検証前の部分ファイルはライブラリへ表示しない。
6. 端末の空き容量を安全制限より下げる操作は拒否する。
7. 通常はアプリ専用領域へ保存し、利用者が明示的に書き出した場合だけ共有領域へ複製する。

### 同期

1. クライアントは操作を一意なoperation_id、端末内連番、端末IDとともにローカルへ保存する。
2. クライアントは未送信操作をまとめてサーバーへ送信する。
3. サーバーはoperation_idの一意制約で重複を排除し、受理順にserver_seqを付与する。
4. サーバーは操作を正本状態へ適用し、適用結果と次の同期カーソルを返す。
5. クライアントはカーソル以降の操作を取得し、同じ操作をローカル状態へ適用する。
6. 同期失敗時は未送信操作を削除せず、指数バックオフで再送する。
7. 長期間接続しなかった端末は差分期間を超えた場合に完全スナップショットを取得する。

### プレイリスト競合

プレイリストの追加、削除、並べ替えは、配列全体ではなく項目IDを対象とする操作として記録する。

サーバーは受理した操作をserver_seq順に適用し、同じ項目に複数の移動があれば後から受理した移動を最後の位置へ適用する。

削除された項目は墓標として保持し、古い端末が再送して復活させることを防ぐ。

墓標は全端末の同期確認後も90日間保持し、その後にスナップショットへ圧縮する。

## アーキテクチャ

### サーバー

サーバーは次の責務を持つ。

- ライブラリスキャン、メタデータ抽出、移行、重複候補検出
- 正本DBの読み書きと検索インデックス更新
- 音源のRange配信、原音配信、互換コピー生成
- 同期操作の受理、重複排除、競合解決、カーソル管理
- パスキー登録、認証、端末管理、資格情報失効
- 管理者向け音源削除、ゴミ箱、バックアップ、復元
- ヘルスチェック、監査ログ、設定管理

サーバー内部の論理モジュールは次の名前と責務に分ける。

- `AuthService`：パスキーのチャレンジ、検証、端末登録、トークン更新、失効を扱う。
- `LibraryScanner`：監視フォルダを走査し、ファイルの安定化、ハッシュ計算、欠損検出を扱う。
- `LibraryImporter`：iTunesまたはMusic XMLと音源ファイルを照合し、確認待ちと移行結果を管理する。
- `MetadataStore`：DB、音源タグ、sidecarの読み書きと不一致を扱う。
- `CatalogService`：トラック、アルバム、アーティスト、検索インデックスを提供する。
- `MediaService`：原音のRange配信、署名URL、互換コピー生成を扱う。
- `SyncService`：操作の受理、重複排除、server_seq採番、カーソル、スナップショットを扱う。
- `ProjectionUpdater`：同期操作を正本状態、履歴集計、検索インデックスへ反映する。
- `TrashService`：削除、ゴミ箱、復元、完全消去を扱う。
- `BackupService`：整合したDB、設定、履歴のバックアップと復元を扱う。
- `AuditLog`：認証変更、管理操作、破壊的操作を記録する。

サーバーはHTTP JSON APIを公開し、API仕様はOpenAPIで管理する。

APIのバージョンはURLの`/v1`で表し、破壊的変更は新しいメジャーバージョンへ分離する。

標準DBはSQLiteとし、WALモードとマイグレーション履歴を使う。

サーバーを複数プロセスで運用する必要が生じた場合も、操作の一意性とserver_seqの採番を単一のDBトランザクションで保証する。

### クライアント

クライアントは次の層に分ける。

- **UI層**：OS標準の画面、ナビゲーション、アクセシビリティ、キーボード操作を実装する。
- **アプリケーション層**：ライブラリ閲覧、再生制御、ダウンロード、同期、設定のユースケースを実装する。
- **ローカルデータ層**：メタデータ、キャッシュ、未送信操作、同期カーソルをSQLiteへ保存する。
- **OS連携層**：音声セッション、バックグラウンド処理、通知、メディアキー、資格情報保管庫を実装する。
- **通信層**：OpenAPIに従ってAPIを呼び出し、認証更新、再試行、Range取得を扱う。

初期クライアントはmacOSとiPhoneを対象とする。

macOSとiPhoneはSwiftを基本とし、SwiftUIをUIの中心に据え、必要な箇所ではAppKitまたはUIKitを使う。

WindowsはC#とWinUI 3、AndroidはKotlinとJetpack Composeを基本とする。

Figmaでは共通の情報設計、デザイン原則、色、タイポグラフィ、コンポーネント状態を定義する。

戻る操作、メニュー、共有、ウィンドウ、キーボード、バックグラウンド実行などは各OSの標準慣習を優先する。

### 共有同期コア

同期規則は、各クライアントが独自に解釈しないよう、状態遷移仕様、機械可読なテストベクトル、障害シナリオ、適合テストを共通資産として管理する。

Rust共有コアは、次の技術検証でSwift単独実装と比較する。

- 同じ同期シナリオを状態機械として実装できること
- 端末内連番、operation_id、server_seq、再送、重複排除を同じ結果へ収束できること
- Swift、Kotlin、C#とのFFI境界でエラー、キャンセル、スレッド、非同期処理を安全に扱えること
- 各OS向けバイナリの配布、デバッグ、クラッシュ解析、ビルド時間、サイズが許容範囲に収まること
- Rust版の採用によって、個別実装よりテスト対象と障害面積が減ること

Rust版が上記条件を満たした場合だけ、同期状態機械と競合解決を共有コアへ移す。

ネットワーク、ローカルDB、ファイル操作、音声再生、OSライフサイクルは共有コアへ含めない。

## データモデル

以下のDDLは論理スキーマであり、実装時は採用DBの型へ変換する。

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL
);

CREATE TABLE passkeys (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  credential_id BLOB NOT NULL UNIQUE,
  public_key BLOB NOT NULL,
  sign_count INTEGER NOT NULL DEFAULT 0,
  label TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_used_at TEXT,
  revoked_at TEXT
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at TEXT
);

CREATE TABLE refresh_tokens (
  id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  token_hash BLOB NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE tracks (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  file_size INTEGER NOT NULL,
  content_hash BLOB NOT NULL,
  format TEXT NOT NULL,
  codec TEXT NOT NULL,
  duration_ms INTEGER NOT NULL,
  sample_rate INTEGER,
  channels INTEGER,
  bitrate INTEGER,
  title TEXT,
  album TEXT,
  album_artist TEXT,
  artist TEXT,
  genre TEXT,
  year INTEGER,
  disc_number INTEGER,
  disc_total INTEGER,
  track_number INTEGER,
  track_total INTEGER,
  composer TEXT,
  comment TEXT,
  artwork_hash BLOB,
  sidecar_path TEXT,
  state TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX tracks_content_hash_idx ON tracks(content_hash);
CREATE INDEX tracks_artist_album_idx ON tracks(artist, album);
CREATE INDEX tracks_state_idx ON tracks(state);

CREATE TABLE playlists (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  description TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE TABLE playlist_items (
  id TEXT PRIMARY KEY,
  playlist_id TEXT NOT NULL REFERENCES playlists(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  position_key TEXT NOT NULL,
  added_at TEXT NOT NULL,
  deleted_at TEXT
);

CREATE INDEX playlist_items_order_idx
  ON playlist_items(playlist_id, deleted_at, position_key);

CREATE TABLE favorites (
  user_id TEXT NOT NULL REFERENCES users(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  enabled INTEGER NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, track_id)
);

CREATE TABLE ratings (
  user_id TEXT NOT NULL REFERENCES users(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  value INTEGER NOT NULL CHECK (value BETWEEN 0 AND 5),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (user_id, track_id)
);

CREATE TABLE play_events (
  id TEXT PRIMARY KEY,
  operation_id TEXT NOT NULL UNIQUE,
  device_id TEXT NOT NULL REFERENCES devices(id),
  track_id TEXT NOT NULL REFERENCES tracks(id),
  event_type TEXT NOT NULL,
  position_ms INTEGER NOT NULL,
  occurred_at TEXT NOT NULL,
  received_at TEXT NOT NULL
);

CREATE INDEX play_events_track_time_idx
  ON play_events(track_id, occurred_at);

CREATE TABLE sync_operations (
  operation_id TEXT PRIMARY KEY,
  device_id TEXT NOT NULL REFERENCES devices(id),
  device_counter INTEGER NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  operation_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  server_seq INTEGER NOT NULL UNIQUE,
  received_at TEXT NOT NULL
);

CREATE INDEX sync_operations_entity_idx
  ON sync_operations(entity_type, entity_id, server_seq);

CREATE TABLE sync_device_cursors (
  device_id TEXT PRIMARY KEY REFERENCES devices(id),
  acknowledged_server_seq INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
);

CREATE TABLE media_trash (
  id TEXT PRIMARY KEY,
  track_id TEXT NOT NULL,
  original_path TEXT NOT NULL,
  trash_path TEXT NOT NULL,
  deleted_at TEXT NOT NULL,
  purge_after TEXT NOT NULL
);

CREATE TABLE audit_logs (
  id TEXT PRIMARY KEY,
  device_id TEXT,
  action TEXT NOT NULL,
  target_type TEXT,
  target_id TEXT,
  created_at TEXT NOT NULL,
  details_json TEXT NOT NULL
);
```

### 識別子と時刻

すべての内部IDとoperation_idは、端末間で衝突しないランダムなIDを使う。

content_hashはファイル内容の同一性を判定するために使うが、タグ変更やコンテナ変更による同一曲判定には使わない。

端末時刻は表示と分析に保持するが、競合順序の決定には使わない。

同一端末の操作順はdevice_counterで表し、サーバー全体の適用順はserver_seqで表す。

## APIと同期契約

### 主要API

- `POST /v1/auth/passkeys/register/options`：初回登録または追加登録のチャレンジを発行する。
- `POST /v1/auth/passkeys/register/verify`：パスキーを登録し、端末資格情報を発行する。
- `POST /v1/auth/passkeys/login/options`：ログイン用チャレンジを発行する。
- `POST /v1/auth/passkeys/login/verify`：アクセストークンと更新資格情報を発行する。
- `POST /v1/auth/token/refresh`：更新資格情報をローテーションする。
- `POST /v1/sync/push`：未送信操作を受理する。
- `GET /v1/sync/pull?cursor=<server_seq>`：カーソル以降の操作または完全スナップショットを返す。
- `GET /v1/library/tracks`：曲一覧、検索、絞り込みを返す。
- `GET /v1/library/albums`：アルバム一覧を返す。
- `GET /v1/library/artists`：アーティスト一覧を返す。
- `GET /v1/playlists`：プレイリスト一覧と項目を返す。
- `POST /v1/media/{track_id}/stream-url`：短時間有効なストリーミングURLを発行する。
- `POST /v1/media/{track_id}/download-url`：短時間有効なダウンロードURLを発行する。
- `POST /v1/library/imports`：XMLと音源の初回移行を開始する。
- `POST /v1/library/scans`：スキャンを開始する。
- `POST /v1/admin/tracks/{track_id}/trash`：管理者の再認証後に音源をゴミ箱へ移す。
- `POST /v1/admin/trash/purge`：管理者の再認証後にゴミ箱を完全消去する。

### 操作の冪等性

サーバーはoperation_idを一意キーとして保存する。

同じoperation_idを再受信した場合、元の適用結果を返し、状態を二重に変更しない。

サーバーが受理した操作を適用できない場合は、操作を破棄せず、エラーコード、対象エンティティ、再試行可否を返す。

端末は再試行可能なエラーでは操作を保持し、認証失効、対象削除、形式不正など再試行しても成功しないエラーでは利用者へ通知する。

### 同期カーソル

クライアントは最後に完全に適用したserver_seqをカーソルとして保存する。

操作の適用中にアプリが終了した場合は、トランザクションをロールバックし、次回に同じカーソルから取得する。

サーバーがイベントを圧縮してカーソル以前の操作を保持しない場合、クライアントへ完全スナップショットを返す。

イベント圧縮で「全端末が同期確認済み」とみなす対象は、失効していない端末とする。

90日以上接続していない端末は、次回接続時に完全スナップショットを取得し、圧縮済みイベントを再生しない。

### エラーコード

APIはエラー本文に次の機械可読コードを含める。

- `auth_required`：アクセストークンがない、または期限切れである。
- `auth_revoked`：端末または更新資格情報が失効している。
- `reauth_required`：破壊的操作に再認証が必要である。
- `rate_limited`：レート制限に達した。
- `operation_duplicate`：同じ操作を受理済みである。元の適用結果を返す。
- `operation_rejected`：対象の状態や権限により操作を適用できない。
- `media_missing`：原音ファイルが欠損している。
- `media_hash_mismatch`：取得したファイルのハッシュが一致しない。
- `unsupported_format`：再生経路が形式を扱えない。
- `quota_exceeded`：端末の保存上限または空き容量制限を超える。
- `invalid_import`：XMLまたは音源情報を移行処理へ渡せない。
- `migration_failed`：DBマイグレーションに失敗した。
- `server_unavailable`：サーバーへ接続できない。

## 再生履歴

クライアントは次のイベントを保存する。

- `play_started`
- `progress_reached`
- `play_completed`
- `play_skipped`

再生回数は`play_completed`を集計する。

再生エンジンが自然終了を報告した場合、または再生進捗が90パーセントへ到達した場合に`play_completed`を発行する。

同一再生セッションの再送はoperation_idで排除する。

サーバーはイベントを90日間保持し、スナップショットへ集約した後に古いイベントを圧縮する。

再生回数、最終再生日時、スキップ回数はイベントから再計算できる派生値とする。

## メタデータとファイル管理

DBは検索と同期に必要な正本である。

タグを書き込める形式では、管理画面からの編集をDBへ保存した後にファイルへ反映する。

タグ書き込みに失敗した場合、DBの変更を失敗として扱い、元の値と書き込みエラーを監査ログへ残す。

WAVやAIFFなどタグの互換性が限定される形式では、DBとsidecarを正本の可搬表現として保存する。

sidecarの形式は、音源ファイルの相対パス、内部ID、メタデータ、アートワーク参照を含むJSONとする。

サーバーがファイルを自動的に移動またはリネームする機能はMVPに含めない。

## 認証とセキュリティ

### パスキー

パスキーを標準認証とする。

初回セットアップはNAS上のCLIが一度だけ有効な登録コードを発行し、そのコードを使って最初のパスキーを登録する。

復旧はNAS上のCLIによる再登録コード、または事前発行した復旧コードで行う。

パスキーのRP IDは初回設定時の正式なホスト名に固定し、ホスト名変更時は新しいパスキーを登録して移行する。

ネイティブアプリはパスキーで端末登録した後、短期アクセストークンとローテーションする更新資格情報を使う。

更新資格情報はmacOS Keychain、iOS Keychain、Windows Credential Manager、Android Keystoreなど、各OSの安全な保管領域へ保存する。

### 接続保護

本番接続はHTTPSだけを許可する。

localhostのHTTPは開発ビルドに限って許可する。

自己署名証明書は、利用者が明示的に信頼設定した場合だけ許可する。

音源URLは短時間だけ有効な署名付きURLとする。

署名付きURLはアプリのログ、監査ログ、エラーメッセージへ書き出さない。

### 権限と再認証

初期版は単一ユーザーとし、ログイン後の通常操作に細かなロールを設けない。

音源の完全削除、ゴミ箱の消去、全端末失効、サーバー設定変更にはパスキーによる再認証を要求する。

端末は一覧表示し、最終利用日時、OS、失効状態を確認できる。

端末単位の失効は既存の更新資格情報を直ちに無効化する。

認証、登録、再認証の試行回数をIPアドレスと資格情報単位で制限する。

初期既定値は、認証系操作を15分あたり5回、通常APIを端末あたり1分あたり120回とし、管理設定で下げられるようにする。

管理操作、認証変更、音源削除、ゴミ箱消去は監査ログへ記録する。

### プライバシー

テレメトリーは既定で送信しない。

利用者が明示的に同意した場合だけ、個人を直接識別しないクラッシュ情報を送信する。

曲名、ファイル名、音源パス、サーバーURL、履歴イベントはテレメトリーへ含めない。

## エラーと境界条件

- **NAS停止**：キャッシュ済み音源と未送信操作を利用可能にし、再接続後に同期する。
- **認証失効**：ローカル再生を継続し、サーバー操作を停止して再認証画面を表示する。
- **音源欠損**：トラックを欠損状態で表示し、既存の履歴とプレイリスト項目を保持する。
- **ハッシュ不一致**：ダウンロードを不完全として破棄し、再試行を促す。
- **非対応形式**：原音ストリーミングを試行し、再生不能なら互換コピーの生成を要求する。
- **互換コピー生成失敗**：エラー理由を表示し、原音の存在と再試行方法を示す。
- **同期競合**：server_seq順に操作を適用し、操作を破棄せず、適用結果をクライアントへ通知する。
- **DB移行失敗**：更新前スナップショットから復元し、旧サーバー版で再起動できるようにする。
- **容量不足**：明示ダウンロードを削除せず、新規自動キャッシュを停止して利用者へ通知する。
- **不正なXML**：移行処理を中断せず、読めた項目と行番号付きのエラーを結果へ保存する。

## 運用

### 配布

サーバーはDocker Composeで起動できるようにし、メディア領域、DB領域、設定領域、ゴミ箱領域を別ボリュームとして指定する。

単一バイナリ配布では、設定ファイル、DB、メディア領域を外部パスで指定できるようにする。

Navidrome評価では、既存サーバーを置き換えずに検証環境へ導入する。

インターネット公開では、サーバーの前段にTLS終端を行うリバースプロキシまたはトンネルを置き、アプリケーションはHTTPSの公開URLを受け取る。

アプリケーション自身はルーター設定、証明書発行、ポート開放を担当しない。

### バックアップ

バックアップ対象は音源ファイル、DB、sidecar、設定、同期イベント、監査ログとする。

DBと同期イベントは整合したスナップショットとして取得する。

復元手順は、空のサーバーへDBを戻し、音源のハッシュを検証し、sidecarを適用し、端末へ完全スナップショットを配信する順序とする。

### ゴミ箱とイベント圧縮

クライアントからの削除は音源をゴミ箱へ移し、既定では30日後に完全消去する。

ゴミ箱の保持期間は設定で変更できる。

同期イベントはスナップショットと全端末の同期確認後に圧縮し、再生イベントの詳細は90日を超えて保持しない。

### 更新

更新前にDBと設定のスナップショットを自動作成する。

DBマイグレーションは再実行可能にし、失敗時は旧版とスナップショットで復旧する。

音源ファイルの移動や変換をDBマイグレーションへ含めない。

### OSSライセンス

自作のサーバー、クライアント、同期仕様、テスト資産はApache-2.0を第一候補とする。

NavidromeとはAPI連携に限定し、ソースコードをリンクまたは改変した配布物を作らない。

依存ライブラリは公開前にライセンス一覧を作成し、配布形態と互換しない依存は採用しない。

音声デコーダーを追加する場合は、OS標準APIを優先し、外部デコーダーはライセンス条件、動的リンク、再配布条件を確認したうえで採用する。

## 既存ソフトウェアの評価

NavidromeはNAS上の音源管理、再生回数、プレイリスト、評価、OpenSubsonic互換APIを提供するため、最初に適合性を検証する。

検証項目は次のとおりとする。

- MP3、AAC、M4A、ALAC、WAV、AIFFを正しく登録、検索、配信できること
- macOSとiPhoneのクライアントが同じメタデータと原音を取得できること
- オフライン履歴を欠損、重複なく取り込めること
- 履歴、評価、お気に入り、プレイリスト操作の競合を収束させられること
- 端末認証、端末失効、短期URL、再認証を実装できること
- 既存のAPIで不足する機能だけを独自APIまたは補助サーバーで追加できること

すべての項目を満たせない場合は、Navidromeを音源サーバーとして利用し、不足する同期状態と端末管理を補助サーバーで提供する。

サーバー全体を新規実装する判断は、補助サーバーで要件を表現できないことを検証してから行う。

SwinsianはmacOS専用のローカルライブラリ管理と再生の比較対象とする。

SwinsianはWindows、iPhone、Android向けの統一クライアントやNAS同期を提供する比較対象ではない。

## 実装順序

### 技術検証

1. Navidromeを隔離したNAS環境へ導入する。
2. iTunesまたはMusic XMLと音源を小規模な検証ライブラリへ取り込む。
3. macOSとiPhoneで原音再生、ギャップレス再生、音量正規化、Rangeダウンロードを試す。
4. オフライン操作の再送、重複排除、プレイリスト競合を検証する。
5. Swift単独同期実装とRust共有コア実装を同じテストベクトルで比較する。
6. 結果に基づいてNavidrome連携方式とRust採否を確定する。

### MVP

1. サーバーの認証、ライブラリスキャン、検索、メディア配信を実装する。
2. macOSクライアントで閲覧、再生、プレイリスト、お気に入り、履歴、ダウンロードを実装する。
3. iPhoneクライアントで同じ同期契約、バックグラウンド再生、オフライン再生を実装する。
4. macOSとiPhoneを4週間日常利用し、NAS停止、回線切替、アプリ終了、重複再送、復元を検証する。
5. 合格後にWindows、Androidへ適合実装を進める。

## テスト方針

- **同期単体テスト**：操作の順序変更、再送、重複、同時追加、同時削除、同時移動、削除と移動の衝突を検証する。
- **プロパティテスト**：任意の操作列を複数端末へ異なる順序で適用しても、最終状態が一致することを検証する。
- **API統合テスト**：認証、カーソル、ページング、Range配信、署名URL、エラーコードを検証する。
- **移行テスト**：XMLと音源の照合、タグなしWAV、AIFF、重複候補、DRM曲、壊れたXMLを検証する。
- **音声テスト**：ギャップレス境界、無音、長尺、可変ビットレート、非対応形式、互換コピーを検証する。
- **障害テスト**：NAS停止、回線切断、アプリ強制終了、DBマイグレーション失敗、空き容量不足を検証する。
- **セキュリティテスト**：パスキー登録、再認証、端末失効、署名URL期限、レート制限、監査ログを検証する。
- **アクセシビリティテスト**：キーボード操作、スクリーンリーダー、文字拡大、コントラスト、フォーカス順をOSごとに検証する。
- **適合テスト**：各クライアントが共通の同期テストベクトルを通過することをリリース条件とする。

## 成果物

- 本設計仕様書
- OpenAPI仕様
- 論理スキーマとDBマイグレーション
- 同期状態機械の仕様
- 同期適合テストベクトル
- iTunesまたはMusic XML移行ツール
- サーバーのDocker Compose定義
- サーバーのバックアップと復元手順
- macOSネイティブクライアント
- iPhoneネイティブクライアント
- Windowsネイティブクライアント
- Androidネイティブクライアント
- 形式ごとの音声再生適合表
- セキュリティモデルと脅威モデル
- OSSライセンス一覧
- 利用者向けセットアップガイド

## 外部仕様への参照

- [Apple MusicのXML書き出し](https://support.apple.com/ja-jp/guide/music/-mus27cd5060f/mac)
- [MediaPlayerのplayCount](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/playcount)
- [MediaPlayerのlastPlayedDate](https://developer.apple.com/documentation/mediaplayer/mpmediaitem/lastplayeddate)
- [MusicKitのライブラリ操作](https://developer.apple.com/documentation/musickit/musiclibrary)
- [Navidromeの概要](https://www.navidrome.org/docs/overview/)
- [Swinsian 3](https://swinsian.com/blog/2025/08/19/swinsian-3/)

## Current Status

設計インタビューと技術検証を完了した。

製品実装は未着手である。

### Checklist

- [x] 目的、正本、対応OS、MVP境界を確定
- [x] 初回移行とAppleアプリとの共存方針を確定
- [x] 音源形式、メタデータ、sidecar方針を確定
- [x] オフライン同期、競合解決、履歴モデルを確定
- [x] ネイティブクライアント方針を確定
- [x] パスキー認証、端末失効、破壊的操作の再認証を確定
- [x] バックアップ、ゴミ箱、イベント圧縮、更新方針を確定
- [x] Navidrome適合性とRust共有コアの評価基準を確定
- [x] 設計仕様書を作成
- [x] Navidrome技術検証。認証なしの実行はBLOCKEDで、製品ではメディアアダプターに限定する
- [x] Rust共有コア技術検証。7ベクトルの適合性を確認し、製品共有コアには採用しない
- [ ] OpenAPIと同期適合テストの作成
- [ ] macOSとiPhoneのMVP実装
- [ ] 4週間の日常利用検証
- [ ] WindowsとAndroidの適合実装

### Updates

- 2026-08-14：設計インタビューを完了し、NAS正本、ネイティブクライアント、オフライン同期、パスキー認証、MVP除外範囲を確定した。
- 2026-08-14：本仕様書を作成した。実装開始前にNavidromeとRust共有コアの技術検証を行う。
- 2026-08-15：Navidrome、Swift同期、Rust候補、Apple再生の技術検証を完了した。AppleのXCTestとiPhone実機検証はBLOCKEDとして記録した。
- 2026-08-15：サーバー、移行、Appleクライアント、運用の実装計画を作成した。
