# 実装計画の読み方

syncstrの実装は、サーバー、移行、Appleクライアント、運用の境界ごとに分けます。

各計画は、先行する契約とテストを入力にして、独立した受け入れ条件を満たす成果物を出します。

## 計画

- [サーバー](server-plan.md)：認証、スキャン、カタログ、メディア配信、同期、バックアップのAPIとDB
- [移行](migration-plan.md)：iTunesまたはMusic XMLとローカル音源の非破壊照合
- [Appleクライアント](apple-client-plan.md)：macOSとiPhoneのSwiftUI、SQLite、Keychain、AVFoundation
- [運用](operations-plan.md)：Docker Compose、HTTPS、バックアップ、ゴミ箱、監査

## 実装順

1. [マスターロードマップ](../superpowers/plans/2026-08-15-syncstr-implementation-plan.md)のサーバー言語判断とリポジトリ基盤
2. OpenAPIと同期契約
3. サーバーの認証、カタログ、メディア配信
4. XML移行
5. SyncService
6. macOSとiPhone
7. 運用と復元
8. MVP受け入れと日常利用
