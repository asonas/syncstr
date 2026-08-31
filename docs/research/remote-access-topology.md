# 自宅外からNASへ接続する方式

調査日: 2026-08-31

## 結論

個人利用MVPでは、**専用の正式ホスト名をCloudflare Tunnelの公開HTTPSへ割り当て、syncstr自身のパスキー認証を使う**構成を推奨する。Cloudflare AccessはアプリAPIの前段には置かない。NASの管理面と緊急復旧経路は公開せず、LAN内アクセスに加えてTailscaleを任意の管理経路として用意する。

この判断の主因はパスキーである。syncstrの設計はRP IDを正式ホスト名に固定し、Appleのネイティブアプリからパスキーを使う。Appleはアプリに`webcredentials:<domain>`を設定し、同じドメインの`/.well-known/apple-app-site-association`（AASA）にApp IDを載せることを要求する。[Appleのパスキーサンプル](https://developer.apple.com/documentation/authenticationservices/connecting-to-a-service-with-passkeys) Apple端末は通常、AASAをオリジンから直接ではなくApple管理CDN経由で取得する。CDNが取得するドメインは全IPアドレスから公開到達でき、リダイレクトやアクセスポリシーで遮断されていてはならない。[Associated Domains entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-domains) [TN3155](https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links)

したがって、Tailscaleだけで閉じたホスト名は通常配布するアプリのパスキー基盤として不適切である。`?mode=developer`は開発署名と端末のDeveloper Modeを必要とする開発用迂回路であり、日常利用MVPの本番契約にはできない。公開HTTPSの正式ホスト名なら、アプリはLAN内外で同じURLとRP IDを使え、VPNの接続状態にも依存しない。

## 前提となるsyncstrの契約

- 本番接続はHTTPSだけを許可する。
- パスキーのRP IDは初回設定時の正式ホスト名に固定し、変更時はパスキーの再登録が必要になる。
- 認証後は短期アクセストークンとローテーションする更新資格情報を使う。
- NAS停止中は端末のキャッシュと未送信操作を使い、再接続後に同期する。
- 公開するのは利用者向けAPIだけとし、管理面は内部ネットワークへ閉じる。

このため、ネットワーク方式はアプリ認証を置き換えるものではなく、安定したHTTPS到達性を提供する層として評価する。

## 候補比較

| 方式 | Appleクライアント | パスキー / AASA | TLS証明書 | 運用負荷 | 障害時復旧 |
| --- | --- | --- | --- | --- | --- |
| Cloudflare Tunnel + 公開カスタムホスト名 | 通常の`URLSession`から同じURLへ接続でき、別VPNアプリを要求しない | 公開ホスト名にAASAを置ける。RP IDを自分のドメインに固定できる | エッジ証明書をCloudflareが扱う。NAS側は外向きトンネルだけ | 中。ドメイン、Cloudflare zone、`cloudflared`、トンネル資格情報の管理が必要だが、ルーターのポート開放や動的IP追従は不要 | Cloudflareまたはトンネル停止時は外部接続不能。LAN内の同一API確認と、非公開Tailscale管理経路で診断・再起動する |
| 直接公開HTTPS（Caddy等） | 追加アプリなし。同じ公開URLを利用 | 公開AASAとRP IDの要件を自然に満たす | Caddyは証明書の取得・更新とHTTPからHTTPSへの転送を自動化する | 高。80/443到達性、ポート転送、ファイアウォール、DDNS、CGNAT可否、証明書更新を所有する | 外部事業者への依存はDNS/CA程度。ただし宅内回線・ルーター・公開入口の復旧を自分で行う |
| Tailscale（ServeまたはNASのHTTPS） | iOS/macOSにTailscaleを導入し、VPN On Demandを管理する。別VPNとOn Demandを同時利用できない | 私設ホストはApple CDNからAASAを取得できない。開発モードは本番不可。AASAだけ公開する分割構成は可能だが複雑 | MagicDNSの`*.ts.net`証明書を取得できるが、証明書名はCTログへ公開される | 低〜中。NAS対応はよく、NAT越えを委譲できるが、全Apple端末のVPN状態とtailnet加入を管理する | Tailscale停止・ログアウト・他VPN利用時にアプリ通信も止まる。LANへ戻れば直接復旧できる |
| WireGuardを自前運用 | WireGuardアプリまたは独自Network Extensionが必要 | 私設DNSのままではAASA問題がTailscaleと同じ | 公開信頼TLS、DNS、鍵更新を別に構築する | 高。サーバー鍵、端末設定、NAT/ポート転送、DNS、到達性監視をすべて所有する | SaaS制御面への依存は小さいが、鍵紛失・回線変更・ルーター交換時の復旧手順が最も多い |
| Tailscale Funnel | クライアントVPNなしで公開HTTPSへ接続できる | 公開AASAは成立しうる | `*.ts.net`証明書を自動取得 | 低。ただし2026-08-31時点でbeta、独自ドメイン不可、帯域制限を設定できない | Funnel固有のURL/RP IDに固定され、別方式への移行時にパスキー再登録が必要 |

## 推奨トポロジー

```text
macOS / iPhone
    |
    | HTTPS: https://sync.<owned-domain>
    v
Cloudflare edge
    |
    | Cloudflare Tunnel（NASから開始する外向き接続）
    v
cloudflared on NAS ----> syncstr reverse proxy / API

管理者端末 -- LAN または Tailscale --> NAS管理面
```

Cloudflare TunnelはオリジンからCloudflareへ外向き接続を張るため、公開IPやオリジンの受信リスナーを必要とせず、ファイアウォールの受信を閉じられる。[Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) `cloudflared`はTCP/UDP 7844の外向きHTTP/2またはQUICを使う。[Connectivity options](https://developers.cloudflare.com/cloudflare-one/networks/connectivity-options/)

### 公開面

- `sync.<owned-domain>`を初回設定時の正式ホスト名およびRP IDとする。ホスト名は後から気軽に変えない。
- `/.well-known/apple-app-site-association`を認証なし、リダイレクトなしで公開する。AASAの変更はApple CDNに即時反映されず、端末は概ね週次で更新確認し、直接のCDN invalidation手段はないため、App IDをリリース前に固定する。[TN3155](https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links)
- 公開する経路を利用者向け`/v1`、AASA、最小限のhealth応答に限定する。バックアップ、再登録コード発行、設定変更などの管理面はTunnelの公開hostnameへ流さない。
- Cloudflare Accessを`/v1`の前には置かない。Accessのservice tokenはClient IDとClient Secretという別の静的資格情報をHTTPヘッダーで要求し、syncstrの端末資格情報と二重になる。[Cloudflare service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/) AASAもAccessで保護してはならない。
- 音源レスポンスは`Content-Length`と正しいRange処理を維持する。Cloudflareはオリジン応答に`Content-Length`があればRangeへ206を返し、なければ全体を200で返すため、MVP実機検証で確認する。[Cloudflare cache behavior](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/)
- 認証済み音源・API応答はCloudflareでキャッシュしない設定を明示し、syncstr側の署名URL、失効、監査の契約を維持する。

### 管理面と復旧面

Tailscaleはアプリの通常データ経路ではなく、外出先からNASへ入り`cloudflared`、リバースプロキシ、syncstrを診断する管理経路に限定するとよい。TailscaleはSynology、QNAP、TrueNAS SCALE、Unraid向けのNAS導入経路を案内しており、iOS/macOSではVPN On Demandも利用できる。[NAS接続](https://tailscale.com/kb/1074/connect-to-your-nas/) [VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand)

復旧手順は次の境界で固定する。

1. 公開URLが失敗したら、端末はキャッシュ再生と操作キューを継続し、同期を再試行する。
2. LAN内からNAS上のsyncstrを直接確認し、アプリ本体とTunnel障害を切り分ける。
3. 外出中の管理が必要ならTailscale経由でNASへ入り、`cloudflared`とアプリのhealth、ログ、資格情報期限を確認する。
4. 漏えいまたはNAS再構築時はCloudflare Tunnel tokenを失効・再発行する。これはsyncstrのパスキーや端末更新資格情報の失効とは別の手順として扱う。
5. Cloudflareを長期利用できない場合は、同じ正式ホスト名を別の公開HTTPS入口へ切り替える。RP IDとホスト名を維持すればパスキー移行を避けられる。

## 他方式を主経路にしない理由

### Tailscaleのみ

TailscaleはApple端末とNASの組み合わせ自体には適している。各端末へ安定したIPとMagicDNS名を与え、NAT配下でも接続できる。[Connect to devices](https://tailscale.com/kb/1452/connect-to-devices) iOS/macOSのVPN On DemandはWi-Fi、Cellular、`*.ts.net`ホスト名に応じて接続を自動化できる。一方、Appleの本番パスキーに必要なAASA公開条件と衝突し、他のOn Demand VPNと共存できない。よって、パスキーを既定にするsyncstrの通常経路には採用しない。

独自ドメインのAASAだけを公開ホスティングし、同じドメインのAPIをsplit DNSでTailscaleへ向ける構成も理論上可能である。しかし、公開AASA、私設DNS、DNS-01証明書、全端末のVPNを同時に管理することになり、Tunnelによる単一公開URLよりMVPの障害面が増える。Let's EncryptのDNS-01は非公開Webサーバーにも証明書を発行できるが、DNS API資格情報の保護と自動更新を所有する必要がある。[Let's Encrypt challenge types](https://letsencrypt.org/docs/challenge-types/)

### 直接公開HTTPS

Apple要件には最も素直で、Cloudflareへのデータ経路依存もない。Caddyは公開ドメインに対する証明書取得・更新を自動化する。[Caddy Automatic HTTPS](https://caddyserver.com/docs/automatic-https) ただし家庭内では通常80/443の外部到達、ルーター設定、ファイアウォールが必要である。[Caddy HTTPS quick-start](https://caddyserver.com/docs/quick-starts/https) ISPのCGNATやポート制限がある場合は成立しない。MVPでネットワーク運用を増やす利点がCloudflare Tunnelより小さいため第二候補とする。

### WireGuard自前運用

制御面を自分で所有できる反面、Appleパスキーの公開AASA問題は解決しない。さらに端末VPN、鍵配布、NAT越え、DNS、公開信頼TLSを個別に運用する。Tailscaleが提供するNAT traversal、MagicDNS、VPN On Demand、NASパッケージを自前で置き換える形になるため、個人利用MVPでは採用しない。

### Tailscale Funnel

Funnelはtailnet内サービスをインターネットへ公開し、クライアント側TailscaleなしでHTTPS接続できる。しかし2026-08-31時点でbetaであり、DNS名はtailnetの`*.ts.net`に限定され、ポートと帯域にも制約がある。[Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel) RP IDを所有外の`ts.net`名へ固定することにもなるため、正式ホスト名の長期安定性を重視する本用途ではCloudflare Tunnelに劣る。

## リリース候補へ進むための検証項目

次を満たすまで接続方式を合格扱いにしない。

1. AppleのAssociated Domains診断で`webcredentials:sync.<owned-domain>`とAASAが承認される。
2. iPhone実機とmacOSでパスキーの新規登録、ログイン、再認証、別端末追加、端末失効が通る。
3. LAN、Wi-FiからCellular、CellularからWi-Fiの切替時に、操作キューを失わず再同期する。
4. HTTPS RangeがCloudflare経由で正しい206、`Content-Range`、`Content-Length`を返し、シークと再生再開が通る。
5. Tunnel停止、NAS停止、Cloudflare DNS/TLS不調を個別に模擬し、キャッシュ再生と管理経路からの切り分けを確認する。
6. 公開hostnameから管理エンドポイントへ到達できないこと、AASAだけは未認証で到達できることを確認する。
7. Tunnel tokenの失効・再発行と、同じ正式ホスト名を維持した入口切替をrunbookで一度実演する。

## 決定

- **通常のアプリ経路:** Cloudflare Tunnel上の公開カスタムホスト名。
- **アプリ認証:** syncstr自身のパスキーと端末資格情報。Cloudflare Accessは重ねない。
- **管理・break-glass経路:** LANを必須とし、外出先用Tailscaleを任意で追加する。
- **代替経路:** Cloudflareを採用できない事情が判明した場合のみ、同じ正式ホスト名を保った直接公開HTTPSへ切り替える。
- **採用しない主経路:** Tailscale-only、WireGuard自前、Tailscale Funnel。

この決定により、次の計画では「所有ドメインと正式ホスト名」「Cloudflareアカウント・zone」「NAS上での`cloudflared`実行方式」「非公開の管理経路」「RangeとAASAを含む実機受け入れ」が具体化対象になる。
