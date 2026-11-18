# Onboarding and connection states

Status: designed for [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md), accepted on 2026-11-18. Nothing in this document is implemented, and it authorizes no production operation.

This document specifies what a listener sees and does in the macOS and iOS apps when a host serves the library over Tailscale. It covers first launch, connecting a device, connection states, downloads, and settings. It answers ASO-167 and the listener-facing half of ASO-166, and it gives the interface for ASO-162, ASO-163, and ASO-164. The exchanges behind the screens are in [Host API design](host-api-design.md), mirrors are in [Mirrors and the primary switch](mirrors-and-primary-switch.md), and the listener's guide to a tailnet is [Tailscale setup](tailscale-setup.md).

In the first release the host and the phone both join Tailscale, and the tailnet policy decides which devices reach the host. A device opens the library by the host address. A QR code or a link only carries that address and grants nothing, so Syncstr has no pairing, no device list, and no removal of a device. The owner gives and withdraws access in Tailscale.

On iPad the iOS app follows the iPhone design, so "iPhone" below includes the iPad. The apps' interface strings are Japanese literals in the SwiftUI sources, with no string catalog. Every string here is a Japanese draft with an English gloss. Final wording and presentation follow [DESIGN.md](../DESIGN.md) and are checked on the screen. The examples use `studio` for a Mac host, `nas` for a NAS host, and `studio.example.ts.net` for a host address.

## Keep the network out of sight

A listener never sees or types a certificate, a node ID, or an address file, and sees a port only in a host address that has one other than 443. After the first connection a device never asks which host to use. The host address appears in the Mac's settings, in the publish confirmation, and in the QR code that a device scans. A listener types it only on a device that cannot scan the code.

The network is named at three moments:

- When the listener lets a Mac accept connections from other devices.
- When connecting or a later request fails and the network is the likely reason.
- When a listener without Tailscale asks how to listen away from the host.

A connected device says nothing about its connection, because DESIGN.md asks the apps not to show state that needs no action.

One exception exists. On a Mac host, the listener copies a command that contains a port ([the publish confirmation](#the-publish-confirmation)). The exception lasts until open question 1 is answered.

## Words in the interface

| Design term | Japanese draft | Note |
| --- | --- | --- |
| Library, device | ライブラリ, 端末 | As today. |
| Connecting a device to a host | 接続 | Replaces ペアリング, which suggests a step that grants access. |
| Offline save, playback cache | 保存, この端末に保存, 保存済み, 再生キャッシュ | As today. |
| All offline saves together | 保存した音楽 | As today in iPhone settings. |
| Host | The host's own name. ホスト only as a settings label. | A message names the machine the listener knows. |
| Mirror | ミラー, on a host only | A device names each host by its name. |
| Private network | プライベートネットワーク | New. |
| A host serving devices | ほかの端末からの接続を受け付ける | Not 公開, which reads as "published on the internet". |
| Download | No word of its own. A save shows 保存中, and playback keeps its preparation label. | One act, one word. |

The words of the old design leave the interface: 参加, 招待, ペアリング, 保存先 in the sense of a host, 接続先, 端末ID, 中継, 競合, and 従来の接続. A device never shows "primary" or "mirror".

## First launch on the Mac

Today the empty window in [Syncstr.swift](../apps/macos/Syncstr.swift) (lines 65-74) offers 既存のライブラリに参加, 音楽フォルダを選ぶ, 音楽ファイルを追加, and 保存したライブラリを開く. The new window keeps its title, 自分の音楽を、どの端末でも, and its local choices. **NASや別のMacのライブラリに接続…** ("Connect to a library on a NAS or another Mac") replaces the first button. The body becomes このMacの音楽を聴くか、NASや別のMacにあるライブラリに接続します。 ("Play the music on this Mac, or connect to a library on a NAS or another Mac."). The app holds one library at a time, as today.

### Music on this Mac

1. The listener chooses a music folder or adds files. The app shows 音楽を読み込み中… as today.
2. The library appears. No host runs yet.
3. Above the album grid, one line reads このライブラリをiPhoneでも聴けます。 ("You can listen to this library on your iPhone too."), with **iPhoneを追加…** ("Add iPhone") and **今はしない** ("Not now").
4. **iPhoneを追加…** starts [Add a device from the Mac](#add-a-device-from-the-mac). When that flow ends, the library is served and the phone is connected.
5. **今はしない** hides the line for good. The same action stays in Settings under 端末.

Serving starts from the wish to add a phone, not from import, which extends the rule in [cluster-ui-review.md](cluster-ui-review.md) that import does not make a machine a host. A listener who only plays locally never meets a host screen. ASO-167 asks that first launch reach a served library, and this design reaches it through the offer that appears with the library.

### Music on a NAS or another Mac

1. The listener chooses **NASや別のMacのライブラリに接続…**.
2. A sheet asks for the host address, such as `nas.example.ts.net`, and accepts a `syncstr://open` link too. It adds `https://` when the listener leaves it out.
3. Opening the link anywhere on the Mac, such as from AirDrop, goes straight to step 4.
4. The app reads the library information. A confirmation names the host, with **接続** ("Connect") and **キャンセル**.
5. The library appears. Playing a track downloads it to the playback cache, as today.

| Element | Japanese draft | Gloss |
| --- | --- | --- |
| Sheet | ライブラリのあるNASやMacのアドレスを入力してください。 | Enter the address of the NAS or Mac that has the library. |
| Confirmation | nas.example.ts.net のライブラリ「Music」に接続しますか？ | Connect to the library Music on nas.example.ts.net? |
| After connecting | iPhoneでも聴くには、iPhoneで同じアドレスを開いてください。 | To listen on your iPhone too, open the same address on the iPhone. |

The Mac is then a device, and its save controls work as on the iPhone. It shows the last line instead of the **iPhoneを追加…** offer, because the host, not this Mac, serves the library.

### Local playback only

A listener who adds music and chooses **今はしない** keeps today's local product. A local-only Mac shows no connection state. It is not "not connected", because nothing is missing.

## Add a device from the Mac

This flow runs on a Mac whose library is local. It starts from **iPhoneを追加…** or from **端末を追加…** ("Add device") in Settings.

1. If the Mac has no host address yet, the app checks Tailscale on this Mac.
   - If Tailscale is connected, the app shows [the publish confirmation](#the-publish-confirmation).
   - If Tailscale is off or logged out, the sheet asks the listener to open it, with **Tailscaleを開く** ("Open Tailscale"). The sheet goes on by itself when Tailscale connects.
   - If Tailscale is not installed, the sheet shows [the recommendation](#recommend-tailscale).
2. The app starts the host. After the listener runs the copied command, the app checks from this Mac that the host address answers. A failure shows its cause from the [host states](#on-the-mac-as-a-host).
3. The connect sheet shows a QR code of the host address, the address as selectable text, **リンクをコピー** ("Copy link"), and **共有…** ("Share"). The code does not expire, and any number of devices can use it.
4. The sheet reminds the listener that the iPhone must reach this Mac over Tailscale and be allowed by the access settings, either on the same tailnet or through a share of this Mac, with **Tailscaleのアクセス設定を開く** ("Open Tailscale access settings"), which opens the admin console in the browser. Only the iPhone itself can show that it is allowed. **完了** ("Done") closes the sheet.

| Element | Japanese draft | Gloss |
| --- | --- | --- |
| Tailscale off | Tailscaleがオフです。Tailscaleを開いてログインすると、続きに進みます。 | Tailscale is off. Open Tailscale and log in to continue. |
| Checking | 接続を確認しています… | Checking the connection. |
| Connect sheet | iPhoneのカメラでこのQRコードを読み取ってください。先にiPhoneにTailscaleとSyncstrを入れてください。 | Scan this QR code with the iPhone camera. Install Tailscale and Syncstr on the iPhone first. |
| Access | Tailscaleでこのライブラリへのアクセスを許可した端末だけが接続できます。 | Only devices that you allow to reach this library in Tailscale can connect. |

The host shows no approval and no list of devices, because it cannot tell devices apart. Access is given and withdrawn in the tailnet policy. This replaces the "pairing approval" of DESIGN.md's macOS guidance, which describes the old Mac-to-iPhone transfer.

### The publish confirmation

One sheet sets up `tailscale serve`. It is the only confirmation in the flow. It says the two things the app cannot do itself, and it gives the one command the listener runs.

The distributed macOS app is sandboxed (`com.apple.security.app-sandbox` in [Syncstr.entitlements](../apps/macos/Syncstr.entitlements)), so it may be unable to run the `tailscale` command or reach Tailscale's LocalAPI. The sheet therefore shows the command with **コマンドをコピー** and the line ターミナルでこのコマンドを実行してください。Syncstrが自動で確認します。 ("Run this command in Terminal. Syncstr checks the result by itself."). The command is `tailscale serve --bg` with the port that [Host API design](host-api-design.md#loopback-only-published-by-serve) sets, and the listener pastes it without reading it. The app then watches the address and continues at step 3. Whether one confirmation can configure Serve without the command is open question 1.

| Element | Japanese draft | Gloss |
| --- | --- | --- |
| Title | Tailscaleでこのライブラリに接続できるようにしますか？ | Let devices connect to this library over Tailscale? |
| Scope | Tailscaleのアクセス設定でこのMacに届く端末は、すべてこのライブラリを聴けます。インターネットには公開しません。 | Every device that your Tailscale access settings let reach this Mac can listen to this library. Nothing is published to the internet. |
| Address | iPhoneは studio.example.ts.net に接続します。 | The iPhone connects to studio.example.ts.net. |
| HTTPS | tailnetでHTTPSをオンにする必要があります。Syncstrからは変更できません。 | HTTPS must be on for the tailnet. Syncstr cannot turn it on. A button opens the Tailscale admin console. |
| Certificate log | 証明書を発行すると、このMacの名前 studio.example.ts.net が公開の記録に載り、誰でも見られます。載った名前は消せません。名前を変える場合は、先にTailscaleでこのMacの名前を変更してください。 | Issuing the certificate puts this Mac's name in a public log that anyone can read, and it cannot be removed. To use another name, rename this Mac in Tailscale first. |
| Access | コマンドを実行する前に、Tailscaleのアクセス設定で、このMacに届く端末を確かめてください。 | Before running the command, check in your Tailscale access settings which devices can reach this Mac. |
| Buttons | Tailscaleのアクセス設定を開く, コマンドをコピー, キャンセル | Open Tailscale access settings, Copy command, Cancel. |

The scope and access lines come before the command because a rule that already exists may let other devices in the moment Serve starts, and Syncstr adds no check of its own to the tailnet policy. The listener never sees or compares a certificate.

## First launch on the iPhone

Today the empty library offers 既存のライブラリに参加 and 音楽ファイルを追加 ([PhoneRoot.swift](../apps/ios/Sources/PhoneRoot.swift), lines 239-248). The new empty library tab shows MacやNASの音楽を聴く ("Listen to music from your Mac or NAS") and ライブラリのあるMacで「iPhoneを追加」を選び、表示されたQRコードをこのiPhoneのカメラで読み取ります。 ("On the Mac that has the library, choose Add iPhone, then scan the QR code with this iPhone's camera."). It offers **QRコードを読み取る** ("Scan QR code"), **アドレスを入力** ("Enter address"), **音楽ファイルを追加** for local playback as today, and **Tailscaleを使っていない場合** ("If you don't use Tailscale").

1. The listener scans the QR code with the iPhone camera or with **QRコードを読み取る**, types the host address, or opens a link received by AirDrop or Messages. Each path opens Syncstr at step 2.
2. The sheet shows 接続しています… ("Connecting") while the phone reads the library information.
3. The sheet asks studio.example.ts.net のライブラリ「Music」に接続しますか？ ("Connect to the library Music on studio.example.ts.net?"), with **接続** and **キャンセル**. A link can come from someone else, so one tap on the phone confirms the host. The sheet names the host by its address, which the answering host does not choose. After that the apps call the host by the first part of the address, such as 「studio」.
4. The library appears, and artwork fills in as it downloads.
5. Once, at the top of the library landing, a line reads 保存した音楽は、「studio」に接続できないときも聴けます。アルバムやプレイリストの保存ボタンで保存します。 ("Saved music plays even when studio is unreachable. Save an album or a playlist with its save button."). It offers **ライブラリ全体を保存…** ("Save the whole library") and **閉じる**.

The QR code holds the custom `syncstr:` link that [Host API design](host-api-design.md#connecting-by-host-address) defines. A phone without Syncstr ignores the link, so the Mac's sheet says to install Syncstr first.

The phone does not look for hosts on the tailnet, for the reasons in [Host API design](host-api-design.md#connecting-by-host-address). The host tells the phone about the library's mirrors, and the phone suggests nothing else.

### When connecting fails

[Host API design](host-api-design.md#when-the-device-cannot-reach-the-host-address) maps each `URLError` to its cause and says when an address is a tailnet address. Only then may a message name Tailscale. This table gives the words. The mapping is a hypothesis that the [device spike](validation/tailscale-device-spike.md) (ASO-159) confirms or corrects. The same messages explain the "host unreachable" state after the first connection.

| Signal and likely cause | Japanese draft | Gloss | Action |
| --- | --- | --- | --- |
| Tailscale address, and the name does not resolve. Tailscale is off on the phone, or another VPN is on. | 「studio」に接続できません。このiPhoneでTailscaleがオンになっているか確認してください。iPhoneで同時に使えるVPNは1つです。 | Can't connect to studio. Check that Tailscale is on on this iPhone. An iPhone runs one VPN at a time. | 再試行 |
| Tailscale address, and the connection times out or is refused. The host is off or asleep, or the tailnet policy does not allow this iPhone. | 「studio」から応答がありません。「studio」が起動していてスリープしていないか、Tailscaleのアクセス設定でこのiPhoneが許可されているか確認してください。 | studio is not answering. Check that it is on and not asleep, and that your Tailscale access settings allow this iPhone. | 再試行 |
| Serve answers with a gateway error. Syncstr is not running on the host. | 「studio」でSyncstrが動いていません。「studio」でSyncstrを開いてください。 | Syncstr is not running on studio. Open it there. | 再試行 |
| The phone has no network at all. | このiPhoneはネットワークにつながっていません。 | This iPhone is not connected to a network. | 再試行 |
| The phone does not trust the certificate, because the address is not the host's full tailnet name. | 「studio」に安全に接続できません。「studio.example.ts.net」のような完全な名前で入力してください。 | Can't connect to studio securely. Enter the full name, such as studio.example.ts.net. | 閉じる |
| The address answers, but not as a Syncstr host. | このアドレスにはSyncstrのライブラリがありません。 | There is no Syncstr library at this address. | 閉じる |
| The link is newer than this app. | このiPhoneのSyncstrを更新してください。 | Update Syncstr on this iPhone. | 閉じる |
| The host is older than this app. | 「studio」のSyncstrを更新してください。 | Update Syncstr on studio. | 閉じる |

## Connection states

### On a device

A device is in exactly one of three states. "Through a mirror" qualifies the connected state when the primary does not answer and a mirror does. Following [Mirrors and the primary switch](mirrors-and-primary-switch.md), the device then shows the age of the mirror's copy.

| State | When | In the library | In Settings, section ライブラリ | The listener can |
| --- | --- | --- | --- | --- |
| Connected | The last request to a host of this library succeeded. | Nothing. | The host's name and 接続中 ("Connected"). | Play anything, save, and remove saves. |
| Connected through a mirror | The primary does not answer, and a mirror is the newest host that does. | One line on the library landing that names both hosts and the date of the mirror's copy. | The same, with the date. | Do everything a connected device can. |
| Host unreachable | Requests to every host the device knows fail. | One line at the top of the library landing, with **詳細** ("Details"). Tracks that are neither saved nor cached use the secondary text color. | The cause from the connection failure table and the last connection. | Browse the catalog, play saved and cached music, request saves that wait, and retry. |
| Not connected | The device knows no host address, or the listener disconnected it. | The first-launch screen, or the last catalog with a reason line. | **ライブラリに接続** ("Connect to a library") and the reason. | Connect. Saved music still plays. |

| Element | Japanese draft | Gloss |
| --- | --- | --- |
| Through a mirror | 「studio」に接続できないため、「nas」から再生しています。「nas」の内容は11月15日時点です。 | studio is unreachable, so music plays from nas. The library on nas is as of November 15. |
| Two hosts accept changes | 「studio」と「nas」の両方が変更を受け付ける設定になっています。どちらかで設定を直してください。再生と保存はそのまま使えます。 | Both studio and nas are set to accept changes. Fix the setting on one of them. Playback and saves keep working. |
| Unreachable | 「studio」に接続できません。保存した音楽は聴けます。 | Can't connect to studio. Saved music still plays. |
| Last connection | 最後の接続: 2時間前 | Last connected 2 hours ago. |
| Not connected, upgraded from the old design | 接続の方法が新しくなりました。ライブラリのあるMacやNASのQRコードを読み取るか、アドレスを入力してください。保存した音楽はそのまま聴けます。 | The way Syncstr connects has changed. Scan the QR code of the Mac or NAS that has the library, or enter its address. Saved music still plays. |

Through a mirror, the device keeps its own catalog when that is newer than the mirror's, as the mirrors design requires. A track whose file no reachable host has uses the secondary text color, as in the unreachable state, and tapping it gives the reason.

A device that was never connected shows no reason line. When the owner withdraws a device's access in Tailscale, the device sees the "host unreachable" state, because a refused connection looks like an unreachable host. It keeps its offline saves and its playback cache, because withdrawing access stops requests to the host and cannot reach files already on the device.

The line for two hosts that accept changes appears on the library landing and in Settings. It is the case where two hosts report the same switch number, which the mirrors design leaves to this document for wording. A device in the first release makes no change, so the line asks for a fix on the hosts and nothing on the device stops.

The state changes by these rules:

- The device enters "host unreachable" only after a probe or a request fails. A network change alone does not change the state.
- The device probes when the app becomes active, when the network path changes, when the listener taps **再試行**, and at intervals while a save waits for the host. A probe gives up after the 15 seconds that [Host API design](host-api-design.md) sets for an interactive request, unless the spike shows a better value.
- The first success returns the device to "connected" and removes the line, with no action from the listener.
- A local-only device shows no state.

### On the Mac as a host

| State | When | In Settings, tab 端末 | In the library window |
| --- | --- | --- | --- |
| Not accepting | Accepting connections was never turned on. | このMacでだけ再生しています。 ("Playing on this Mac only.") and **iPhoneを追加…**. | The offer line, until dismissed. |
| Reachable | The host runs and its address answers the host's own check. | ほかの端末からの接続を受け付けています。 ("Accepting connections from other devices.") and the address as selectable text. The check cannot tell whether a given device is allowed. | Nothing. |
| Not reachable | The host runs and the check fails. | The cause, with **Tailscaleを開く** or **もう一度設定…** ("Set up again"). | このMacからライブラリのアドレスを確認できません。 ("This Mac can't check the library's address.") in the notice area at the bottom of the window, with the cause and **再試行**. |
| Stopped | The listener turned off accepting connections. | 接続の受け付けを停止しています。ほかの端末では、保存した音楽だけを聴けます。 ("Not accepting connections. Other devices play only their saved music.") and **再開** ("Resume"). | Nothing. |

The causes of "not reachable" are Tailscaleがオフです。 ("Tailscale is off."), Tailscaleからログアウトしています。 ("Tailscale is logged out."), tailnetでHTTPSがオフです。 ("HTTPS is off for the tailnet."), and Tailscaleの設定がなくなりました。 ("The Tailscale setting is gone."). The notice area is `catalogNotice` in [Syncstr.swift](../apps/macos/Syncstr.swift) (line 76).

### When Tailscale is named

The Mac names Tailscale in the add-device flow, the publish confirmation, and the causes of "not reachable". A device names it only in the connection failure rows for a tailnet address, and in the recommendation for a listener without Tailscale. Nothing names it in the connected state, in the library, or in saves.

## Downloads

A download fills either the playback cache or an offline save, and [ADR 0005](adr/0005-distinguish-playback-cache-from-offline-saves.md) keeps the two apart. This section covers offline saves. Playback keeps the rules of [player-interaction-spec.md](player-interaction-spec.md).

### Save an album, a playlist, or the whole library

Tracks, albums, and playlists keep their save controls ([OfflineSaves.swift](../apps/macos/OfflineSaves.swift), album details at PhoneRoot.swift line 379, and playlists at [PlaylistViews.swift](../apps/macos/PlaylistViews.swift) line 187). An album or playlist save covers the tracks it has when the listener asks, as cluster-ui-review rules.

The whole library is new, as the switch **ライブラリ全体をこの端末に保存** ("Keep the whole library on this device") in the settings section 保存.

1. The listener turns the switch on, or chooses **ライブラリ全体を保存…** in the first-launch offer.
2. A sheet shows ライブラリ全体（48 GB）を保存します。この端末の空き容量は120 GBです。 ("Saves the whole library, 48 GB. This device has 120 GB free."), with **保存** and **キャンセル**.
3. If the library does not fit, the sheet shows 空き容量が足りません。あと12 GB必要です。 ("Not enough space. 12 GB more is needed.") and offers only **キャンセル**.
4. While the switch is on, tracks added to the library later are saved too.
5. Turning the switch off stops new saves and cancels waiting ones. Music already saved stays, and the footer says so.

The whole library is a standing switch, unlike an album save. A listener who keeps everything expects new albums to follow, and a one-time request would turn every later addition into a partial save.

A Mac whose library is local, as a host or for local playback only, shows no save controls and no saved-music list, because every track is already on it. Today the album details show save controls for every library (Syncstr.swift line 418).

### Show progress per album and overall

- The save button of an album or playlist shows a progress ring by bytes in place of today's spinner. The caption 12/18曲を保存済み stays (PhoneRoot.swift lines 383-389).
- A new library category **保存した音楽** ("Saved music") lists saved albums and playlists. Its first line shows overall progress, such as 保存中・残り42曲（1.3 GB） ("Saving, 42 tracks left, 1.3 GB"), or the waiting reason. Each row shows its own progress or its size. The list holds offline saves only and never the playback cache. On a Mac that is a device, the category is in the sidebar.
- No banner and no notification announce a download.

### Say why a save waits

| Reason | Japanese draft | Gloss | Resumes |
| --- | --- | --- | --- |
| No host is reachable. | 接続待ち | Waiting for the connection. | On the first successful request. |
| On cellular, with saves over cellular off. | Wi-Fi接続待ち | Waiting for Wi-Fi. | On Wi-Fi, or at once after **今回はモバイル通信で保存** ("Save over cellular this time"). |
| Storage is full. | 空き容量が足りません。あと1.2 GB必要です。 | Not enough space. 1.2 GB more is needed. | When the app becomes active or a save is removed and the space is enough, or on **再試行**. |

Before a save waits for storage, the device evicts the playback cache that ADR 0005 lets it evict. It never evicts an offline save. Today a full disk ends the save as a failure (OfflineSaves.swift lines 240-241). It becomes a waiting reason because the listener's fix, removing something, should let the save continue without a new request.

A save fails only when a retry cannot help, such as a file that fails its hash check twice or a track that has left the library. A failure keeps the partial-result rules of cluster-ui-review, where completed tracks stay and a retry fetches only the rest.

### Keep cellular opt-in

- Playing a track, an album, or a queue uses cellular, as today.
- An offline save uses cellular only when **モバイル通信で保存** ("Save over cellular") is on. It is off by default. Its footer reads オフの場合も、再生はモバイル通信でできます。保存はWi-Fiを待ちます。 ("When off, playback still uses cellular. Saves wait for Wi-Fi.").
- A waiting album or playlist save offers **今回はモバイル通信で保存** in its menu, for that save only. The whole-library switch uses cellular only when the setting is on.
- The Mac saves on any network and has no cellular setting.

This rule replaces today's behavior, where an explicit save starts over cellular and only an automatic resume waits for Wi-Fi (OfflineSaves.swift lines 205-206, and the toggle copy in [PeerSetup.swift](../apps/macos/PeerSetup.swift) lines 287-289). With saves that continue in the background, one tap on a large album could use gigabytes of cellular data while the listener is not looking.

### Continue in the background

The listener can leave the app or lock the phone, and saves continue. A save that a network change or iOS interrupts resumes the partial file instead of starting over. Today the app cancels transfers when it goes to the background ([SyncstrApp.swift](../apps/ios/Sources/SyncstrApp.swift) lines 44-47, and PhoneRoot.swift lines 90-92).

ASO-166 asks to record the fallback before building. If the spike shows that background downloads stop over the Tailscale tunnel, saves run while Syncstr is open, finish the current file in the time iOS allows, and continue on return without starting that file again. The waiting reasons then gain one row, Syncstrを開くと再開します ("Resumes when you open Syncstr"). The rest of this section stays as written.

### Show storage and remove saves

The settings section 保存 on a device shows 保存した音楽 with its size, 再生キャッシュ with its size and today's limit stepper with its default of 10 GB ([PlaybackCache.swift](../apps/macos/PlaybackCache.swift) lines 183-201), and この端末の空き容量, the free space. It ends with **すべての保存を解除…** ("Remove all saves"), which confirms with 保存した音楽（12 GB）をこの端末から削除します。「studio」のライブラリは変わりません。再生中の曲は止まります。 ("Deletes the saved music, 12 GB, from this device. The library on studio does not change. The playing track stops.").

The listener removes one album or playlist from its save menu, as today, or from the Saved music list. Removing a save deletes the managed copy and does not turn it into cache, as cluster-ui-review rules.

## The Mac as a host

The settings tab 端末 holds everything about serving:

- The state line and its action, from the [host states](#on-the-mac-as-a-host).
- The host address as selectable text.
- The switch **ほかの端末からの接続を受け付ける** ("Accept connections from other devices"). Turning it off asks 接続の受け付けを停止しますか？ ("Stop accepting connections?") and repeats the "stopped" line.
- The library's mirrors, as [Mirrors and the primary switch](mirrors-and-primary-switch.md) describes.
- **端末を追加…**, which opens the connect sheet of [Add a device from the Mac](#add-a-device-from-the-mac).
- **Tailscaleのアクセス設定を開く**, with the line どの端末が接続できるかは、Tailscaleのアクセス設定で決まります。 ("Which devices can connect is set in your Tailscale access settings.").
- **ログイン時に開く** ("Open at login"), if ASO-162 keeps the host inside the app.
- The footer このMacがスリープしている間や、ログアウトしている間は、ほかの端末から接続できません。 ("While this Mac sleeps or nobody is logged in, other devices can't connect."). [Tailscale setup](tailscale-setup.md) explains why logging out matters.

The host lists no devices, because every request arrives from Serve on loopback and carries no identity that the host checks.

While a device downloads, the host keeps the Mac from idle sleep. A long album save then does not stop halfway, and the listener's energy settings apply at all other times. A Mac that is a mirror shows its state as [Mirrors and the primary switch](mirrors-and-primary-switch.md) describes.

## Settings after the change

### Removed

Each item goes when ASO-169 removes the code behind it, after the owner's library runs on the new path.

- In [SettingsView.swift](../apps/macos/SettingsView.swift), the `PeerSetupView` block (line 24), the 従来の接続 disclosure with its sheet and `MacPairingView` (lines 26-47), and the caption under the folder button (line 15).
- [PeerSetup.swift](../apps/macos/PeerSetup.swift), the whole file. `PeerSetupView` holds 既存のライブラリに参加, the invitation and JSON field, 接続先のQRコードを読み取る, 従来のP2P接続と端末ID, 保存先と接続診断 with the relay, the connection path and host IDs, この端末のID, 接続設定を更新, and the P2P buttons. The file also holds `ClusterImportResults` (音源の追加結果) and `ClusterConflictsView` (変更の競合と端末の権限). The cellular toggle at lines 287-289 moves to the section 保存 with the new rule.
- In [LocalSetup.swift](../apps/macos/LocalSetup.swift), `MacPairingView` (lines 69-117) and `PhonePairingView` (lines 119-209). `PairingScanner` (lines 211-234) stays for the new QR scan, and `AddMusicButton` and `LocalFolderButton` stay.
- In Syncstr.swift, 既存のライブラリに参加 with its sheet (lines 68 and 112-116), and the `ClusterImportResults` sheet (lines 117-123).
- In PhoneRoot.swift, the sections ライブラリと接続 (line 545) and 従来の接続 (lines 547-554), and the link 既存のライブラリに参加 (lines 241-244).
- In the iOS [Info.plist](../apps/ios/Info.plist) and the `apps/ios/project.yml` that generates it, `NSBonjourServices`, and `NSLocalNetworkUsageDescription` if the [device spike](validation/tailscale-device-spike.md) shows that a host reached over Tailscale needs no local network permission. `NSCameraUsageDescription` becomes ライブラリのあるMacやNASのQRコードを読み取るために使用します。 ("Used to scan the QR code of the Mac or NAS that has the library.").

### Kept

Appearance, the playback-cache limit and usage, and playback diagnostics stay on both platforms. The Mac keeps music-folder selection and adding music files for a local library or a host. The iPhone keeps 曲数 ("Track count") and 保存した音楽を開く for a local library.

### New

- On the Mac, Settings becomes three tabs, 一般 ("General"), ライブラリ ("Library"), and 端末 ("Devices"). Today one 520-by-680-point scroll view mixes unrelated controls, and a native macOS Settings window uses tabs.
- On a device, the section ライブラリ shows the library and host names, the connection state, the last connection, and **接続を解除…** ("Disconnect").
- On a device, the section 保存 holds **モバイル通信で保存**, the whole-library switch, storage, and **すべての保存を解除…**.
- On a host, the tab 端末. A Mac that is a device has no 端末 tab, and its tab ライブラリ holds the device sections above.

### Edits that leave a connected device

In the first release a device reads and downloads, and the listener edits the library on the primary. These controls are hidden on a device connected to a host and stay on a host and on a local-only device:

- 音楽ファイルを追加 in the iPhone toolbar (PhoneRoot.swift lines 138 and 262-264) and in the Mac sidebar (Syncstr.swift lines 198-207).
- Hiding and showing albums (PhoneRoot.swift lines 326-332, Syncstr.swift line 331). The category 非表示にしたアルバム stays, read-only.
- 曲の情報を編集… and 変更を送信 in [TrackMetadataEditor.swift](../apps/macos/TrackMetadataEditor.swift).
- XMLから移行 for playlists (PlaylistViews.swift line 53).

They are hidden rather than disabled, because a disabled control on every album asks for an action the listener cannot take on that device. ASO-168 decides which edits return.

## Recommend Tailscale

The Mac shows this text in the add-device flow when Tailscale is not installed. The iPhone shows it behind **Tailscaleを使っていない場合**.

| Element | Japanese draft | Gloss |
| --- | --- | --- |
| Lead | iPhoneで聴くには、このMacとiPhoneにTailscaleを入れます。 | To listen on your iPhone, install Tailscale on this Mac and the iPhone. |
| Step 1 | このMacとiPhoneにTailscaleを入れ、同じアカウントでログインします。 | Install Tailscale on this Mac and the iPhone, and log in with the same account. Someone else's iPhone uses their own account and a share of this Mac, as [Tailscale setup](tailscale-setup.md#share-the-host-with-another-person) describes. |
| Step 2 | Syncstrに戻り、「iPhoneを追加」を選びます。 | Come back to Syncstr and choose Add iPhone. On the iPhone, the step says to choose Add iPhone on the Mac and scan the code. |
| Without it | Tailscaleがなくても、このMacで音楽を聴けます。 | Without Tailscale, this Mac still plays your music. |
| Buttons | Tailscaleを入手, 閉じる | Get Tailscale, Close. |

The first release connects devices only over Tailscale, because it gives the host one name at home and on cellular, a certificate that iOS accepts without an exception, and the access policy that decides who reads the library. **Tailscaleを入手** opens Tailscale's download page in the browser.

## Rules carried over

These rules of [cluster-ui-review.md](cluster-ui-review.md) still apply:

- Audio retention, the eviction order, protection of saved audio from before the upgrade, the exception for a track larger than the cache limit, and protection of a cached track when it is saved.
- The playback transitions. "An available authorized source" now means the primary or a mirror that the device knows.
- The offline-save transitions for restart, partial failure, cancel, and removal.
- A daily library that needs no choice of host and keeps its catalog without a connection.
- The cache limit, default 10 GB, counted apart from offline saves.

These rules are replaced:

- Settings that organize enrollment, hosts, connection diagnostics, membership, conflicts, and legacy transfer.
- "Without forced re-enrollment" and the Upgrade scenario. Each existing device connects once more by the host address, and its saved audio stays.
- Explicit saves over cellular, and a full disk as a failure.

Every rule of [player-interaction-spec.md](player-interaction-spec.md) applies unchanged. Two matter most here. A host that is offline is not evidence that a track was deleted, and a queue that cannot fetch its next track in the background stops and explains why.

Three lines of DESIGN.md change under ASO-167. "Put legacy device transfer in Settings" goes. "Pairing approval" goes, because the tailnet policy decides which devices connect. Music import in the sidebar applies only to a host and a local library.

## Which issue builds each flow

| Flow | Issue | Needs first |
| --- | --- | --- |
| Mac first launch, all three cases | ASO-167 | ASO-162 |
| Accepting connections, sleep, and login | ASO-162 | ASO-160 |
| Tailscale checks, the publish confirmation, and the copied command | ASO-163 | ASO-159, ASO-160 |
| The connect sheet, connecting by host address on the device, and connection failures | ASO-164 | ASO-160 |
| iPhone first launch and the offer to save | ASO-167 | ASO-164, ASO-165 |
| Device connection states and when Tailscale is named | ASO-167 | ASO-159, ASO-165 |
| The mirror line and the line for two hosts that accept changes | ASO-172 | ASO-167 for wording |
| Saves, progress, waiting, cellular, storage, the whole library, and the background | ASO-166 | ASO-159, ASO-165 |
| Hiding edits on a connected device | ASO-165 | ASO-168 to bring edits back |
| The "upgraded" reason and connecting once more | ASO-165 | ASO-161 |
| Removal of the old screens | ASO-169 | The owner's library on the new path |
| The recommendation without Tailscale | ASO-167 | ASO-163 for the guide |

## Prototype before building

ASO-167 requires a prototype before these flows are built. Each is a throwaway SwiftUI app with stubbed hosts, checked against DESIGN.md in both appearances, with long names, and at accessibility text sizes.

1. The Mac's add-device flow with Tailscale missing, off, HTTPS off, and ready. Can a listener who has never used Tailscale finish without help?
2. The iPhone first launch and every connection failure, against a stub host that fails on demand.
3. The unreachable line and the secondary color on tracks that cannot play. Does the library still read as usable when most tracks are not saved?
4. The Saved music category and its progress during a long whole-library save.
5. A sandboxed Mac app that tries to configure `tailscale serve` through the command and the LocalAPI, with both macOS variants of Tailscale. It answers open question 1.

## What the device spike must answer

The download design is not final before the [device spike](validation/tailscale-device-spike.md#questions) (ASO-159) answers Q2 (background downloads over the tunnel, where a "no" selects the foreground fallback), Q3 (resume after a network change), Q4 (the signal and time of each unreachable cause, which set the connection failure table and the probe timeout), and Q8 (whether `URLSession` keeps a download off cellular through the tunnel, where a "no" means the cellular rule cannot be enforced as written).

## Open questions

1. Can one confirmation configure Serve, so that the listener copies no command? This depends on whether the sandboxed app can run the `tailscale` command or reach the LocalAPI with the App Store and Standalone variants of Tailscale, and whether it can read Tailscale's state and this Mac's tailnet name, which the add-device checks and the address line need. Prototype 5 settles it. If it cannot, the copied command stays, or a build outside the sandbox with a helper replaces it. ASO-163.
2. [Host API design](host-api-design.md) has the macOS app run owner actions in process. Does the host keep serving with the window closed, and does it start at login? This decides **ログイン時に開く** and whether the listener can keep the Mac awake at all times. ASO-162.
3. Does accepting connections for a folder-based library copy the audio into the host's storage? If it does, the add-device flow must show the space it needs first. ASO-162.
4. How much free space does a device keep before a whole-library save, or before it resumes a save that waits for storage? ASO-166.
5. Where does longer help text live, given that Syncstr runs no service? ASO-167.
6. How does a NAS host show its connect QR code, given that it has no screen? A command that prints the address and the code as text is the default. ASO-164.
7. What happens to the Serve setting when the listener stops accepting connections or quits the app? `tailscale serve --bg` survives restarts. If Syncstr frees its loopback port while the setting stays, another program that takes the port would be published at the host address. Syncstr either removes its own Serve handler on stop, or keeps the port and answers that it is not serving. ASO-162, ASO-163.
