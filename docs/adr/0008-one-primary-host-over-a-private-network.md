---
status: proposed
---

# Serve a library from one primary host over a private network

Syncstr stops building its own connectivity. It assumes that a private network, such as a tailnet, another VPN, or a home LAN, already connects the listener's machines. A host serves the library over HTTPS at a host address, and a device reaches that address like any other web service. Discovery by mDNS, peer-to-peer transport, relays, the rendezvous directory, and everything that existed to connect hosts across networks are removed once the new path carries the owner's library.

A library has exactly one primary host. Only the primary accepts changes. A library can also have mirrors. A mirror pulls everything from the primary through the same API that a phone uses, keeps a full copy, and can serve that copy to devices. A mirror never accepts a change. Making a mirror the primary is an explicit step that the owner takes on both machines, recorded as a switch number that rises with each switch. Two hosts that accept changes at the same time are out of scope.

The owner decided the two paragraphs above on 2026-11-17. They replace the parts of [ADR 0002](0002-local-first-connectivity-with-user-operated-remote-access.md) that describe discovery, relays, a peer directory, LAN-only enrollment, and several library hosts that exchange music with each other. ADR 0002 still holds where it says that the operator of Syncstr provides no central service, that there are no username and password accounts, and that an administrator can revoke a device.

## Why

Recent work did not change what a listener can do. At the commit before this decision, about 62% of `headless/src` was networking, cluster, and activation code. The activation journal alone, with its inventory tooling, was about 8,660 lines, and no app speaks its protocol. The owner's real library never ran on the cluster or on v5. It runs on the oldest host mode at schema generation 4. Meanwhile the shipped apps can find a host only on the same LAN and reject tailnet addresses.

The cost came from one requirement: several hosts that all accept changes must agree. That requirement needs signed changes, membership grants, ordering, and a protocol to move every host to a new format together. One writer removes the requirement. A second machine is still useful as a backup and as a second place to download from, and a mirror gives both without agreement between writers.

The price is real. A listener cannot edit the library on two hosts and merge the results later. If the primary is lost, the changes it accepted after the mirror was last caught up are lost, unless the old primary comes back, and then they are kept aside for the owner rather than merged. A listener who has no private network gets a LAN-only product until they set one up, and Syncstr now depends on software it does not ship.

## What follows

A device is paired once. During pairing it creates its own device token and registers it with the primary. The token is the credential on every network. Tailscale identity can add to it and never replaces it, because other private networks have nothing like it.

In a planned switch the owner acts on both machines. If the primary is lost, the owner promotes a mirror on the mirror's machine. The old primary stops accepting changes when it next reads the new primary, and the owner's step on the old primary's machine is to make it a mirror or retire it.

Tailscale is the first private network that Syncstr helps with, and it is not required. A device needs a host address that it can reach over HTTPS. Syncstr prefers a certificate from a public authority, which `tailscale serve` provides, because iOS refuses plain HTTP to IP addresses.

Either a Mac or a NAS can be the primary. The macOS app runs the host on a Mac, and the same host runs headless elsewhere.

In the first release, a device reads and downloads. The listener edits the library on the primary. Editing from a device returns later as a request to the primary, described in [the migration plan](../private-network-migration-plan.md).

Whole-file download with hash verification stays the playback model, and [ADR 0005](0005-distinguish-playback-cache-from-offline-saves.md) keeps its distinction between the playback cache and offline saves. Track identity in [ADR 0006](0006-preserve-source-track-identity-independently-of-audio.md) and [ADR 0007](0007-preserve-track-addresses-when-sharing-audio.md) stays a product boundary. How the single-writer store keeps it is decided in the migration plan.

The design is described in [the architecture overview](../private-network-architecture.md). This ADR records a decision and authorizes no production operation.

## Status of the parts

- Accepted on 2026-11-17: one primary, mirrors, the explicit switch, no simultaneous writers, and no connectivity built by Syncstr.
- Proposed, and accepted when the owner merges this document: either machine can be the primary, Tailscale is helped and not required, the device token is the baseline credential, devices are read-only in the first release, and the old stacks are removed only after the owner's library runs on the new path.
- Exception to that last part: code that the owner's library never ran and that no shipped Apple flow depends on, which is the v5 host-to-host and activation journal code and the connectivity probe, may be removed before the cutover. Removing the Windows, Android and gpui apps needs the owner's separate decision in ASO-170, which merging this document does not make.
