# Music Player Apple Client Implementation Plan

**Goal:** Deliver native macOS and iPhone clients with local SQLite, offline operations, original-first playback, and accessible SwiftUI.

**Architecture:** SwiftUI uses a local repository and Keychain-backed device credentials. The client implements the SyncService operation contract locally; Rust is not linked. AVFoundation remains platform-specific behind PlaybackService.

**Dependencies:** server OpenAPI and sync vectors; AudioValidation report. Current macOS AVFoundation build passes but XCTest is BLOCKED by Command Line Tools; no iPhone device result exists.

## Boundaries

| Layer | Boundary | Acceptance evidence |
| --- | --- | --- |
| LocalStore | SQLite metadata, cursor, pending operations | crash/retry and snapshot tests |
| SyncClient | `/v1/sync` DTOs | common vector and idempotent retry tests |
| PlaybackService | AVFoundation, downloads, Range | original-first and download hash tests |
| OSIntegration | Keychain, AudioSession, remote commands | simulator/device checklists by case ID |
| SwiftUI | catalog, queue, downloads, settings | accessibility identifiers and VoiceOver tests |

## Implementation order

1. Create local SQLite schema and Keychain device credential boundary.
2. Implement OpenAPI client, pending-operation queue, cursor/snapshot recovery, favorites/rating/playlist/history conflict flows.
3. Build catalog/search/playlist SwiftUI flows with Dynamic Type, VoiceOver labels, keyboard navigation on macOS, and error/retry states.
4. Add download manager: Range resume, partial-file isolation, SHA-256 verification, storage budget, explicit-download protection.
5. Add AVFoundation original-local playback first; only request compatibility copy/server transcode after recorded native failure.
6. On iPhone configure AudioSession/background/remote commands and invoke `IPhonePlaybackProbe.probeAndWriteJSON`; on macOS invoke `PlaybackProbe.probeAndWriteJSON`.
7. Measure and implement gapless and loudness normalization only after device evidence; preserve BLOCKED until then.

## Test cycles and acceptance

- Every offline mutation has a local persistence and resend test using shared vectors.
- macOS/iPhone playback report must contain the same 11 case IDs, JSON output, fixture hashes, and explicit PASS/REJECT/BLOCKED.
- Gapless, background, media-key, and HTTPS Range are not accepted based on code presence; require device/manual evidence.

## Risks / decisions

- XCTest/Xcode setup blocks current macOS automated playback probes; install matching Xcode before treating formats as PASS.
- iPhone hardware, headphones/route changes, and passkey UX remain unmeasured.
