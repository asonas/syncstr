# 同期コア評価

## 結論

Rust共有コアは**不採用**とする。

同期仕様の実行モデルはSwift基準実装とする。

Rust実装はJSONベクトル適合性を確認するための破棄可能な候補として保持する。

SwiftとRustは成功3件と拒否4件のJSONベクトルで同じ正規化済みJSONを返した。

しかし、RustをSwiftから呼び出すFFIは未実装である。

そのため、採用条件であるFFI境界の最小呼び出し、エラー伝達、キャンセル、スレッド境界の検証を満たしていない。

FFI導入によるテスト対象または障害面積の削減も測定できない。

## 実行環境

実行日時は2026-08-15T02:13:51+0900（JST）である。

評価対象commitは`fe6c63c52611924531dd6bceaf412cb9b89a2fbe`である。

OSはmacOS 26.6.1（Build 25G76）である。

SwiftはApple Swift 6.3.3である。

Rustはrustc 1.97.1、Cargo 1.97.1である。

JSON比較にはjq 1.8.2を使った。

## 適合性

`make -C validation sync-test`は終了コード0だった。

Swiftのライブラリテストは15件がPASSした。

Rustのテストはengine単体3件と統合7件の合計10件がPASSした。

比較ターゲットは各runnerへ同じ7ベクトルを1件ずつ渡した。

成功3件では`state`、`events`、`differences`が一致した。

拒否4件では両方が`{"error":"operation_rejected"}`を返した。

比較スクリプトは`jq -S -c`でオブジェクトキーと改行を正規化する。

`state.playlist_tombstones.*`は集合なので、その配列だけをソートして比較する。

プレイリスト順とイベント順は状態遷移の意味を持つため、配列順を並べ替えずに比較する。

異なるfixtureに対する比較スクリプトは差分を出し、終了コード1を返した。

逆順の墓標集合fixtureは同値として終了コード0を返した。

拒否ベクトルではSwift CLIが終了コード4、Rust CLIが終了コード1を返す。

Makefileの比較契約は終了コードの一致ではなく、両方が非ゼロであり、標準出力のJSON分類が同じであることとする。

このため、拒否4件はどちらも`{"error":"operation_rejected"}`であることを比較する。

## Fixture

同期ベクトルは次の7件である。

- `sync-vectors/convergence-basic.json`
- `sync-vectors/convergence-conflicts.json`
- `sync-vectors/history-events.json`
- `sync-vectors/rejections/device-counter-regression.json`
- `sync-vectors/rejections/unknown-operation.json`
- `sync-vectors/rejections/missing-required-field.json`
- `sync-vectors/rejections/missing-server-seq.json`

比較scriptのfixtureは次の4件である。

- `scripts/fixtures/compare-expected.json`
- `scripts/fixtures/compare-actual.json`
- `scripts/fixtures/tombstones-expected.json`
- `scripts/fixtures/tombstones-reversed.json`

Swift CLIのerror fixtureは次の2件である。

- `scripts/fixtures/invalid-json.json`
- `scripts/fixtures/expectation-mismatch.json`

明示的failed casesはnoneである。

## Swift CLI

`SyncValidationCLI`はベクトルパスを1件受け取り、成功時には`state`、`events`、`differences`をJSONで標準出力へ出す。

`VectorResult`は`Codable`である。

エラーは標準出力のJSONと終了コードで区別する。

| 条件 | JSON | 終了コード |
| --- | --- | --- |
| 引数不正 | `{"error":"invalid_arguments"}` | 2 |
| パス不存在 | `{"error":"vector_not_found"}` | 3 |
| 不正JSONまたは操作拒否 | `{"error":"operation_rejected"}` | 4 |
| 期待値不一致 | `{"error":"expectation_mismatch"}` | 5 |

不存在パス、不正JSON、期待値不一致をCLIで実行し、それぞれ3、4、5を確認した。

## 測定値

測定日は2026-08-15である。

テスト時間は既ビルド状態で`/usr/bin/time -p`を使って計測した。

| 実装 | テスト数 | 実行時間 | debug CLIサイズ |
| --- | ---: | ---: | ---: |
| Swift | 15 | 2.54秒 | 508,928 bytes |
| Rust | 10 | 0.07秒 | 2,163,600 bytes |

これらの値はdebug buildとローカル環境の測定値であり、リリース性能の比較ではない。

## 再現コマンド

```sh
make -C validation sync-test
make -C validation sync-cli-test
make -C validation sync-compare-test
/usr/bin/time -p swift test --package-path validation/swift-sync --skip-build
/usr/bin/time -p cargo test --manifest-path validation/rust-sync/Cargo.toml
stat -f '%N %z bytes' validation/swift-sync/.build/arm64-apple-macosx/debug/SyncValidationCLI validation/rust-sync/target/debug/vector-runner
```

## FFI評価

| 項目 | 結果 |
| --- | --- |
| 最小FFI呼び出し | 未実装 |
| FFIエラー伝達 | 未検証 |
| FFIキャンセル | 未実装 |
| FFIスレッド境界 | 未検証 |
| テスト対象または障害面積の削減 | 未測定 |

FFIが未実装の状態では、Rust共有コアへの移行根拠はない。

## 配布・パッケージング評価

配布・パッケージングは未測定である。上記のdebug CLIサイズはローカル検証用の
実行ファイルであり、製品向けの配布物を表さない。SwiftからRustを組み込む
XCFramework、static library、Swift Packageのbinary targetはいずれも作成していない。
iOS/macOSの署名、notarization、release artifact size、起動時間、更新・rollback、
Kotlin/C#など他クライアント向けbindingも未評価である。

Rust不採用の根拠として測定または検証すべき項目は次のとおりであり、JSONベクトル
適合性以外は未測定または未実装である。

| 項目 | 現状 |
| --- | --- |
| JSONベクトル適合性 | Swift/Rustとも7ベクトルで確認済み |
| 最小FFI呼び出し | 未実装 |
| FFIエラー伝達 | 未検証 |
| FFIキャンセル | 未実装 |
| FFIスレッド境界 | 未検証 |
| テスト対象または障害面積の削減 | 未測定 |
| release性能・サイズ | 未測定 |
| 配布物の構築・署名・notarization | 未測定 |
| クライアントbindingと配布 | 未測定 |
| 更新・rollbackの運用性 | 未測定 |

## 採否の実装計画への反映

次段階ではSyncServiceをサーバーの正本とし、Swiftクライアントは機械可読な
ベクトル契約を独自実装する。Rust候補は適合性検査用に限定し、製品の共有コア、
FFI、配布物には含めない。release性能、FFI、障害面積、配布・パッケージングは
未測定のままである。
