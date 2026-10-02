# syncstr macOS

Navidrome に接続し、アルバム・アーティスト・曲から音楽を選んで再生する macOS アプリです。
接続先の既定値は https://navidrome.jkte.ch です。
Navidrome のユーザー名とパスワードをアプリ内で入力してください。
HTTPS 接続のみ受け付けます。ログイン成功時に接続先・ユーザー名・パスワードをこの Mac の Keychain に保存します。
次回起動時は保存情報で自動ログインします。接続中は待機画面を表示し、失敗時はログイン画面へ戻ります。
ログアウトはアプリの「設定…」（Command+,）にあります。確認後に再生を停止し、Navidromeの保存情報を削除します。
一覧取得とストリーミングには OpenSubsonic API を使用します。
再生履歴の送信と既存音源のメタデータ編集は行いません。

## アップロード

上部の「音楽をアップロード」ボタンから音楽ファイルを複数選択して送信できます。
[Rustのアップロードサービス](https://github.com/asonas/syncstr-uploader-deployment)をNAS上に配置し、HTTPSで公開してください。
アップロード先の既定値は `https://syncstr-uploader.jkte.ch` です。
アプリの「設定…」（Command+,）またはアップロード画面の「アップロード設定…」で、URLと専用トークンを入力して「保存」を押します。
アップロード前に専用のKeychain serviceへ保存し、次回以降は保存済みの接続情報を使用します。Navidromeのユーザー名・パスワードとは別の認証です。
Navidromeからのログアウトとは独立しており、設定の「保存した接続情報を削除」で削除できます。

転送は1ファイルずつ行い、完了件数と処理中のファイル名を表示します。
失敗した場合は完了済みを除いた残りを再試行できます。同名ファイルは上書きしません。
元ファイルの内容とチェックサムがずれないよう、一時コピーを作成して送ります。ファイルサイズ分の空き容量が必要です。
形式検証を通ったファイルだけがサーバーへ保存されます。Navidromeのスキャン後にライブラリを再読み込みしてください。
初期版はアプリ実行中の転送のみ対応し、バックグラウンド転送・途中再開・フォルダ選択には対応していません。

## 起動

SwiftとmacOS SDKを使用します。SwiftUIマクロが必要なSDKではXcodeのDeveloperディレクトリを指定してください。
署名には、この Mac の Keychain にある `Apple Development: Yuya Fujiwara (55CYFEJC5B)` 証明書と秘密鍵が必要です。
再ビルド後も Keychain のアクセス許可を引き継ぐため、同じ証明書と bundle ID で署名します。
アドホック署名のビルドから切り替えた初回は、保存済みログイン情報へのアクセス確認で「常に許可」を選んでください。

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer sh apps/macos/build.sh
open apps/macos/.build/Syncstr.app
```

ログイン後はアルバムを表示します。アルバムを開き、曲名を押すと再生します。
サイドバーでアルバム・アーティスト・曲を切り替えられます。上部の検索欄はライブラリ全体が対象です。
サイドバーを閉じても表示中の画面は維持します。下部の曲名から同じウィンドウの再生中画面を開けます。

下部のボタンで前の曲・一時停止／再開・次の曲を操作し、シークバーで再生位置を変更できます。
再生順は曲を選んだ一覧の順番です。アルバムではディスク番号・曲番号順に並びます。
検索や画面移動で再生順は変わりません。曲が終わると次へ進み、最後の曲で停止します。
最後の曲が終わった後に「再生」を押すと、その曲を先頭から再生します。
接続に失敗した場合は入力やネットワークを確認して再試行してください。
再生に失敗した場合は曲を選び直してください。
プレイリスト編集・ダウンロード・履歴・オフライン保存は未実装です。

画面構成は [Apple MVP 操作モデルの決定](https://github.com/asonas/syncstr/issues/5#issuecomment-5472974010)に沿っています。

## API 検証

アップロードのHTTPヘッダー、SHA-256、ファイル名のエンコード、確定応答、重複拒否、HTTPS制限を通信境界で確認できます。

```sh
mkdir -p apps/macos/.build/module-cache
xcrun swiftc -parse-as-library -module-cache-path apps/macos/.build/module-cache -o apps/macos/.build/upload-check apps/macos/Upload.swift apps/macos/UploadCheck.swift
apps/macos/.build/upload-check
```

URLSession の通信境界に固定応答を使用して、ログイン拒否、
ページ分割された曲一覧取得、配信URLの生成を確認します。本番資格情報は不要です。

```sh
mkdir -p apps/macos/.build/module-cache
xcrun swiftc -parse-as-library -module-cache-path apps/macos/.build/module-cache -o apps/macos/.build/navidrome-check apps/macos/Navidrome.swift apps/macos/NavidromeCheck.swift
apps/macos/.build/navidrome-check
```

## 再生・Keychain の検証

API だけを固定応答へ置き換え、実際の AVPlayer と短い無音ファイルで前後移動・連続再生・末尾停止・シークを検証します。
Keychain は実行ごとに異なる `as.ason.syncstr.test.*` service の架空の資格情報を使い、終了時に削除します。
通常の保存情報は読み書きしません。Keychain と音声サービスへアクセスできる macOS 環境で実行してください。

```sh
xcrun swiftc -parse-as-library -module-cache-path apps/macos/.build/module-cache -o apps/macos/.build/library-check apps/macos/Library.swift apps/macos/Navidrome.swift apps/macos/CredentialStore.swift apps/macos/LibraryCheck.swift
apps/macos/.build/library-check
```

本番の確認は、ログイン後に試聴用の9曲が表示されること、選曲して音が出ること、
一時停止・再開、曲の切り替え、シーク、アプリ再起動後の入力復元、ログアウト後の保存情報削除をアプリで確認してください。

## 参照

- [Navidrome の Subsonic API 対応](https://www.navidrome.org/docs/developers/subsonic-api/)
- [OpenSubsonic 認証仕様](https://opensubsonic.netlify.app/docs/api-reference/)
- [曲一覧の取得](https://opensubsonic.netlify.app/docs/endpoints/search3/)
