# Syncstr design decisions

These decisions describe the local music product. The initial server-oriented specification and superseded decisions remain in Git history. Earlier plans are investigations, not requirements for current onboarding.

| ID | Decision | Rationale | Consequence |
|---|---|---|---|
| D-002 | Consider Music XML only for an initial import | Audio ownership must remain independent of Apple's applications | Migration is deferred |
| D-003 | Build native clients | Use OS audio, background, media-control, and file-access APIs | macOS and iPhone use Swift |
| D-004 | Preserve original audio | Avoid irreversible edits and quality loss | Read originals and transfer byte-identical copies |
| D-009 | Do not adopt a shared Rust synchronization core | FFI and packaging benefits remain unmeasured | Share contracts and test vectors when other platforms need them |
| D-010 | Implement macOS and iPhone first | Validate native playback and transfer with a small scope | Windows and Android are deferred |
| D-011 | Make Mac-folder-to-iPhone local copies the sole music source | General users should not need to administer a server | Supersede the initial NAS authority, server sequencing, account authentication, and media-adapter requirements |
| D-012 | Require explicit pairing approval and verify received audio | Discovery alone does not establish trust; partial files must not become playable | Retain pairing keys in Keychain and publish audio after exact size and SHA-256 checks |

## Unresolved decisions

- Application license: select before an open-source release; retain dependency notices.
- Future platform and remote-transfer support: evaluate against the local product journey.
- Synchronization and metadata editing: define ownership and conflict behavior before implementation.

The user confirmed the local transfer and offline iPhone cold-launch playback journey through TestFlight on 2026-10-07. Recheck it after changes; this does not establish every codec, permission recovery, or locked-screen interaction.
