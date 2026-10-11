# Compilation membership repair

This change implements stage A of the [revision plan](../compilation-revision-implementation-plan.md), following the [agreed policy](../compilation-policy-review.md). Artwork acquisition and cluster replication remain separate stages.

## Retained evidence and reassessment

Each track may retain `importContext` (`sourceID`, relative `folder`), disc and track numbers, and the original imported tags. Folder scans establish context from the selected source and catalog identity. File uploads use a persistent importer identity and opaque directory components captured before copying audio. Managed storage paths never establish context. A proven complete-file match retains its original context after relocation; changed file bytes do not inherit the original identity.

`automaticAliases` contains derived membership links. Repair evaluates all retained tracks, including unavailable tracks, and rebuilds these links without creating manual membership revisions. Explicit aliases and listener choices remain separate. Compatible later discs prefer the established album identity. Contradictory evidence withdraws derived links and leaves original album IDs available for reassessment. Classification changes made while automatically grouped retain per-original-album causal histories so a later split does not invalidate those histories.

Schema 2 catalogs upgrade to schema 3 transactionally, using retained source paths only when a source root exists. Reopening persists repaired organization. A folder refresh rereads original tags even when file content has not changed. Missing sources retain the saved organization. The headless store evaluates received retained context; it does not reconstruct source folders from its object store or acquire tags from audio itself.

## Compatibility

Native transfer messages use version 3; the headless HTTP API uses `/v3`. Older message versions are rejected and `/v1` and `/v2` routes return HTTP 426. Both ends require updating. Schema 3 also prevents schema-2 binaries from overwriting new evidence and automatic links. No production data directory or deployment is changed by building this branch.

## Verification

The shared `headless/fixtures/compilation-membership.json` cases specify expected partitions independently of both implementations. They cover twenty artists, absent/negative/unrecognized/mixed flags, different releases and import sources, explicit separation, manual membership, incompatible classification choices, compatible sibling discs, concrete shared credits, ambiguous numbering, unrelated parents, and missing context. Both implementations test reversed record order and repeated repair.

Additional checks cover later-disc arrival through merge, withdrawing derived links after a late contradiction, classification history after reassessment, SQLite rollback and restart, actual M4A metadata refresh and relocation without source mutation, and native-to-Rust transfer. Final execution results are recorded after the branch checks complete.

Distribution signing, TestFlight delivery, physical-device playback, and stage B/C behavior are not established by these checks.
