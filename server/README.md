# Syncstr Upload

Syncstrから音楽ファイルを受け取り、Navidromeが参照する音楽フォルダへ保存するRustサービスです。
NavidromeへのAPIプロキシではありません。既存の音源やタグの編集は行いません。

## 配置

HTTPSはCloudflare Tunnelなどのリバースプロキシで終端し、内部HTTPポート4545へ接続します。
内部HTTPをインターネットへ直接公開しないでください。macOSクライアントはHTTPSのみ受け付けます。

`compose.yaml`はNASへの配置例です。実行UID/GIDとホスト側のパスを確認してください。
管理者がmusicとupload-stagingを事前に作成し、実行ユーザーの書き込みを許可します。
stagingは音楽フォルダの外、かつ同じファイルシステムに置きます。
確定にはhard linkを使うため、別ファイルシステムの場合は保存に失敗します。
Navidrome側の音楽マウントは読み取り専用を維持します。

`server/secrets/upload-token`にランダムなトークンを保存します（32文字以上のASCII可視文字、推奨32バイト以上の乱数をhex化）。
このファイルはGit・Docker build contextから除外しています。コンテナの実行ユーザーが読み取れる権限を設定してください。
トークンはNavidromeのパスワードとは独立しています。初期版は1つの共有トークンで、端末単位の失効はありません。
ローテーション時はファイルを差し替えてサービスを再起動し、各端末の設定を更新します。

環境変数:

| 変数 | 値 |
| --- | --- |
| `SYNCSTR_TOKEN_FILE` | トークンファイル（必須） |
| `SYNCSTR_MUSIC_DIR` | 確定先ディレクトリ（必須） |
| `SYNCSTR_STAGING_DIR` | 一時保存ディレクトリ（必須） |
| `SYNCSTR_BIND` | 既定 `127.0.0.1:4545` |
| `SYNCSTR_MAX_UPLOAD_BYTES` | 既定1 GiB、ファイル単位 |

ffprobeをPATHに配置してください。Dockerイメージには同梱します。
アップロードは最大2件を同時処理し、受信は15分、形式検証は30秒で打ち切ります。
プロキシ側のリクエストサイズ・タイムアウトも確認してください。
Cloudflare経由の場合は契約プランのリクエスト上限も適用されます。初期版に分割・途中再開はありません。

## API

`PUT /v1/uploads/{filename}` にファイル本体をそのまま送ります。

- `Authorization: Bearer <token>`
- `Content-Length`: ファイルサイズ
- `X-Content-SHA256`: 本体のSHA-256（64桁hex）

成功は201と `{"filename":"song.mp3","bytes":123,"sha256":"…"}` です。
確定した時点の応答であり、Navidromeでのスキャン完了は意味しません。
追加した曲はNavidromeのスキャン後にクライアントでライブラリを再読み込みしてください。
エラーは `{"error":"invalid_audio"}` のようなJSONです。

| HTTP | 意味 |
| --- | --- |
| 400 | 不正なファイル名、チェックサム指定、転送サイズ不一致・中断 |
| 401 | トークン不一致 |
| 409 | 同名のエントリが存在（上書きしない） |
| 411 | サイズ指定なし |
| 413 | サイズ制限超過・本体が指定サイズを超過 |
| 422 | チェックサム不一致・音声形式検証に失敗 |
| 429 | 同時処理数超過 |
| 408 | 受信タイムアウト |
| 500 | 保存先・ffprobeなどサーバー側のエラー |

保存先は設定された音楽フォルダ直下に固定します。サブフォルダ指定、パス区切り、隠しファイル、Windows予約名は拒否します。
初期対応の拡張子はmp3、aac、m4a、alac、wav、aiff、aif、flac、ogg、opusです。
ffprobeには拡張子に対応するdemuxerを固定し、音声ストリームがあること、動画などが含まれないことを確認します。
埋め込みのアルバムアートは許可します。プレイリストやネットワーク入力としての解釈は許可しません。
これは形式検証であり、ウイルス検査や全曲の完全デコードによる破損検査ではありません。

一時ファイルは受信・検証中にmusicから見えず、失敗・キャンセル時に削除します。
正常終了したファイルだけを上書きなしで公開します。同時に同名が到着した場合も片方が409になります。
プロセスの強制終了・停電ではstagingに残ることがあるため、停止中に残存ファイルを確認・削除してください。
応答を受け取る前に接続が切れた場合、再送で409になることがあります。その場合は保存先を確認してください。
音源はUnixでは0644で確定します。musicとstagingを変更できる管理者・ホストプロセスは信頼境界内です。

## 検証

ffprobeが必要です。テストは一時ディレクトリだけに書き込みます。

```sh
mise exec -- cargo test --manifest-path server/Cargo.toml
mise exec -- cargo clippy --manifest-path server/Cargo.toml --all-targets -- -D warnings
mise exec -- cargo fmt --manifest-path server/Cargo.toml --check
```
