---
status: accepted
---

# Preserve track addresses when sharing audio

Implement the accepted boundary in [ADR 0006](0006-preserve-source-track-identity-independently-of-audio.md) by retaining existing canonical track IDs and alias resolutions while introducing independent logical-track records and explicit track-to-audio bindings. Hash equality can reuse stored bytes but cannot create a track alias; existing playlist references remain pinned until an explicit revision changes them. Prefer an additive, validated migration and a coordinated protocol upgrade over resetting IDs or projecting multiple registrations back into a hash-keyed catalog; see the [server design](../shared-audio-server-design.md) for migration, concurrency and rollout constraints.
