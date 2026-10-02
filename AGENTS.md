## Navigation

For implementation files, build and verification commands, or earlier prototypes, start with the [README map](README.md#code-and-documentation-map).
Write documentation in English. Use relative paths and fictional values in published documentation and fixtures; keep personal filesystem paths, operational hostnames, account details, device identifiers, and session logs out of them.

## Agent skills

- Before changing UI layout, wording, dimensions, or state presentation, read the macOS guidance in [DESIGN.md](DESIGN.md).
- When reviewing changes, read [CODING_STANDARDS.md](CODING_STANDARDS.md) and verify the affected interactions and display states.

- Issues and specs: [GitHub issue conventions](docs/agents/issue-tracker.md).
- Triage: [default labels](docs/agents/triage-labels.md).
- Design terminology and decisions: [domain docs](docs/agents/domain.md).

## macOS launch verification

- Launch or restart builds with `sh apps/macos/run.sh`; pass the target `.app` path for another location. If shutdown times out, inspect the remaining process. See the [macOS guide](apps/macos/README.md#build-and-run).
- Before removing a worktree, confirm that no Syncstr process is running from it.
