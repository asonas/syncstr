# Syncstr on a private network

Status: proposed 2026-11-17 with [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md). Nothing in this document is implemented, and it authorizes no production operation.

This overview explains the planned shape of Syncstr and where each part is designed. Read it first. The documents it links to hold the rules.

## What changes for a listener

Today a listener who wants music on their phone joins a cluster. Someone creates an invitation on a stopped host from a terminal, the phone must be on the same LAN, and the apps contain screens for hosts, conflicts, relays, and legacy connections.

In the planned design the listener has a private network that already connects their machines, for example Tailscale on the main machine and on the phone. They scan one code. The phone shows the library, and the listener saves albums for offline use. Downloads continue while the phone is locked. The network is named only when it is the reason something does not work.

## The parts

```text
        private network (tailnet, another VPN, or a home LAN)
  ┌───────────────────────────────────────────────────────────┐
  │                                                           │
  │   primary host ──── pull ───▶ mirror host (optional)      │
  │   accepts changes             copies and serves           │
  │        ▲                           ▲                      │
  │        │  HTTPS + device token     │                      │
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
- In **pairing**, a device creates its own device token for a library and registers it with the primary, using a one-time code that the owner shows there. The device sends the token with every request.

The terms are defined in the [glossary](../GLOSSARY.md#hosts-and-devices).

## Where each part is designed

| Part | Document | Issues |
| --- | --- | --- |
| The decision and what it replaces | [ADR 0008](adr/0008-one-primary-host-over-a-private-network.md) | ASO-158 |
| The HTTPS API, device tokens, and pairing | [Host API design](host-api-design.md) | ASO-160, ASO-164 |
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

One exception applies. Code that the owner's library never ran and that no shipped Apple flow depends on, which is the v5 host-to-host and activation journal code and the connectivity probe, may go before the cutover. Removing the Windows, Android and gpui apps needs the owner's separate decision in ASO-170. The [migration plan](private-network-migration-plan.md) gives the order.

## What stays

- Whole-file download, verification against the content hash, and local playback.
- The playback cache and offline saves, with the distinction that [ADR 0005](adr/0005-distinguish-playback-cache-from-offline-saves.md) draws.
- The catalog, album organization, artwork, playlists, and import. Their identity rules follow [ADR 0006](adr/0006-preserve-source-track-identity-independently-of-audio.md) and [ADR 0007](adr/0007-preserve-track-addresses-when-sharing-audio.md).
- Local playback with no host at all.
- No account, and no service run by the operator of Syncstr.

## What Syncstr asks of the private network

A device must be able to open an HTTPS connection to the host address. That is the whole requirement.

Tailscale meets it with the least work, so Syncstr helps with it first. `tailscale serve` gives the host a name and a certificate that iOS accepts without an exception. The [setup guide](tailscale-setup.md) covers Tailscale, other VPNs, and a home LAN.

A device that reaches a host at a LAN address needs the iOS local network permission. A device that reaches a host over a VPN interface, such as Tailscale, does not.

The device token is the credential on every network. Syncstr does not rely on the private network to decide who may read the library, because a network such as a home LAN can include machines that the listener does not control.

## Order of work

1. Record the decision and run the device spike. The spike can change the download design, so it comes before any build.
2. Remove the code that the owner never ran, within the exception above.
3. Build the store, the migration, the host API, and pairing.
4. Move the Apple apps to the API, then build background downloads and the new first launch.
5. Move the owner's library to the new path, and then remove the code the owner uses daily.
6. Add mirrors and the primary switch, then changes from devices, then the Windows, Android and gpui apps if the owner wants them.

Each step leaves a product that works. The old path stays usable until step 5 is proven. The [migration plan](private-network-migration-plan.md#phases) gives the phases in detail.

## Risks the owner accepted or must still weigh

- A listener without a private network gets a LAN-only product until they set one up.
- iOS allows one VPN at a time, so a listener who needs another VPN on the phone cannot use Tailscale at the same moment.
- Publishing a host with `tailscale serve` puts the machine's full name in public certificate transparency logs.
- With one writer, if the primary is lost, the changes it accepted after a mirror was last caught up are lost, unless the old primary comes back and keeps them aside for the owner.
- Whether background downloads continue over the Tailscale tunnel is not documented. The [device spike](validation/tailscale-device-spike.md) measures it.
