# Recovered playlist audit and smart-rule investigation

Status: audit tool recovered; exploratory decoding completed. No playlist
importer, smart evaluator, application UI, or shared-playlist protocol has been
implemented by this work.

## Recovered tool

The Windows handoff supplied `audit.py`, its README and three tests. They are
preserved in [tools/playlist-audit](../../tools/playlist-audit/README.md). The
implementation is unchanged; an additional process-boundary test protects CLI
source preservation, report overwrite refusal, and output-directory restrictions.
All four tests pass on macOS. This does not repeat Windows file observations.

The private report remains outside Git. It contains ordered membership,
occurrence positions, source identity, file observations, and original smart
definitions. It is an inspection artifact, not an import interchange contract.
Do not execute the file audit on macOS to replace Windows availability results.

## Decoder provenance and limits

The public [cvzi/itunes_smartplaylist parser](https://github.com/cvzi/itunes_smartplaylist)
was checked out separately at
`9a36e82d5bfaad9154b50166fee0489f5d9306e2`. Only its parsing API was used locally;
no private data was uploaded, and the dependency was not added to the app.
Call `Parser(info_base64, criteria_base64).result` on the retained smart data.
Preserve `queryTree.fulltree`, options, `ignore`, and logging warnings separately.
The formatted output strips implicit media filters; inspect the full tree rather
than treating that output as a complete executable definition.

All supplied non-system smart definitions produced trees without exceptions.
One definition emitted unknown-cloud-value warnings even though `ignore` was
empty. Therefore neither a returned tree nor an empty `ignore` means complete
support. Keep the original blobs and require warning review. The parser also
reported ascending play-count selection for a limited list; actual source UI
comparison is required before choosing the intended direction.

The decoded sample includes nested all/any groups, source addition-date ranges,
relative dates, artist, album artist, genre, title, composer, media-kind and
podcast filters, ratings, play counts, last-played dates, and cloud state.
Limits and selection order are separate from the predicate. Source-app UI,
boundary dates/time zones, Unicode matching, and evaluated membership equality
have not been verified. Exact private counts and definitions are not fixtures.

## Implementation consequences

1. Keep ordinary playlist storage, synchronization, and XML membership import
   first. The recovered audit is reusable for source inspection, not importing.
2. Prioritize source addition-date preservation and nested all/any conditions
   for smart migration. Native shared addition time remains a distinct field.
3. Treat artist, album artist, genre, title, and composer matching as candidates
   only after defining typed metadata, Unicode comparison, and missing values.
   Retain media-kind and podcast clauses rather than silently dropping them.
4. Preserve history/rating/cloud-based lists as explicitly fixed snapshots until
   their metadata policy and semantics are supported. A history/ratings import
   remains a separate scope decision.
5. Validate limit ordering and unknown cloud values against the Windows source
   application. Successful decoding does not establish iTunes equivalence.

The next core task is the identity/order/causality contract described in the
[implementation plan](../playlist-implementation-plan.md). Windows UI recovery
is not a prerequisite for that work, but remains a gate for source compatibility
acceptance. No existing audio or source library was modified.
