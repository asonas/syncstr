# Backfill source-library addition dates

The `backfill_addition_times` example applies an independently verified source-library date map to an offline host data directory. It preserves audio files, track identifiers, artwork, organization, and existing history. It emits signed metadata revisions so the dates can reach other devices through normal synchronization. Legacy entries without history receive their first signed import record without copying audio.

This helper targets the pre-v5 legacy cluster catalog. It does not update the
v5 shared-audio catalog, and `Store::open` rejects an activated schema-5 store.
Do not use it as a v5 metadata migration or activation step.

Build with the `p2p` feature. The request contains the existing library identifier and an array of updates:

```json
{
  "library_id": "example-library",
  "tracks": [{
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "track_id": "example-track",
    "expected_added_at": null,
    "added_at": 1700000000000
  }]
}
```

Dates are Unix milliseconds. Convert the original library's UTC timestamp explicitly; do not interpret it as local time. Match source persistent identifiers through migration receipts, or independently verify the audio before assigning a date. Leave unresolved tracks unchanged.

Stop the host, back up data and identity, and verify the restored backup before using the example. Run it against the restored copy first:

```sh
cargo run --release --locked --features p2p --example backfill_addition_times -- ./restored-data ./dates.json
```

The whole request commits atomically. A mismatched library, stale date, conflicting history, or disagreement between stored and signed metadata rejects the request. The supplied date cannot be later than a dated historical revision. Applying the same request again makes no additional revisions.

Validate the full served catalog, existing organization and visibility choices, historical revisions, and audio hashes before activation. All participating clients and hosts must support the optional signed `addedAt` field. After activation, revisions may already have reached other devices; restoring only the host's database is not a distributed undo operation.

Recently Added orders albums by their newest member's addition date. Albums with no dated members retain the existing legacy ordering.
