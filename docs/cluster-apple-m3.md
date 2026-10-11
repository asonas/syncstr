# M3 Apple cluster integration

Status: implementation in progress, based on the integrated M2 LAN protocol.
Do not merge this milestone before the acceptance gate below is verified.

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
test remain M4. Physical-device validation will use TestFlight. Production NAS
deployment and router changes are separate from this milestone.

## Implemented development path

The Apple apps accept the same one-use invitation JSON through paste and the
iPhone QR reader. `cluster-invite --qr` explicitly renders that invitation in a
terminal. The invitation secret is consumed during enrollment and is not saved
in the app's registration. Registration stores the pinned root and signed grants.

The cluster ALPN is `syncstr/cluster/2`. Pages include the exact signature preimage
so Swift does not reconstruct floating-point JSON before verifying a signature.
It does not downgrade to the earlier cluster ALPN or the legacy library protocol.
LAN headless endpoints bind IPv4 by default to match DNS-SD discovery. A measured
dual-stack failure showed Iroh also trying global IPv6 candidates, which the
LAN-only ingress policy rejected. Remote dual-stack paths remain an M4 concern.

Client uploads carry the object history observed by the client. The host signs
the resulting change; a concurrent deletion remains a competing head. A storage
acknowledgement follows whole-file verification and durable host receipt creation.
Each client import batch retains metadata, target host, per-item outcome, and
local-copy decisions. Failed items and original import sources are not removed.
Automatic queued audio pauses on cellular unless enabled; explicit downloads use
a separate path. Backgrounding iOS cancels transfers and retains durable state.

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
- The pre-integration macOS suite passed 50 tests, with two opt-in environment
  tests skipped. iOS simulator compilation passed. These results must be rerun
  as appropriate after incorporating concurrent changes on main.
- Native screen verification, complete conflict-resolution interaction coverage,
  iOS tests, TestFlight delivery, physical-device playback/interruption tests,
  and the final two-axis review are outstanding. M3 is not complete or merged.
