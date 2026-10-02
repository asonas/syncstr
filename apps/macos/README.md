# syncstr macOS

Navidrome に接続し、アルバム・アーティスト・曲から音楽を選んで再生する macOS アプリです。
接続先の既定値は https://navidrome.jkte.ch です。
Navidrome のユーザー名とパスワードをアプリ内で入力してください。
HTTPS 接続のみ受け付けます。ログイン成功時に接続先・ユーザー名・パスワードをこの Mac の Keychain に保存します。
次回起動時はログイン欄に復元します。ログアウトすると保存情報を削除します。
一覧取得とストリーミングには OpenSubsonic API を使用します。
音源・メタデータへの書き込みや再生履歴の送信は行いません。

## 起動

Command Line Tools の Swift と macOS SDK を使用します。

```sh
sh apps/macos/build.sh
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
