# Syncstr on a private network

This overview describes the planned implementation of [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md), accepted on 2026-11-18. Production operations require separate approval.

This overview explains the planned shape of Syncstr and where each part is designed. Read it first. The documents it links to hold the rules.

## What changes for a listener

Today a listener who wants music on their phone joins a cluster. Someone creates an invitation on a stopped host from a terminal, the phone must be on the same LAN, and the apps contain screens for hosts, conflicts, relays, and legacy connections.

In the first release, both the Mac or NAS host and the phone connect to Tailscale. The owner allows the phone to reach the host’s HTTPS service in the tailnet policy. The listener opens the host address in Syncstr and saves albums for offline use. ASO-159 measures what happens when the phone locks.

## The parts

```text
        Tailscale on the host and playback devices
  ┌───────────────────────────────────────────────────────────┐
  │                                                           │
  │   primary host ──── pull ───▶ mirror host (optional)      │
  │   accepts changes             copies and serves           │
  │        ▲                           ▲                      │
  │        │  HTTPS over Tailscale     │                      │
  │        └────────────┬──────────────┘                      │
  │                     │                                     │
  │                  devices                                  │
  │       iPhone app, macOS app when it is not a host         │
  └───────────────────────────────────────────────────────────┘
```

- A **library** is the music, its catalog, artwork, and playlists.
- A **host** holds a full copy of a library and serves it over HTTPS at a host address. The macOS app can run a host. The same host runs headless on a NAS.
- The **primary** is the one host that accepts changes. A **mirror** copies the primary and serves the copy.
- A **device** plays music from a host. It downloads whole files, checks each file against its hash, and plays the local file.
- Access to the first-release read API follows the host and port rules in the tailnet policy. A host address carries no credential.

The terms are defined in the [glossary](../GLOSSARY.md#hosts-and-devices).

## Where each part is designed

| Part | Document | Issues |
| --- | --- | --- |
| The decision and what it replaces | [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md) | ASO-158 |
| The read-only HTTPS API and connecting by address | [Host API design](host-api-design.md) | ASO-160, ASO-164 |
| Mirrors and switching the primary | [Mirrors and the primary switch](mirrors-and-primary-switch.md) | ASO-172, ASO-173 |
| First launch, connection states, downloads, and settings | [Onboarding and connection states](onboarding-and-connection-states.md) | ASO-162, ASO-163, ASO-166, ASO-167 |
| The store, the migration of an existing library, the Apple transport change, changes from devices, removal of the old stacks, the Windows, Android and gpui apps, and existing issues | [Migration plan](private-network-migration-plan.md) | ASO-161, ASO-165, ASO-168, ASO-169, ASO-170, ASO-171 |
| Putting a host on a tailnet | [Tailscale setup](tailscale-setup.md) | ASO-163 |
| What must be measured on a real iPhone first | [Device spike](validation/tailscale-device-spike.md) | ASO-159 |

## What Syncstr no longer does

Syncstr does not find hosts, cross networks, or relay traffic. The following exist today and are removed after the owner's library runs on the new path:

- Discovery by mDNS and the address filters that go with it.
- The peer-to-peer transports built on iroh, in the host and in the Apple apps.
- The relay, the rendezvous directory, and their deployment packages.
- Cluster membership: invitations, grants, and signed changes that several hosts merge.
- The v5 activation journal and its inventory tooling.
- The transfer between a Mac and an iPhone over Bonjour.

Code may go before the cutover if the owner's library has never used it and no active client depends on it. ASO-170 tracks the owner's separate decision about the Windows, Android and gpui apps. The [migration plan](private-network-migration-plan.md) gives the order.

## What stays

- Whole-file download, verification against the content hash, and local playback.
- The playback cache and offline saves, with the distinction that [ADR 0005](adr/0005-distinguish-playback-cache-from-offline-saves.md) draws.
- The catalog, album organization, artwork, playlists, and import. Their identity rules follow [ADR 0006](adr/0006-preserve-source-track-identity-independently-of-audio.md) and [ADR 0007](adr/0007-preserve-track-addresses-when-sharing-audio.md).
- Local playback with no host at all.
- No account, and no service run by the operator of Syncstr.

## What Syncstr asks of the private network

The Mac or NAS host joins Tailscale and publishes its loopback read service with Serve. The phone joins Tailscale and opens that HTTPS address. The owner grants or withdraws access to the service in Tailscale. The host provides library reads through this listener and keeps administration local. See the [setup guide](tailscale-setup.md).

## Order of work

1. Record the decision and run the device spike. The spike can change the download design, so it comes before any build.
2. Remove the code that the owner never ran, within the exception above.
3. Build the store, the migration, the read API, and connection by host address.
4. Move the Apple apps to the API, then build background downloads and the new first launch.
5. Move the owner's library to the new path, and then remove the code the owner uses daily.
6. Add mirrors and the primary switch, then changes from devices, then the Windows, Android and gpui apps if the owner wants them.

Each step leaves a product that works. The old path stays usable until step 5 is proven. The [migration plan](private-network-migration-plan.md#phases) gives the phases in detail.

## Risks the owner accepted or must still weigh

- Remote reads require Tailscale on both ends. Saved music remains available offline.
- iOS allows one VPN at a time, so a listener who needs another VPN on the phone cannot use Tailscale at the same moment.
- Publishing a host with `tailscale serve` puts the machine's full name in public certificate transparency logs.
- With one writer, if the primary is lost, the changes it accepted after a mirror was last caught up are lost, unless the old primary comes back and keeps them aside for the owner.
- Whether background downloads continue over the Tailscale tunnel is not documented. The [device spike](validation/tailscale-device-spike.md) measures it.
