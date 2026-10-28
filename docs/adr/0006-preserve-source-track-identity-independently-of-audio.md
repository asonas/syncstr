# Preserve source track identity independently of audio copies

Retain separate source registrations as separate library tracks, even when titles or file bytes match. Multiple encodings may belong to one track, but different album releases, live versions, remixes and remasters remain distinct; filename suffixes such as `-1` and `-2` do not establish or collapse identity. Prefer durable, evidenced source-to-Syncstr correspondence reusable across imports and devices over repeated metadata matching; deduplicating file storage must not merge logical tracks.

This is an accepted product boundary, not a claim that the current catalog already supports it. The Windows inventory described in [the implementation handoff](../source-track-identity-windows-handoff.md) establishes source evidence before changing catalog identity or existing playlist references. Exact-byte matching identifies an audio copy, not permission to merge source registrations.
