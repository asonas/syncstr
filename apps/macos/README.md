# syncstr macOS

Navidrome に接続し、曲一覧から選曲・再生・一時停止する最小の macOS アプリです。
接続先の既定値は https://navidrome.jkte.ch です。
Navidrome のユーザー名とパスワードをアプリ内で入力してください。
HTTPS 接続のみ受け付けます。資格情報は起動中のメモリだけで保持し、ログアウトで破棄します。
一覧取得とストリーミングには OpenSubsonic API を使用します。
音源・メタデータへの書き込みや再生履歴の送信は行いません。

## 起動

Command Line Tools の Swift と macOS SDK を使用します。

```sh
sh apps/macos/build.sh
open apps/macos/.build/Syncstr.app
```

ログイン後、曲名を押すと再生します。下部のボタンで一時停止・再開できます。
曲が終わった後に「再生」を押すと先頭から再生します。
接続に失敗した場合は入力やネットワークを確認して再試行してください。
再生に失敗した場合は曲を選び直してください。
自動で次の曲へ進む機能やオフライン保存はありません。

## API 検証

URLSession の通信境界に固定応答を使用して、ログイン拒否、
ページ分割された曲一覧取得、配信URLの生成を確認します。本番資格情報は不要です。

```sh
mkdir -p apps/macos/.build/module-cache
xcrun swiftc -parse-as-library -module-cache-path apps/macos/.build/module-cache -o apps/macos/.build/navidrome-check apps/macos/Navidrome.swift apps/macos/NavidromeCheck.swift
apps/macos/.build/navidrome-check
```

本番の確認は、ログイン後に試聴用の9曲が表示されること、選曲して音が出ること、
一時停止・再開、曲の切り替え、ログアウトをアプリで確認してください。

## 参照

- [Navidrome の Subsonic API 対応](https://www.navidrome.org/docs/developers/subsonic-api/)
- [OpenSubsonic 認証仕様](https://opensubsonic.netlify.app/docs/api-reference/)
- [曲一覧の取得](https://opensubsonic.netlify.app/docs/endpoints/search3/)
