# syncstr iPhone

Navidrome の音楽を iPhone で選んで再生する SwiftUI アプリです。iOS 26 以降を対象とします。
macOS の `Library.swift`、`Navidrome.swift`、`CredentialStore.swift` を同じソースとしてビルドします。

## 起動

Xcode と iOS Simulator を使用します。`project.yml` は XcodeGen の生成元です。

```sh
mise exec -- xcodegen generate --spec apps/ios/project.yml
open apps/ios/Syncstr.xcodeproj
```

Xcode で `Syncstr` scheme と iPhone Simulator を選び、Run します。
初回はアプリ内で Navidrome のアカウントを入力します。資格情報は iPhone / Simulator の Keychain に保存し、次回から自動ログインします。
Mac 側の Keychain の資格情報は転送しません。

実機の場合は Xcode の Signing & Capabilities で利用者の Team を選び、接続した iPhone を実行先にします。
署名は Yuya Fujiwara の Team `QYP65434UW`、Bundle ID `as.ason.syncstr.ios` を使用します。
資格情報や署名の秘密鍵はリポジトリへ保存しません。

## TestFlight と Xcode Cloud

`project.yml` を生成元として Git 管理し、生成済みの project・workspace・共有 scheme は Git に含めません。
Cloud は `ci_scripts/ci_post_clone.sh` で XcodeGen を用意して、clone 後に同じ場所へ project と scheme を生成します。
Cloud 接続情報の `Syncstr.xcodeproj/xcshareddata/xcodecloud/manifest.json` は Git 管理を続けます。
初回は Xcode の Integrate → Create Workflow から `Syncstr iOS` を選択して、このリポジトリを接続します。

配布ワークフローは次の構成にします。

- ソース: `asonas/syncstr` の `main`
- Project: `apps/ios/Syncstr.xcodeproj`、scheme: `Syncstr`
- 開始条件: `main` への変更
- Action: iOS の Archive、TestFlight の内部テスト配布
- Post-action: 本人用の内部テストグループへ配布

「プロジェクトまたはワークスペース」は生成後の `apps/ios/Syncstr.xcodeproj` を指定します。
`apps/ios` ディレクトリや `project.yml` は指定しません。

同じ生成元にはmacOS配信用の `SyncstrMac` schemeも含まれます。macOSの配布設定は [macOS README](../macos/README.md#testflight-と-xcode-cloud) を参照してください。

Cloud の設定と初回ビルドの完了は、ローカルのビルド成功とは別に App Store Connect で確認します。

アイコンは [採用原図](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=12-2) から書き出しました。
原図を保持したまま、[iOS 用の 1024px フレーム](https://www.figma.com/design/KtfBubkg9KiK5LuLHIm8Qt?node-id=15-2) で背景を全面に広げています。角丸は OS が適用します。

## 最初の操作範囲

- ライブラリはアルバムから開始し、アルバム内の曲・全曲・アーティストを閲覧できます。
- 検索タブは曲、アルバム、アーティストを対象にします。
- 曲を選ぶと一覧順に再生します。ミニプレイヤーから再生中タブへ移れます。
- 再生中では一時停止・再開、前後の曲、シークを操作できます。
- 曲一覧の雲と下矢印は未ダウンロード、スピナーはダウンロード中、丸とチェックは保存済みです。雲のボタンで端末へ保存します。曲名のタップは再生を開始し、準備中は曲名の横にスピナーを表示します。
- 保存した曲は端末のファイルを優先して再生します。保存状態は再起動後も復元し、接続先とアカウントごとに分けます。ログアウトしても音源は保持します。起動時のライブラリ取得にはサーバー接続が必要です。
- ロック画面・コントロールセンターには曲名、アーティスト、再生位置を表示し、再生・一時停止、前後の曲、シークを操作できます。
- 設定では再読み込みとログアウトを行えます。ログアウトでこの端末の保存資格情報を削除します。
- 再生開始時に AudioSession の playback category を有効にします。background audio を宣言していますが、実機での画面ロック・経路変更・割り込みは実機確認が必要です。

キュー編集、オフライン起動時のライブラリ閲覧、プレイリスト、お気に入りは対象外です。

保存状態のアイコンは [Regen Icons](https://github.com/kazdenc/regen-icons) の `cloud-download` と `circle-check` を使用しています。MIT ライセンスを `Licenses/RegenIcons.txt` に保持し、アプリへ同梱します。

## 検証

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/ios/Syncstr.xcodeproj -scheme Syncstr \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath apps/ios/.build/DerivedData CODE_SIGN_IDENTITY=- test
```

固定 API 応答とテスト専用の Keychain service で、自動ログイン・ライブラリ取得・ログアウトを検証します。
テスト用音源で保存状態の復元、アカウント分離、AVPlayer のローカル読み込み、Now Playing 情報の更新も検証します。
本番資格情報はテストに使いません。
手動ではログイン、アルバム表示、追加済みの Voyager の選曲、音声、シーク、再起動後の自動ログインを確認してください。
Simulator の成功は iPhone 実機での再生成功とは分けて記録します。
TestFlight では未保存の曲のストリーミング、雲ボタンからの保存、保存済み表示、画面ロック後の再生継続・ロック画面操作を確認してください。端末の保存曲の再生は、ライブラリ表示後にネットワークを切った状態でも確認できます。
