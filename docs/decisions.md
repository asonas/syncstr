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
| D-013 | Persist each device's catalog and local file locations in SQLite | Preserve identity across restarts and support transactional catalog replacement | Migrate existing JSON without changing pairing or audio; keep the JSON transfer protocol |
| D-014 | Allow additions from any device, with an always-on headless NAS collecting originals | Devices should not have permanently assigned source and receiver roles | The headless HTTPS node and CLI implement explicit uploads and downloads; native app integration, automatic collection, and remote access remain pending |
| D-015 | Implement headless as a standalone Rust service with its own SQLite database | Run on Linux NAS hosts without Apple frameworks or an app database mounted over the network | Share JSON field contracts and fixtures with native apps; use explicit HTTPS endpoints and a shared node token for this first CLI milestone. D-009 still applies to an FFI-based shared synchronization core |

## Unresolved decisions

- Application license: select before an open-source release; retain dependency notices.
- Future platform and remote-transfer support: evaluate against the local product journey.
- Synchronization and metadata editing: define ownership and conflict behavior before implementation.

The user confirmed the local transfer and offline iPhone cold-launch playback journey through TestFlight on 2026-10-07. Recheck it after changes; this does not establish every codec, permission recovery, or locked-screen interaction.
