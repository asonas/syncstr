# 技術検証レポート

このディレクトリには、実装前に行った技術検証の判定を保存します。

## 判定

- [同期コア](sync-core-report.md)：Swiftを基準実装とし、Rust共有コアは不採用
- [Navidrome](navidrome-report.md)：メディア配信の補助アダプターとして扱う。認証済みAPIの実測はBLOCKED
- [Apple再生](apple-playback-report.md)：macOSビルドは成功。XCTestとiPhone実機の再生結果はBLOCKED

## 判定の扱い

BLOCKEDは失敗と同じ意味ではなく、実行条件が満たされず観測できなかったことを示します。

BLOCKEDのケースをPASSへ変更するには、レポートに再現コマンド、実行環境、結果JSON、失敗理由を追記します。

技術検証用の音源、資格情報、DBを製品環境へ流用しません。
