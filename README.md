# syncstr

NASを正本とする個人向け音楽ライブラリと、複数端末の再生状態を同期するネイティブ音楽プレイヤーです。

macOS、Windows、iPhone、Androidで同じライブラリを参照し、端末がオフラインの間もダウンロード済みの音源を再生できます。

## 現在地

設計と技術検証を完了し、製品実装を開始する準備段階です。

- サービス仕様：[docs/design-spec.md](docs/design-spec.md)
- サービス概要：[docs/service-overview.md](docs/service-overview.md)
- 設計判断：[docs/decisions.md](docs/decisions.md)
- 設計インタビュー記録：[docs/grill-me.md](docs/grill-me.md)
- 実装ロードマップ：[docs/superpowers/plans/2026-08-15-syncstr-implementation-plan.md](docs/superpowers/plans/2026-08-15-syncstr-implementation-plan.md)
- 技術検証：[docs/validation/](docs/validation/)

## 製品の境界

サーバーはNAS上の音源、メタデータ、プレイリスト、評価、再生履歴の正本を保持します。

クライアントは音源キャッシュと未送信操作を保持し、接続が復旧した時点で同期します。

初回移行ではiTunesまたはMusicのXMLとローカル音源を照合します。

Apple MusicまたはiTunesとの継続的な双方向同期は行いません。

DRM保護された音源とApple Musicのクラウド上だけに存在する曲は対象外です。

## 対応形式

初期対応形式はMP3、AAC、M4A、ALAC、WAV、AIFFです。

原音を優先し、端末が再生できない場合だけ互換コピーまたはサーバー変換を検討します。

WAVとAIFFのようにタグを書き込めない音源は、DBとsidecarでメタデータを保持します。

## 実装方針

- クライアントは各OSのネイティブAPIで実装します。
- macOSとiPhoneを最初の縦切りにします。
- WindowsとAndroidは共通同期契約に適合する後続クライアントとします。
- Navidromeはメディア配信の補助アダプターとして扱います。
- Rustの共有同期コアは採用せず、各クライアントは共通のテストベクトルに適合させます。
- 認証はパスキーを既定とし、端末単位の資格情報失効を実装します。

## 開発を始めるとき

1. [設計仕様](docs/design-spec.md)と[未解決の論点](docs/grill-me.md)を確認します。
2. [実装ロードマップ](docs/superpowers/plans/2026-08-15-syncstr-implementation-plan.md)の最初の判断ゲートを完了します。
3. 同期契約とOpenAPIを先に固定します。
4. サーバー、macOS、iPhoneを独立したテストサイクルで実装します。

## ライセンス

ライセンスは実装開始前に決定します。
