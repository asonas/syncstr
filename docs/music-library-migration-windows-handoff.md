# Continue the migration MVP on Windows

The design interview selected a Windows command-line MVP that imports the
listener's own music into a NAS library host. Continue on Windows because the
source application's actual capabilities and available storage determine the
next implementation steps. The eventual goal is a Syncstr feature; this MVP
establishes migration behavior before product integration.

## Read first

- [Migration plan](music-library-migration-plan.md): agreed scope, workflow and
  acceptance conditions. Use this as the source of truth rather than reopening
  the completed interview.
- [Glossary](../GLOSSARY.md): source metadata, eligible tracks and cloud copies.
- [Source precedence ADR](adr/0004-preserve-source-library-metadata-during-migration.md).
- Repository `AGENTS.md` and the [README map](../README.md#code-and-documentation-map).

## Handoff state

Only design documents and terminology were changed during this task. No
Windows importer exists as a result of this work, and no source library was
enumerated, downloaded, edited or migrated. The macOS scripting dictionary and
existing Syncstr code were inspected; Windows extraction remains unverified.
Earlier Android remote-development configuration does not identify the source
music library or authorize using an Android fixture as the migration target.

Before starting, verify that this document, its linked plan and ADR are present
in the Windows checkout. Record the checkout revision and dirty state, and
create a task worktree according to repository instructions. A document that
exists only in another machine's worktree is not delivered by pulling main.

## First Windows session

Begin with read-only capability checks. Establish whether the session runs in
native Windows or WSL, which Windows account owns the music library, and which
application actually manages music: iTunes or Apple Music. Inspect installed
versions, source-library and media locations, available disk, and existing NAS
connectivity. WSL SSH alone does not establish access to an interactive Windows
application or its automation interfaces.

Use the application's supported export/automation interfaces where available.
Validate actual behavior on this installation before selecting a language or
API. Do not assume macOS AppleScript, iTunes COM, XML cloud-status fields or
library-only artwork extraction are available in the installed Windows app.
Do not replace the application, change library ownership or read a live private
database through an unverified parser merely to make the planned adapter fit.

Produce a small private sample report with the following evidence:

| Capability | Required observation |
|---|---|
| Eligibility | Distinguish subscription-catalog entries from owned imported/purchased/matched/uploaded entries; retain unresolved states |
| Availability | Distinguish an eligible cloud-only record from a locally readable audio file |
| Metadata | Obtain library-edited album/track values and retain embedded values separately |
| Artwork | Extract an image held by the source library, not only an image embedded in audio; record unavailable cases |
| Correspondence | Match a source record to its actual file without using the title alone; identify the source library's ID scope |
| Destination | Establish NAS checkout/runtime, cluster identity, authorized import path and a separate test destination |

Keep source records, personal paths, machine identities and artwork samples in
private task storage. Publish only sanitized findings. Do not log credentials
or invitation tokens. If representative cases are absent, report them as
unverified instead of inventing coverage.

Conclude the capability check with the chosen extraction path and its evidence,
the exact remaining gaps, and the smallest implementation slice. If a required
capability is missing, present the observed constraint and concrete alternatives
before changing the agreed source-data policy. An unknown classification is not
permission to import a subscription track.

## Implementation boundary

When implementation is requested, follow the plan's inventory/preview, import
and resume flow. Keep source acquisition separate from verified NAS import so
downloads and imports can be retried independently. Use the existing headless
Entry/Organization and integrity contracts; investigate any necessary format
extension against the actual sample before designing a generalized framework.

Validate representative albums in an isolated destination. Preserve original
audio bytes, album evidence and explicit Syncstr edits; cover repeat runs and
interrupted transfers. Missing artwork is a reported partial result, not a
reason to lose otherwise eligible audio. Full-library import follows the
listener's review of the sample results. Source deletion and continuous
two-way synchronization are outside the agreed MVP.

## Suggested starting request

> Read `docs/music-library-migration-windows-handoff.md` and its linked design
> documents. Continue the Windows-to-NAS owned-music migration MVP from the
> agreed design. First inspect this Windows environment and verify read-only
> extraction of track origin, library metadata, file correspondence and
> library-only artwork. Report the verified extraction path and any concrete
> gaps before implementation. Keep the existing music library intact; do not
> start bulk downloads or production imports during this capability check.
