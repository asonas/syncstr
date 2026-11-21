---
status: accepted
---

# Serve a library from one primary host over a private network

Syncstr stops building its own connectivity. For the first release, the Mac or NAS hosting the library and each remote playback device join Tailscale. A host serves the library over HTTPS at a host address, and a device reaches that address like any other web service. Discovery by mDNS, peer-to-peer transport, relays, the rendezvous directory, and everything that existed to connect hosts across networks are removed during the rebuild.

A library has exactly one primary host. Only the primary accepts changes. A library can also have mirrors. A mirror pulls everything from the primary through the same API that a phone uses, keeps a full copy, and can serve that copy to devices. A mirror never accepts a change. The owner explicitly chooses when a mirror becomes the primary. In a planned switch the owner acts on both machines. The switch number rises with each switch. Two hosts that accept changes at the same time are out of scope.

On 2026-11-17 the owner chose one writer and an externally managed private network. On 2026-11-18 the owner chose Tailscale for first-release remote access. These decisions replace the parts of [ADR 0002](0002-local-first-connectivity-with-user-operated-remote-access.md) about discovery, relays, a peer directory, LAN enrollment and several writers. Syncstr provides no central service or Syncstr account. The owner withdraws a device's access through Tailscale.

## Why

Recent work did not change what a listener can do. At the commit before this decision, about 62% of `headless/src` was networking, cluster, and activation code. The activation journal alone, with its inventory tooling, was about 8,660 lines, and no app speaks its protocol. The owner's real library never ran on the cluster or on v5. It runs on the oldest host mode at schema generation 4. Meanwhile the shipped apps can find a host only on the same LAN and reject tailnet addresses.

The cost came from one requirement: several hosts that all accept changes must agree. That requirement needs signed changes, membership grants, ordering, and a protocol to move every host to a new format together. One writer removes the requirement. A second machine is still useful as a backup and as a second place to download from, and a mirror gives both without agreement between writers.

The price is real. A listener cannot edit the library on two hosts and merge the results later. If the primary is lost, the changes it accepted after the mirror was last caught up are lost, unless the old primary comes back, and then they are kept aside for the owner rather than merged. Remote library access depends on Tailscale. Music already saved on a device remains playable offline.

The access decision carries these risks:

- A listener who does not use Tailscale cannot reach the library from another device.
- iOS runs one VPN at a time, so a phone that needs another VPN cannot reach the host at that moment.
- Every device that the effective tailnet policy lets reach the host reads the whole library. A rule broader than intended exposes it, and Syncstr adds no check of its own.
- Serve's certificate puts the host's machine name in public certificate transparency logs.

## What follows

The host publishes its read-only library API through Tailscale Serve. The owner controls which devices can reach that host and port in the tailnet policy. An allowed iPhone opens the host’s HTTPS address and reads the library directly, without a Syncstr token or pairing code. Removing network access stops future remote reads. Local playback and existing offline saves remain available.

When the primary is unreachable, a device can browse, download and play from the most up-to-date reachable mirror. It keeps any newer catalog it has already seen and shows when the mirror was last caught up, along with the number of missing changes when known.

If the primary is lost, the owner can promote a mirror using its last complete copy. Later changes may be missing from that copy. An isolated old primary may continue accepting changes until it learns of the switch. It then stops writing and preserves any divergent copy for the owner. If two hosts claim to be primary at the same switch number, writes stop when the conflict is detected and the owner chooses the primary. See [mirrors and the primary switch](../mirrors-and-primary-switch.md).

The library service listens on loopback. In the NAS userspace sidecar's network namespace, both node listeners bind to `127.0.0.2`. Tailscale forwards tailnet TCP ports outside Serve to the same port on `127.0.0.1`. Serve publishes only the read API over HTTPS. Owner operations stay local.

Either a Mac or a NAS can be the primary. The macOS app runs the host on a Mac, and the same host runs headless elsewhere.

In the first release, the iPhone can browse, download, save music for offline listening, and play it. The listener adds music and edits metadata and playlists on the primary. ASO-168 covers later edits from devices.

Whole-file download with hash verification stays the playback model, and [ADR 0005](0005-distinguish-playback-cache-from-offline-saves.md) keeps its distinction between the playback cache and offline saves. Track identity in [ADR 0006](0006-preserve-source-track-identity-independently-of-audio.md) and [ADR 0007](0007-preserve-track-addresses-when-sharing-audio.md) stays a product boundary. How the single-writer store keeps it is decided in the migration plan.

## What this replaces in the v5 and cluster designs

| Part | Status | Documents |
| --- | --- | --- |
| Several writers: signed changes, membership grants, enrollment, epochs, profile floors, the activation journal, and retrying a change at another host | Replaced | [v5 completion design](../v5-completion-design.md), [v5 member mutation contract](../v5-member-mutation-contract.md), [v5 activation and recovery](../v5-activation-and-recovery.md), [v5 activation control protocol](../v5-activation-control-protocol.md), [cluster model](../cluster-model-design.md), [cluster implementation plan](../cluster-implementation-plan.md) and its milestone documents |
| Connectivity built by Syncstr: mDNS discovery, peer-to-peer transfer, relays, and the rendezvous directory | Replaced | [peer rendezvous](../peer-rendezvous.md), [peer-to-peer transfer](../p2p-music-transfer.md), [local transfer milestone](../design-spec.md#trust-and-execution), [cluster connectivity M0](../cluster-connectivity-m0.md) |
| Track identity, playlist references, and the playback cache and offline saves | Kept | ADR 0005, ADR 0006, ADR 0007, and the playback rules of the [cluster UI review](../cluster-ui-review.md) |
| The code behind the replaced parts | May break or be removed during the rebuild | [Migration plan](../private-network-migration-plan.md) |

Each replaced document carries a note that points here and stays as the record of the code that still implements it.

The design is described in [the architecture overview](../private-network-architecture.md). This ADR records a decision and authorizes no production operation.

## Status of the parts

- Accepted on 2026-11-17: one primary, mirrors, the explicit switch, no simultaneous writers, and no connectivity built by Syncstr.
- On 2026-11-18 the owner accepted the Mac and NAS host roles, the iPhone scope, mirror playback and manual promotion. The first release uses Tailscale and tailnet policy for read access.
- ASO-160 merged in #83 (`b652fa4`). On 2026-11-19 the NAS began serving the read-only `/api/v1`, including playlists, from the existing store. The node shares the sidecar's network namespace. Serve proxies every path to `http://127.0.0.2:8441`. The legacy listener is loopback-only. See [Tailscale setup](../tailscale-setup.md) for the assumptions to recheck on updates.
- The owner is the only user. The old paths may break or be removed as the Apple apps switch to API reads and connection by address. Keep the data directory and originals safe so the previous image can reopen them. ASO-170 still tracks the separate decision on the Windows, Android and gpui apps.

[ASO-159's TestFlight checklist](../validation/tailscale-testflight-qa.md) follows each app change onto the owner's physical iPhone. A push to `main` triggers Xcode Cloud and internal TestFlight distribution. Mac reads have been verified. The phone measurements and NAS reboot check are pending.
