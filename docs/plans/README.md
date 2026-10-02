# Implementation plans

These documents preserve the initial long-term plan. Start with the [README map](../../README.md#code-and-documentation-map) when changing the current Navidrome player. Synchronization, migration, and recovery work are not prerequisites for current app development.

## Plans

- [Initial implementation roadmap](2026-08-15-syncstr-implementation-plan.md): historical sequencing and acceptance gates.
- [Server](server-plan.md): authentication, scanning, catalog, media, synchronization, and backup APIs and storage.
- [Migration](migration-plan.md): non-destructive matching of Music XML and local audio.
- [Apple clients](apple-client-plan.md): SwiftUI, local storage, Keychain, and AVFoundation.
- [Operations](operations-plan.md): deployment, HTTPS, backup, trash, and auditing.

The original sequence was foundation and language selection, contracts, server, migration, synchronization, Apple clients, operations, and MVP acceptance. Check the current scope and successor issues before resuming any of these steps.
