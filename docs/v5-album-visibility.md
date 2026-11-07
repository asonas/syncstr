# v5 album visibility records

Status: accepted design (ASO-66). The owner accepted the recommended option A of D1 to D4 on 2026-11-07. Implementation follows the bounded slice below under its own issues. It extends the [member mutation contract](v5-member-mutation-contract.md); its older current-state inventory is historical, not a description of today's implemented operations.

## Problem

An album can be hidden or shown on legacy clients, but v5 freezes the organization at activation. A track metadata edit cannot represent an album preference: an album contains several logical tracks and can gain or lose tracks later. Visibility must follow the album's identity without changing its music, playback queue, saved audio, or source registrations.

## Current state

These are source observations, not runtime acceptance results.

| Capability | Evidence | Consequence |
| --- | --- | --- |
| Signed values | `headless/src/shared_audio.rs:44` defines only Track and Correspondence; `:57` derives their subjects | There is no album-level signed decision. |
| Frozen organization | `headless/src/shared_audio.rs:246` copies the legacy organization into the baseline; `:1959` initializes the projected catalog from it | Changing track records does not update album visibility. |
| Album binding | `headless/src/shared_audio.rs:26` stores `Track.album_id`; `:267` obtains migrated album IDs from the organization | Album identity already exists separately from audio hashes and track membership. |
| Apple projection | `apps/macos/SharedAudio.swift:100` starts with `legacy_organization`; `:106` reads a logical track's album ID | A new album preference needs an explicit projection overlay. |
| Apple legacy visibility | `apps/macos/AlbumOrganization.swift:154` canonicalizes visibility subjects; `:167` reads hidden choices | Alias handling and existing hidden choices must survive activation. |
| Rust legacy visibility | `headless/src/organization.rs:88` reads visibility choices; `:95` writes album choices | Visibility belongs to the organization, not an audio object. |
| Android/Windows shared sender | `headless/src/cluster_client.rs:139` changes album visibility through the legacy organization path | Both platforms need the later v5 transport and projection change. |
| Apple entry point | `apps/macos/Library.swift:323` provides the visibility action label | Restore the existing journey after protocol and client support are available. |

## Decisions for the owner

The owner accepted A for each decision below.

### D1. Subject, value and baseline overlay

- **A (recommended).** Add a narrowly scoped value `{"kind":"album-visibility","album":"A-1","hidden":true}` with subject `album-visibility:A-1`. Use existing signed Body fields, including host author, grant, request digest and authenticated member origin. Each edit names its parent heads.
- **B.** Use subject `album:A-1` and an extensible album object containing visibility and future fields. This makes unrelated future album edits compete and requires defining preservation rules now.
- **C.** Encode hidden flags on every current track. This loses the setting when membership changes and can leave an album partially hidden; reject this option.

Under A, expose an additive catalog projection `album_visibility`, keyed by canonical album ID. A resolved entry contains `hidden`; heads remain in the catalog's existing heads map. No v5 entry means use the visibility derived from the frozen organization. Explicit `hidden:false` overrides a legacy hidden choice; absence never means show. Do not rewrite `legacy_organization` or synthesize replacement legacy signed choices.

Apply the existing DAG completeness and conflict rules. A stale request returns `needs-review` with current subject heads and stores nothing. Concurrent distinct records remain competing heads even if their boolean values happen to match; no timestamp or arrival order chooses a winner. When no resolved v5 value exists because of a conflict or missing parents, preserve the baseline visibility for presentation and expose the unresolved subject. Never hide unrelated albums or fail the entire catalog. Disable further ordinary visibility edits for that subject until an explicit resolution names all competing heads; the implementation must define that resolution path before enabling the feature.

### D2. Stable album IDs and membership changes

- **A (recommended).** Preserve the canonical IDs established by the activation organization and aliases. Explicit `Track.album_id` refers to that stable identity. Joining, leaving, renaming or emptying an album never recalculates its ID or removes its visibility preference. Tracks without an explicit binding retain the existing projected membership fallback; do not mint a second ID for the same established album.
- **B.** Derive IDs from current title, artist, audio hashes or membership. Renames and imports would unexpectedly reset visibility; reject this option.

Normalize existing aliases at the host before subject construction, expected-head comparison and signing. Freeze those aliases with the baseline. Reject unknown album IDs in this first slice; creating albums or changing alias/merge relationships needs its own signed identity contract. An established empty album retains its identity and preference, so a later joining track inherits the setting. Moving a track from hidden A to visible B follows B's setting; A stays hidden for its remaining or future tracks. Equal titles or shared audio never combine album identities.

### D3. Who may change visibility?

- **A (recommended).** Any currently authorized member may request a change, consistent with mutation decision D1. The accepting host validates membership and signs the album record with `origin: {member, grant}`. A later origin revocation does not invalidate an accepted record.
- **B.** Restrict changes to hosts. This is simpler authorization but removes a legacy member capability without an identified product requirement.

Hiding is a shared presentation preference, not cluster-wide deletion. It changes neither track retirement nor audio retention. Reject requests from revoked members; preserve their queued intent and use the verified Hello refusal where available. A transport failure alone is not proof of revocation.

### D4. Mutation operation

- **A (recommended).** Add `set-album-visibility`, advertised in Hello only by supporting hosts. Payload is `{"album":"A-1","hidden":true}`; expected is `{"album-visibility:A-1":["<head>"]}`; confirmed is empty. Require a real JSON boolean. Initially submit one album per durable request ID; batch UI creates independent requests and reports partial outcomes.
- **B.** Extend `edit-track`. This couples an album preference to an arbitrary track and cannot address an empty album; reject this option.

Reuse the existing typed mutation replies, transaction boundary, request-ID digest validation and same-accepting-host retry rule (D3 A). Hash the original canonical request and origin member before rebuilding projection state; a retry returns its original accepted record/host/heads even after later changes. A reused ID with different intent is rejected. This slice adds no cross-host retry guarantee.

## Acceptance cases

1. With no new records, every migrated album keeps its baseline visibility. Explicit show overrides baseline hidden, and explicit hide overrides baseline visible.
2. Hiding A affects all its current tracks and later arrivals. Removing its last track and later adding another does not reset the setting.
3. Renaming an album or changing membership does not change its ID. An existing alias targets the same canonical visibility subject; equal titles or hashes do not merge albums.
4. Two albums sharing one Audio Copy keep independent visibility. Saved copies, playback pins, queue order and original files remain unchanged.
5. A valid ordinary member receives accepted with a host-signed origin. A revoked member cannot create a record; accepted history remains readable after revocation.
6. A stale request returns needs-review with current heads and no partial state. Competing records remain visible as an unresolved subject without blocking unrelated catalog or playlist reads.
7. Resolving visibility names every conflicting head and produces one explicit boolean. Missing-parent history stays unresolved and never silently becomes an authoritative show/hide decision.
8. A lost reply followed by a retry at the same host returns the original accepted reply and creates one record. Different intent under the same ID is rejected.
9. An unsupported host advertises no operation. The client preserves the intent, explains unavailability and never sends a legacy metadata mutation as fallback.
10. Offline restart restores both resolved visibility and pending requests. Apple, Android and Windows agree on canonical IDs, explicit false, baseline fallback and conflict presentation.

## Bounded implementation slice

After the owner decides D1–D4, deliver host schema/value decoding, projection, mutation validation, capability advertisement and focused Rust tests first. Cover baseline overlay, stable IDs, aliases, conflicts/incomplete history, authorization, provenance, independent albums and idempotency. Define an album-visibility resolution operation in that same host contract before enabling writes; do not reuse track resolution implicitly.

Then add the catalog overlay and durable request queue to Apple, followed by the shared Rust client used by Android and Windows. Enable the existing visibility controls only when the target host advertises support and the local projection supports the value. Test offline restart, partial batch outcomes and same-host retry on each platform.

Existing record-value decoders reject unknown kinds. Upgrade all hosts before producing the new signed value, and ensure readers can apply the new catalog overlay before enabling the operation. Older clients otherwise risk showing stale baseline visibility; capability discovery alone does not update their projection. Treat deployment order as an acceptance gate, not an automatic migration.

Out of scope: album creation/merge/split, new aliases, other album choices, metadata reclassification, track retirement, deleting audio, per-device visibility, and cross-host retry. This document changes no code, signed data or deployed service.
