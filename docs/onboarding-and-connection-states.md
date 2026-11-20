# Onboarding and connection states

Both Apple apps open one headless host's library over HTTPS, as described in [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md). The first-launch and Settings sections below describe the current implementation. The connection-state wording, mirror behavior, and expanded download controls are design targets. TestFlight verification is pending.

The host and each listening device join Tailscale. A device opens the host address allowed by the tailnet policy. A QR code or link carries the address. The owner manages access in Tailscale. See the [host read API](host-api-design.md), [mirror design](mirrors-and-primary-switch.md), and [Tailscale setup](tailscale-setup.md).

On iPad the iOS app follows the same connection flow as on iPhone. The interface uses Japanese labels. The examples below use fictional host addresses.

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
| Download | No word of its own. A save shows 保存中, and playback keeps its preparation label. | One act, one word. |

The words of the old design leave the interface: 参加, 招待, ペアリング, 保存先 in the sense of a host, 接続先, 端末ID, 中継, 競合, and 従来の接続. A device never shows "primary" or "mirror".

## First launch on the Mac

The [library window](../apps/macos/Syncstr.swift) offers **ホストに接続** ("Connect to host"), **音楽フォルダを選ぶ** ("Select Music Folder"), and **音楽ファイルを追加** ("Add music files"). If a saved local library is available, the listener can reopen it.

For a host library, enter its address (for example, `music.example.ts.net`) or open its Syncstr link. The [connection sheet](../apps/macos/HostConnectionView.swift) reads the library information and asks for confirmation. The Mac then reads the catalog, playlists, artwork, and audio from the host's `/api/v1`, just like the iPhone.

For local playback, choose a folder. The app indexes it and plays the original files on this Mac. Folder selection is disabled while a host is connected. Disconnect in Settings to choose a local folder again.

## Connect another device

Open the same host address on the other device and confirm the library there. The headless host serves both devices. Importing a folder into the Mac app makes its music available for local playback only.

## First launch on the iPhone

In the [empty library](../apps/ios/Sources/PhoneRoot.swift), choose **ホストに接続** to enter the address or scan a host QR code on a supported device. Opening a Syncstr link also starts confirmation. The sheet identifies the host and library before the listener connects. **音楽ファイルを追加** imports local files, and **保存した音楽を開く** opens a saved library when available.

### When connecting fails

[Host API design](host-api-design.md#when-the-device-cannot-reach-the-host-address) maps each `URLError` to its cause and says when an address is a tailnet address. Only then may a message name Tailscale. This table gives the words. The mapping is a hypothesis that the [TestFlight checklist](validation/tailscale-testflight-qa.md) (ASO-159) confirms or corrects. The same messages explain the "host unreachable" state after the first connection.

| Signal and likely cause | Japanese draft | Gloss | Action |
| --- | --- | --- | --- |
| Tailscale address, and the name does not resolve. Tailscale is off on the phone, or another VPN is on. | 「studio」に接続できません。このiPhoneでTailscaleがオンになっているか確認してください。iPhoneで同時に使えるVPNは1つです。 | Can't connect to studio. Check that Tailscale is on on this iPhone. An iPhone runs one VPN at a time. | 再試行 |
| Tailscale address, and the connection times out or is refused. The host is off or asleep, or the tailnet policy does not allow this iPhone. | 「studio」から応答がありません。「studio」が起動していてスリープしていないか、Tailscaleのアクセス設定でこのiPhoneが許可されているか確認してください。 | studio is not answering. Check that it is on and not asleep, and that your Tailscale access settings allow this iPhone. | 再試行 |
| Serve answers with a gateway error. Syncstr is not running on the host. | 「studio」でSyncstrが動いていません。「studio」でSyncstrを開いてください。 | Syncstr is not running on studio. Open it there. | 再試行 |
| The phone has no network at all. | このiPhoneはネットワークにつながっていません。 | This iPhone is not connected to a network. | 再試行 |
| The phone does not trust the certificate, because the address is not the host's full tailnet name. | 「studio」に安全に接続できません。「studio.example.ts.net」のような完全な名前で入力してください。 | Can't connect to studio securely. Enter the full name, such as studio.example.ts.net. | 閉じる |
| The address answers, but not as a Syncstr host. | このアドレスにはSyncstrのライブラリがありません。 | There is no Syncstr library at this address. | 閉じる |
| The host answers `404 not-found` for a route that this app needs, so the host is older than this app. | 「studio」のSyncstrを更新してください。 | Update Syncstr on studio. | 閉じる |

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

After a disconnect, the device keeps the last host catalog until the listener connects to a host again. The catalog still indexes saved tracks, even on a device with an older cluster registration. The device remembers the catalog's address and library ID so it can ask before replacing the library at that address.

A device that was never connected shows no reason line. When the owner withdraws a device's access in Tailscale, the device sees the "host unreachable" state, because a refused connection looks like an unreachable host. It keeps its offline saves and its playback cache, because withdrawing access stops requests to the host and cannot reach files already on the device.

From ASO-172 on, the line for two hosts that accept changes appears on the library landing and in Settings. The first release has one host, so it never shows. It is the case where two hosts report the same switch number with different primaries, which the mirrors design leaves to this document for wording. A device in the first release makes no change, so the line asks for a fix on the hosts and nothing on the device stops.

The state changes by these rules:

- The device enters "host unreachable" only after a probe or a request fails. A network change alone does not change the state.
- The device probes when the app becomes active, when the network path changes, when the listener taps **再試行**, and at intervals while a save waits for the host. A probe gives up after the 15 seconds that [Host API design](host-api-design.md) sets for an interactive request, unless iPhone measurements show a better value.
- The first success returns the device to "connected" and removes the line, with no action from the listener.
- A local-only device shows no state.

The Mac follows the same device connection states as the iPhone. When it has only the retained host catalog, local saves remain playable and library refresh is unavailable. A listener can reconnect in Settings.

## Downloads

A download fills either the playback cache or an offline save, and [ADR 0005](adr/0005-distinguish-playback-cache-from-offline-saves.md) keeps the two apart. This section covers offline saves. Playback keeps the rules of [player-interaction-spec.md](player-interaction-spec.md).

### Save an album, a playlist, or the whole library

Tracks, albums, and playlists keep their save controls ([OfflineSaves.swift](../apps/macos/OfflineSaves.swift) and [PlaylistViews.swift](../apps/macos/PlaylistViews.swift)). An album or playlist save covers the tracks it has when the listener asks, as cluster-ui-review rules.

The whole library is new, as the switch **ライブラリ全体をこの端末に保存** ("Keep the whole library on this device") in the settings section 保存.

1. The listener turns the switch on, or chooses **ライブラリ全体を保存…** in the first-launch offer.
2. A sheet shows ライブラリ全体（48 GB）を保存します。この端末の空き容量は120 GBです。 ("Saves the whole library, 48 GB. This device has 120 GB free."), with **保存** and **キャンセル**.
3. If the library does not fit, the sheet shows 空き容量が足りません。あと12 GB必要です。 ("Not enough space. 12 GB more is needed.") and offers only **キャンセル**.
4. While the switch is on, tracks added to the library later are saved too.
5. Turning the switch off stops new saves and cancels waiting ones. Music already saved stays, and the footer says so.

The whole library is a standing switch, unlike an album save. A listener who keeps everything expects new albums to follow, and a one-time request would turn every later addition into a partial save.

On the Mac, local-folder tracks play from their originals.

### Show progress per album and overall

- The save button of an album or playlist shows a progress ring by bytes in place of today's spinner. The caption 12/18曲を保存済み stays.
- A new library category **保存した音楽** ("Saved music") lists saved albums and playlists. Its first line shows overall progress, such as 保存中・残り42曲（1.3 GB） ("Saving, 42 tracks left, 1.3 GB"), or the waiting reason. Each row shows its own progress or its size. The list holds offline saves only and never the playback cache. On a Mac that is a device, the category is in the sidebar.
- No banner and no notification announce a download.

### Say why a save waits

| Reason | Japanese draft | Gloss | Resumes |
| --- | --- | --- | --- |
| No host is reachable. | 接続待ち | Waiting for the connection. | On the first successful request. |
| On cellular, with saves over cellular off. | Wi-Fi接続待ち | Waiting for Wi-Fi. | On Wi-Fi, or at once after **今回はモバイル通信で保存** ("Save over cellular this time"). |
| The host answers 429 because it is busy. | 接続待ち | Waiting for the connection. The host's `Retry-After` sets when the save retries. The frequency has not been measured. | When the host accepts the download. |
| Storage is full. | 空き容量が足りません。あと1.2 GB必要です。 | Not enough space. 1.2 GB more is needed. | When the app becomes active or a save is removed and the space is enough, or on **再試行**. |

Before a save waits for storage, the device evicts the playback cache that ADR 0005 lets it evict. It never evicts an offline save. Today a full disk ends the save as a failure. It becomes a waiting reason because the listener's fix, removing something, should let the save continue without a new request.

A save fails only when a retry cannot help, such as a file that fails its hash check twice or a track that has left the library. A failure keeps the partial-result rules of cluster-ui-review, where completed tracks stay and a retry fetches only the rest.

### Keep cellular opt-in

- Playing a track, an album, or a queue uses cellular, as today.
- An offline save uses cellular only when **モバイル通信で保存** ("Save over cellular") is on. It is off by default. Its footer reads オフの場合も、再生はモバイル通信でできます。保存はWi-Fiを待ちます。 ("When off, playback still uses cellular. Saves wait for Wi-Fi.").
- A waiting album or playlist save offers **今回はモバイル通信で保存** in its menu, for that save only. The whole-library switch uses cellular only when the setting is on.

Today the saving section of Settings on both platforms includes **モバイル通信でも自動転送する**. The current preference controls automatic saves. The per-save override above is proposed.

### Continue in the background

The listener can leave the app or lock the phone, and saves continue. A save that a network change or iOS interrupts resumes the partial file instead of starting over. Current automatic saves run while the app is active.

ASO-166 asks to record the fallback before building. If TestFlight QA shows that background downloads stop over the Tailscale tunnel, saves run while Syncstr is open, finish the current file in the time iOS allows, and continue on return without starting that file again. The waiting reasons then gain one row, Syncstrを開くと再開します ("Resumes when you open Syncstr"). The rest of this section stays as written.

### Show storage and remove saves

The settings section 保存 on a device shows 保存した音楽 with its size, 再生キャッシュ with its size and today's limit stepper with its default of 10 GB ([PlaybackCache.swift](../apps/macos/PlaybackCache.swift)), and この端末の空き容量, the free space. It ends with **すべての保存を解除…** ("Remove all saves"), which confirms with 保存した音楽（12 GB）をこの端末から削除します。「studio」のライブラリは変わりません。再生中の曲は止まります。 ("Deletes the saved music, 12 GB, from this device. The library on studio does not change. The playing track stops.").

The listener removes one album or playlist from its save menu, as today, or from the Saved music list. Removing a save deletes the managed copy and does not turn it into cache, as cluster-ui-review rules.

## Settings after the change

On both platforms, Settings shows the host and library names and offers refresh, change host, and disconnect actions. Disconnecting retains the last catalog and saved audio. Host catalogs are read-only, including a retained host catalog after disconnect. Local libraries support file import and album visibility changes.

The saving section includes the automatic cellular transfer toggle, playback-cache limit, cache usage, and saved audio size. Appearance and playback diagnostics are also available. On the Mac, the folder chooser becomes available after disconnect. See [Mac Settings](../apps/macos/SettingsView.swift), [iPhone Settings](../apps/ios/Sources/PhoneRoot.swift), and the [shared saving controls](../apps/macos/PlaybackCache.swift).

## Rules carried over

These rules of [cluster-ui-review.md](cluster-ui-review.md) still apply:

- Audio retention, the eviction order, protection of saved audio from before the upgrade, the exception for a track larger than the cache limit, and protection of a cached track when it is saved.
- The playback transitions. "An available authorized source" now means the primary or a mirror that the device knows.
- The offline-save transitions for restart, partial failure, cancel, and removal.
- A daily library that needs no choice of host and keeps its catalog without a connection.
- The cache limit, default 10 GB, counted apart from offline saves.

The design revises these earlier rules:

- Settings that organize enrollment, hosts, connection diagnostics, membership, conflicts, and legacy transfer.
- "Without forced re-enrollment" and the Upgrade scenario. Each existing device connects once more by the host address, and its saved audio stays.
- Explicit saves over cellular, and a full disk as a failure.

Every rule of [player-interaction-spec.md](player-interaction-spec.md) applies unchanged. Two matter most here. A host that is offline is not evidence that a track was deleted, and a queue that cannot fetch its next track in the background stops and explains why.

## Planned device work

| Flow | Issue | Needs first |
| --- | --- | --- |
| Connection by host address and connection failures | ASO-164 | ASO-160 |
| First launch, the offer to save, and device connection states | ASO-167 | ASO-164, ASO-165 |
| Mirror status and conflicting primary hosts | ASO-172 | ASO-167 for wording |
| Whole-library saves, storage waits, cellular and background downloads | ASO-166 | ASO-164, ASO-165 |
| Library edits on a connected device | ASO-168 | ASO-165 |

The proposed ASO-167 prototypes exercise first launch and connection failures against a stub host, the appearance of an unreachable library with few saved tracks, and progress during a whole-library save. Check both appearances, long names, and accessibility text sizes against [DESIGN.md](../DESIGN.md).

## What to check in TestFlight

Use the [TestFlight checklist](validation/tailscale-testflight-qa.md#questions) as the app changes land. Q2 checks whether saves need the foreground fallback. Q3 checks resume after a network change. Q4 measures connection failure signals and timeouts. Q8 checks whether Wi-Fi-only saves stay off cellular through the tunnel.

## Open questions

- How much free space should a device reserve for whole-library saves and for resuming a save after a storage wait? ASO-166.
- Where should longer help text live? ASO-167.
- How should a headless host display a connect QR code? ASO-164.
