# M3 Apple cluster integration

Status: Apple integration checkpoint approved for main and TestFlight validation.
The complete acceptance gate remains open until the manual checks below pass.

## Implementation order

1. Verify Rust-produced membership and signed change fixtures in Swift. Keep the
   exact signed bytes available across JSON encoders; number formatting or object
   key ordering must not become a platform-dependent signature contract.
2. Persist the pinned cluster root, local grant, membership history, change inbox,
   per-host cursors, jobs, and import batches beside the existing catalog. Preserve
   the current device key, legacy registrations, saved files, and source paths.
3. Discover headless endpoints over the M2 DNS-SD service, redeem a pinned one-use
   invitation, and restore enrollment after restart. QR and paste share one parser.
4. Reconcile multiple hosts into one object-indexed catalog and choose available
   sources for explicit downloads. A host failure changes availability, not the
   catalog. Keep verified local playback independent of network access.
5. Add authenticated client imports with host-authored changes and verified host
   storage acknowledgements. Preserve an import batch until each item has a known
   result. Offer keep/remove only after a host copy is confirmed; never delete the
   user's original source file automatically.
6. Expose enrollment, hosts, jobs, and unresolved alternatives in both Apple apps.
   Keep local-copy removal separate from host-authorized cluster deletion. Default
   automatic transfers to Wi-Fi; permit explicit cellular downloads.

## Acceptance gate

Two headless hosts plus macOS and a physical iPhone must complete enrollment,
import, replication, source failover, explicit download, restart, and offline
playback. Verify partial batch failures and keep/remove prompts, concurrent edit
and deletion resolution, and cellular policy. Simulator builds and tests alone
do not satisfy physical-device verification or audible playback.

Remote relay configuration and the no-manual-router-rule cellular connectivity
test remain M4. Physical-device validation uses a USB development build with a
separate application identifier. Production NAS deployment and router changes
are separate from this milestone.

## Implemented development path

The Apple apps accept the same one-use invitation JSON through paste and the
iPhone QR reader. `cluster-invite --qr` explicitly renders that invitation in a
terminal. The invitation secret is consumed during enrollment and is not saved
in the app's registration. Registration stores the pinned root and signed grants.

The cluster ALPN is `syncstr/cluster/2`. Pages include the exact signature preimage
so Swift does not reconstruct floating-point JSON before verifying a signature.
It does not downgrade to the earlier cluster ALPN or the legacy library protocol.
LAN headless endpoints bind a concrete private or link-local IPv4 interface to
match DNS-SD discovery. The default route's LAN address is preferred, with an
active LAN interface used when no default route exists. This keeps the advertised
address and QUIC reply source consistent on multihomed hosts. A measured wildcard
bind failure changed the reply source between two interfaces and stalled the
physical iPhone handshake. Restart the host after changing its LAN interface.
Global IPv6 candidates are excluded by the LAN-only ingress policy; remote
dual-stack paths remain an M4 concern.

Client uploads carry the object history observed by the client. The host signs
the resulting change; a concurrent deletion remains a competing head. A storage
acknowledgement follows whole-file verification and durable host receipt creation.
Each client import batch retains metadata, target host, per-item outcome, and
local-copy decisions. Failed items and original import sources are not removed.
Automatic queued audio pauses on cellular unless enabled; explicit downloads use
a separate path. Backgrounding iOS cancels transfers and retains durable state.
Organization edits are queued in the same transaction as the local catalog and
sent with their observed object parents. Acknowledgements preserve any newer
local edit. Uploads can select another authorized host after a source fails;
the batch records the host that actually acknowledged each item.

Deleting a managed local copy does not publish a cluster deletion. Re-importing
an observed deleted object waits for explicit restoration confirmation. Album
title conflicts retain affected catalog rows while unrelated objects continue
updating; the user can select an observed title. Disputed membership remains
denied and is displayed separately from metadata conflicts.

## Verification record and outstanding gates

- Rust-generated grants, revocations, disputed membership, exact signed change
  bytes, durable cursors, replay, and registration restoration pass Swift tests.
- A native Swift client discovers and enrolls with real headless processes,
  uploads twice without duplicate history, downloads with hash verification,
  reopens registration, and downloads from a second replicated host after the
  first stops. No fixed LAN address is supplied by this test.
- A batch containing valid and invalid audio preserves its partial results after
  reopening SQLite. Its local-copy removal removes only the verified successful
  managed copy; both import sources remain intact.
- Focused tests verify receipt/job transaction rollback, independent catalog
  updates during album title conflicts, explicit restoration with concurrent
  deletion, and resuming every queued batch after reopening the registration.
- The pre-integration macOS suite passed 63 tests, with two opt-in environment
  tests skipped. After the recovery fixes, nine focused membership and real-host
  tests passed. Rust full-suite tests, all-target Clippy, and the standalone real
  AVPlayer playback/restoration check passed. Both Apple application builds pass.
- The iOS simulator suite passed 47 tests. A separate development app was
  installed and launched on a physical iPhone, and invitation QR scanning was
  confirmed. Enrollment, catalog download, verified audio storage, and audible
  playback were confirmed with two live headless hosts. The user also confirmed
  audible playback after restarting the app with Wi-Fi and cellular disabled.
- The user confirmed enrollment, verified audio storage, and audible playback
  in the separate macOS development app using the same two-host cluster.
- A real-host regression test verifies that a rejected metadata edit stays
  pending while an unrelated edit is acknowledged and reflected in the catalog.
- Native screen verification, complete conflict-resolution interaction coverage,
  physical-device source failover, import batch prompts, and transfer interruption
  checks remain outstanding. Carry these checks into TestFlight validation;
  actual external-network downloads belong to M4. Main integration is approved
  at this checkpoint without declaring the full M3 acceptance gate complete.
