import Foundation
import SQLite3

struct CatalogSnapshot {
    var catalog: LocalCatalog
    var sourceRoot: URL?
    var sourcePaths: [String: String]
}

extension CatalogDatabase {
    private func migrateClusterMembership() throws {
        try execute("CREATE TABLE IF NOT EXISTS cluster_registration (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS cluster_signed_changes (id TEXT PRIMARY KEY, payload TEXT NOT NULL, accepted INTEGER NOT NULL CHECK(accepted IN (0, 1)))")
        try execute("CREATE TABLE IF NOT EXISTS cluster_peer_cursors (peer TEXT PRIMARY KEY, sequence INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS cluster_track_ids (object TEXT PRIMARY KEY, id TEXT NOT NULL UNIQUE)")
        try execute("CREATE TABLE IF NOT EXISTS cluster_import_batches (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS cluster_transfer_settings (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), cellular INTEGER NOT NULL CHECK(cellular IN (0, 1)))")
        try execute("CREATE TABLE IF NOT EXISTS cluster_metadata_queue (object TEXT PRIMARY KEY, payload TEXT NOT NULL)")
    }

    func clusterMetadataEdits() throws -> [ClusterMetadataEdit] {
        try rows("SELECT payload FROM cluster_metadata_queue ORDER BY rowid").map {
            guard let payload = $0[0] else { throw LocalMusicError.invalidData }
            return try JSONDecoder().decode(ClusterMetadataEdit.self, from: Data(payload.utf8))
        }
    }

    private func saveClusterMetadataEdit(_ edit: ClusterMetadataEdit) throws {
        let payload = try JSONEncoder().encode(edit)
        guard payload.count <= ClusterSignedChange.maximumBytes else { throw LocalMusicError.invalidData }
        try execute("INSERT INTO cluster_metadata_queue VALUES (?, ?) ON CONFLICT(object) DO UPDATE SET payload = excluded.payload",
            [edit.entry.sha256, String(decoding: payload, as: UTF8.self)])
    }

    func finishClusterMetadataEdit(_ edit: ClusterMetadataEdit, revision: String) throws {
        guard ClusterIdentity.isLowercaseHex256(revision) else { throw LocalMusicError.invalidData }
        try transaction {
            guard var pending = try clusterMetadataEdits().first(where: { $0.entry.sha256 == edit.entry.sha256 }) else { return }
            if pending.id == edit.id {
                try execute("DELETE FROM cluster_metadata_queue WHERE object = ?", [edit.entry.sha256])
            } else if pending.parents == edit.parents {
                pending.parents = [revision]
                try saveClusterMetadataEdit(pending)
            }
        }
    }

    func clusterRegistration() throws -> ClusterRegistration? {
        guard let payload = try rows("SELECT payload FROM cluster_registration WHERE singleton = 1").first?.first ?? nil else { return nil }
        return try JSONDecoder().decode(ClusterRegistration.self, from: Data(payload.utf8))
    }

    func saveClusterBatch(_ batch: ClusterImportBatch) throws {
        guard UUID(uuidString: batch.id) != nil, ClusterIdentity.isLowercaseHex256(batch.host),
              Set(batch.items.map(\.id)).count == batch.items.count,
              batch.items.allSatisfy({ UUID(uuidString: $0.id) != nil && ($0.entry.map(LocalMusicStore.valid) ?? true) }) else { throw LocalMusicError.invalidData }
        try execute("INSERT INTO cluster_import_batches VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload = excluded.payload", [batch.id, String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)])
    }

    func clusterBatches() throws -> [ClusterImportBatch] {
        try rows("SELECT payload FROM cluster_import_batches ORDER BY rowid").map { row in
            guard let value = row[0] else { throw LocalMusicError.invalidData }
            return try JSONDecoder().decode(ClusterImportBatch.self, from: Data(value.utf8))
        }
    }

    func clusterAutomaticCellular() throws -> Bool {
        try rows("SELECT cellular FROM cluster_transfer_settings WHERE singleton = 1").first?.first == "1"
    }

    func setClusterAutomaticCellular(_ enabled: Bool) throws {
        try execute("INSERT OR REPLACE INTO cluster_transfer_settings VALUES (1, ?)", [enabled ? "1" : "0"])
    }

    func enrollCluster(invitation: ClusterInvitation, grantID: String, membership: ClusterMembership, ownID: String, name: String) throws {
        guard name.utf8.count <= 2048 else { throw LocalMusicError.invalidData }
        let relay = try invitation.relay.map(ClusterInvitation.validatedRelay)
        let grant = try membership.verify(grantID)
        guard grant.cluster == invitation.cluster, grant.issuer == invitation.host,
              grant.member == ownID, grant.authority != nil else { throw LocalMusicError.unauthorized }
        for item in membership.grants {
            guard item.cluster == grant.cluster else { throw LocalMusicError.unauthorized }
            _ = try membership.chain(item.id)
        }
        for item in membership.revocations { guard item.cluster == grant.cluster else { throw LocalMusicError.unauthorized } }
        _ = try membership.revocationState()
        try transaction {
            var effective = membership
            if let previous = try clusterRegistration() {
                guard previous.localGrant == grantID, previous.membership.root == membership.root else { throw LocalMusicError.unauthorized }
                effective = try previous.membership.merging(membership, presenter: invitation.host)
            }
            try execute("INSERT OR IGNORE INTO cluster_identity VALUES (1, ?, ?)", [grant.cluster, ownID])
            guard let identity = try rows("SELECT id, member_id FROM cluster_identity WHERE singleton = 1").first,
                  identity == [grant.cluster, ownID] else { throw LocalMusicError.unauthorized }
            let registration = ClusterRegistration(name: name, localGrant: grantID, membership: effective, relay: relay)
            try execute("INSERT OR REPLACE INTO cluster_registration VALUES (1, ?)", [String(decoding: try JSONEncoder().encode(registration), as: UTF8.self)])
        }
    }

    func authenticateClusterPeer(_ peer: String, membership: ClusterMembership) throws {
        try transaction {
            guard var registration = try clusterRegistration() else { throw LocalMusicError.unauthorized }
            registration.membership = try registration.membership.merging(membership, presenter: peer)
            try execute("UPDATE cluster_registration SET payload = ? WHERE singleton = 1", [String(decoding: try JSONEncoder().encode(registration), as: UTF8.self)])
        }
        guard let registration = try clusterRegistration() else { throw LocalMusicError.unauthorized }
        _ = try registration.membership.authorize(peer, host: true)
        _ = try registration.membership.verify(registration.localGrant)
        try transaction { try acceptPendingClusterChanges(registration.membership) }
    }

    func clusterCursor(_ peer: String) throws -> Int64 {
        guard let value = try rows("SELECT sequence FROM cluster_peer_cursors WHERE peer = ?", [peer]).first?.first ?? nil else { return 0 }
        guard let sequence = Int64(value), sequence >= 0 else { throw LocalMusicError.invalidData }
        return sequence
    }

    private func readSignedChanges(acceptedOnly: Bool) throws -> [ClusterSignedChange] {
        try rows("SELECT payload FROM cluster_signed_changes \(acceptedOnly ? "WHERE accepted = 1" : "") ORDER BY rowid").map { row in
            guard let payload = row[0] else { throw LocalMusicError.invalidData }
            return try JSONDecoder().decode(ClusterSignedChange.self, from: Data(payload.utf8))
        }
    }

    func clusterChanges() throws -> [ClusterChange] {
        guard let registration = try clusterRegistration() else { return [] }
        return try readSignedChanges(acceptedOnly: true).map { try $0.decode(membership: registration.membership) }
    }

    func receiveClusterPage(peer: String, sequence: Int64, signed: ClusterSignedChange) throws {
        try transaction {
            guard sequence > 0, let registration = try clusterRegistration() else { throw LocalMusicError.unauthorized }
            let membership = registration.membership
            _ = try membership.authorize(peer, host: true)
            _ = try membership.verify(registration.localGrant)
            let change = try signed.decode(membership: membership)
            guard change.cluster == membership.grants.first?.cluster else { throw LocalMusicError.unauthorized }
            if let existing = try rows("SELECT payload FROM cluster_signed_changes WHERE id = ?", [signed.id]).first?.first ?? nil {
                guard try JSONDecoder().decode(ClusterSignedChange.self, from: Data(existing.utf8)) == signed else { throw LocalMusicError.invalidData }
            } else {
                try execute("INSERT INTO cluster_signed_changes VALUES (?, ?, 0)", [signed.id, String(decoding: try JSONEncoder().encode(signed), as: UTF8.self)])
            }
            guard let row = try rows("SELECT COALESCE(SUM(length(CAST(payload AS BLOB))), 0) FROM cluster_signed_changes WHERE accepted = 0").first,
                  let value = row[0], let size = Int(value),
                  size <= 128 * 1024 * 1024 else { throw LocalMusicError.invalidData }
            try acceptPendingClusterChanges(membership)
            let current = try clusterCursor(peer)
            guard sequence >= current else { throw LocalMusicError.invalidData }
            try execute("INSERT INTO cluster_peer_cursors VALUES (?, ?) ON CONFLICT(peer) DO UPDATE SET sequence = excluded.sequence", [peer, String(sequence)])
        }
    }

    private func acceptPendingClusterChanges(_ membership: ClusterMembership) throws {
        let all = try readSignedChanges(acceptedOnly: false).map { try $0.decode(membership: membership) }
        var accepted = try clusterChanges()
        var known = Set(accepted.map(\.id))
        while true {
            let previous = known.count
            for record in all where !known.contains(record.id) {
                let ready = record.parents.allSatisfy { id in accepted.contains { $0.id == id && $0.object == record.object } }
                    && record.previous.allSatisfy { id in accepted.contains { $0.id == id && $0.author == record.author } }
                if ready, try record.authorized(by: membership, history: all) {
                    if let entry = record.action.entry, let size = entry.track.size {
                        try execute("INSERT OR IGNORE INTO cluster_objects VALUES (?, ?)", [entry.sha256, String(size)])
                        guard try rows("SELECT bytes FROM cluster_objects WHERE sha256 = ?", [entry.sha256]).first?.first == String(size) else { throw LocalMusicError.invalidData }
                    }
                    try execute("UPDATE cluster_signed_changes SET accepted = 1 WHERE id = ?", [record.id])
                    known.insert(record.id); accepted.append(record)
                }
            }
            if previous == known.count { break }
        }
    }

    func clusterDownloadEntry(object: String, peer: String) throws -> LocalEntry {
        try transaction {
            guard let registration = try clusterRegistration() else { throw LocalMusicError.unauthorized }
            _ = try registration.membership.verify(registration.localGrant)
            _ = try registration.membership.authorize(peer, host: true)
            let records = try clusterChanges()
            let states = try ClusterObjectState.project(records, membership: registration.membership)
            guard let state = states.first(where: { $0.object == object }),
                  let entry = try state.selected(in: records)?.action.entry else { throw LocalMusicError.invalidData }
            return entry
        }
    }

    func finishClusterDownload(_ jobID: String, entry: LocalEntry, file: URL) throws {
        guard try LocalMusicStore.digest(file: file) == entry.sha256 else { throw LocalMusicError.invalidData }
        try transaction {
            guard let registration = try clusterRegistration() else { throw LocalMusicError.unauthorized }
            let member = try registration.membership.verify(registration.localGrant).member
            let records = try clusterChanges()
            let states = try ClusterObjectState.project(records, membership: registration.membership)
            guard let state = states.first(where: { $0.object == entry.sha256 }),
                  let selected = try state.selected(in: records)?.action.entry,
                  selected.track.size == entry.track.size else { throw LocalMusicError.invalidData }
            try recordReceived(entry)
            try execute("UPDATE cluster_jobs SET state = 'complete' WHERE id = ? AND sha256 = ? AND destination = ? AND state = 'running'", [jobID, entry.sha256, member])
            guard sqlite3_changes(connection) == 1 else { throw LocalMusicError.invalidData }
        }
    }

    func retryClusterJob(_ jobID: String) throws {
        try execute("UPDATE cluster_jobs SET state = 'queued' WHERE id = ? AND state = 'running'", [jobID])
    }

    func clusterObjectStates() throws -> [ClusterObjectState] {
        try transaction {
            guard let registration = try clusterRegistration() else { return [] }
            return try ClusterObjectState.project(clusterChanges(), membership: registration.membership)
        }
    }

    func clusterAlbumConflicts() throws -> [ClusterAlbumConflict] {
        try transaction {
            guard let registration = try clusterRegistration() else { return [] }
            let records = try clusterChanges()
            let states = try ClusterObjectState.project(records, membership: registration.membership)
            let selected = try states.filter { !$0.conflicted }.compactMap { try $0.selected(in: records) }
            return try ClusterAlbumConflict.project(selected, organization: readSnapshot()?.catalog.organization ?? AlbumOrganization())
        }
    }

    func clusterCatalog() throws -> LocalCatalog {
        try transaction {
            guard let registration = try clusterRegistration() else { throw LocalMusicError.unauthorized }
            let grant = try registration.membership.verify(registration.localGrant)
            let previous = try readSnapshot()?.catalog
            let records = try clusterChanges()
            let states = try ClusterObjectState.project(records, membership: registration.membership)
            let known = Set(records.map(\.object))
            let selected = try states.filter { !$0.conflicted }.compactMap { try $0.selected(in: records) }
            let albumConflicts = try ClusterAlbumConflict.project(selected, organization: previous?.organization ?? AlbumOrganization())
            let blocked = Set(albumConflicts.flatMap(\.objects))
            let conflicts = Set(states.filter(\.conflicted).map(\.object)).union(blocked)
            var entries = (previous?.entries ?? []).filter { !known.contains($0.sha256) || conflicts.contains($0.sha256) }
            var organization = previous?.organization ?? AlbumOrganization()
            let deleted = try Set(states.filter { state in
                guard !state.conflicted else { return false }
                return try state.selected(in: records) == nil
            }.map(\.object))
            try organization.excludeClusterObjects(deleted)
            var titles: [String: String] = [:]
            for state in states where !state.conflicted && !blocked.contains(state.object) {
                guard let record = try state.selected(in: records), var entry = record.action.entry,
                      let incoming = record.action.organization else { continue }
                try organization.merge(incoming)
                for album in incoming.albums {
                    let id = organization.canonical(album.id)
                    titles[id] = album.title
                }
                let saved = try rows("SELECT id FROM cluster_track_ids WHERE object = ?", [state.object]).first?.first ?? nil
                let id = saved ?? previous?.entries.first(where: { $0.sha256 == state.object })?.track.id ?? entry.track.id
                try execute("INSERT OR IGNORE INTO cluster_track_ids VALUES (?, ?)", [state.object, id])
                guard try rows("SELECT id FROM cluster_track_ids WHERE object = ?", [state.object]).first?.first == id else { throw LocalMusicError.invalidData }
                if entry.track.id != id {
                    if organization.trackAliases == nil { organization.trackAliases = [:] }
                    if organization.tracks.contains(where: { $0.id == id }) {
                        organization.trackAliases?[entry.track.id] = id
                    }
                    entry.track.id = id
                    if entry.track.coverArt != nil { entry.track.coverArt = id }
                }
                entries.append(entry)
            }
            for index in organization.albums.indices {
                if let title = titles[organization.canonical(organization.albums[index].id)] {
                    organization.albums[index].title = title
                }
            }
            try organization.validate()
            return LocalCatalog(id: previous?.id ?? grant.cluster, name: registration.name, entries: entries, organization: organization)
        }
    }
}

/// Each operation owns its connection; catalog replacement commits as one transaction.
final class CatalogDatabase {
    private var connection: OpaquePointer?

    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(connection)
            connection = nil
            throw error
        }
        sqlite3_busy_timeout(connection, 5000)
        do {
            let version = try rows("PRAGMA user_version").first?.first ?? nil
            guard ["0", "1", "2", "3", "4"].contains(version) else { throw LocalMusicError.invalidData }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS catalog (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL, name TEXT NOT NULL, source_root TEXT)")
                try execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, position INTEGER NOT NULL, sha256 TEXT NOT NULL, payload TEXT NOT NULL, source_path TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS entries_content ON entries(sha256)")
                try execute("CREATE TABLE IF NOT EXISTS received_files (relative_path TEXT PRIMARY KEY, sha256 TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS organization (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), payload TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS artwork_assets (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                if version != "4" { _ = try readSnapshot() }
                try migrateCluster()
                try migrateClusterMembership()
                try execute("PRAGMA user_version = 4")
            }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    private func failure() -> NSError {
        NSError(domain: "Syncstr.CatalogDatabase", code: Int(sqlite3_errcode(connection)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
    }

    private func statement(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        for (index, value) in values.enumerated() {
            let result: Int32
            if let value {
                result = sqlite3_bind_text(statement, Int32(index + 1), value, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                result = sqlite3_bind_null(statement, Int32(index + 1))
            }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }

    private func execute(_ sql: String, _ values: [String?] = []) throws {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func rows(_ sql: String, _ values: [String?] = []) throws -> [[String?]] {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while true {
            try Task.checkCancellation()
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map {
                    String(decoding: UnsafeBufferPointer(start: $0, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
                }
            })
        }
    }

    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func snapshot() throws -> CatalogSnapshot? {
        try transaction { try readSnapshot() }
    }

    func containsCatalog() throws -> Bool {
        try rows("SELECT EXISTS(SELECT 1 FROM catalog WHERE singleton = 1)").first?.first == "1"
    }

    private func readSnapshot() throws -> CatalogSnapshot? {
        guard let header = try rows("SELECT id, name, source_root FROM catalog WHERE singleton = 1").first,
              let id = header[0], let name = header[1] else { return nil }
        var entries: [LocalEntry] = []
        var paths: [String: String] = [:]
        for row in try rows("SELECT id, payload, source_path FROM entries ORDER BY position") {
            try Task.checkCancellation()
            guard let trackID = row[0], let payload = row[1] else { throw LocalMusicError.invalidData }
            let entry = try JSONDecoder().decode(LocalEntry.self, from: Data(payload.utf8))
            guard LocalMusicStore.valid(entry), entry.track.id == trackID else { throw LocalMusicError.invalidData }
            entries.append(entry)
            paths[trackID] = row[2]
        }
        var catalog = LocalCatalog(id: id, name: name, entries: entries)
        if let payload = try rows("SELECT payload FROM organization WHERE singleton = 1").first?.first ?? nil {
            catalog.organization = try JSONDecoder().decode(AlbumOrganization.self, from: Data(payload.utf8))
            if catalog.organization?.artwork != nil {
                for row in try rows("SELECT id, payload FROM artwork_assets") {
                    try Task.checkCancellation()
                    guard let id = row[0], let payload = row[1], let data = Data(base64Encoded: payload) else { throw LocalMusicError.invalidData }
                    if catalog.organization?.artwork?.assets[id] != nil { catalog.organization?.artwork?.assets[id] = data }
                }
            }
            try catalog.organization?.validate()
        }
        let previous = catalog.organization
        catalog.organize(folders: header[2] == nil ? [:] : paths.mapValues { ($0 as NSString).deletingLastPathComponent })
        try catalog.organization?.validate()
        if previous != catalog.organization {
            try writeOrganization(catalog.organization!)
        }
        return CatalogSnapshot(catalog: catalog,
            sourceRoot: header[2].map { URL(fileURLWithPath: $0, isDirectory: true) }, sourcePaths: paths)
    }

    func save(_ catalog: LocalCatalog, sourceRoot: URL? = nil, sourcePaths: [String: String]? = nil,
              received: [LocalEntry] = [], clusterEdits: Bool = false) throws {
        guard Set(catalog.entries.map { $0.track.id }).count == catalog.entries.count,
              catalog.entries.allSatisfy(LocalMusicStore.valid) else { throw LocalMusicError.invalidData }
        try transaction {
            let previous = try readSnapshot()
            let sameLibrary = previous?.catalog.id == catalog.id
            let root = sourceRoot ?? (sameLibrary ? previous?.sourceRoot : nil)
            let paths = sourcePaths ?? (sameLibrary ? previous?.sourcePaths ?? [:] : [:])
            var organized = catalog
            if organized.organization == nil, sameLibrary { organized.organization = previous?.catalog.organization }
            organized.organize(folders: root == nil ? [:] : paths.mapValues { ($0 as NSString).deletingLastPathComponent })
            try organized.organization?.validate()
            if clusterEdits, let registration = try clusterRegistration(), let organization = organized.organization {
                _ = try registration.membership.verify(registration.localGrant)
                let records = try clusterChanges()
                let pending = try clusterMetadataEdits()
                for state in try ClusterObjectState.project(records, membership: registration.membership) {
                    let metadata = try organization.forClusterObject(state.object)
                    guard try metadata != previous?.catalog.organization?.forClusterObject(state.object) else { continue }
                    guard !state.conflicted else { throw LocalMusicError.clusterNeedsAttention }
                    guard let selected = try state.selected(in: records)?.action.entry else { continue }
                    let entry = organized.entries.first { $0.sha256 == state.object } ?? selected
                    let parents = pending.first(where: { $0.entry.sha256 == state.object })?.parents ?? state.heads.map(\.id)
                    try saveClusterMetadataEdit(ClusterMetadataEdit(id: UUID().uuidString, entry: entry, organization: metadata, parents: parents))
                }
            }
            try writeOrganization(organized.organization!)
            try execute("DELETE FROM entries")
            try execute("INSERT OR REPLACE INTO catalog VALUES (1, ?, ?, ?)", [catalog.id, catalog.name, root?.path])
            for (position, entry) in catalog.entries.enumerated() {
                let payload = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
                try execute("INSERT INTO entries VALUES (?, ?, ?, ?, ?)",
                    [entry.track.id, String(position), entry.sha256, payload, paths[entry.track.id]])
            }
            for entry in received { try recordReceived(entry) }
            try indexClusterCatalog(organized, memberID: nil)
        }
    }

    func recordReceived(_ entry: LocalEntry) throws {
        try execute("INSERT OR REPLACE INTO received_files VALUES (?, ?)",
            [entry.sha256 + "." + (entry.track.suffix ?? "audio"), entry.sha256])
    }

    func forgetReceived(_ entry: LocalEntry) throws {
        try execute("DELETE FROM received_files WHERE relative_path = ? AND sha256 = ?",
            [entry.sha256 + "." + (entry.track.suffix ?? "audio"), entry.sha256])
    }

    private func writeOrganization(_ organization: AlbumOrganization) throws {
        try organization.validate()
        for (id, data) in organization.artwork?.assets ?? [:] {
            try execute("INSERT OR IGNORE INTO artwork_assets VALUES (?, ?)", [id, data.base64EncodedString()])
        }
        var metadata = organization
        metadata.artwork?.assets = organization.artwork?.assets.mapValues { _ in Data() } ?? [:]
        try execute("INSERT OR REPLACE INTO organization VALUES (1, ?)", [String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)])
    }
}

extension CatalogDatabase {
    private func migrateCluster() throws {
        try execute("CREATE TABLE IF NOT EXISTS cluster_schema (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), version INTEGER NOT NULL)")
        try execute("INSERT OR IGNORE INTO cluster_schema VALUES (1, 1)")
        let inserted = sqlite3_changes(connection) == 1
        guard try rows("SELECT version FROM cluster_schema WHERE singleton = 1").first?.first == "1" else { throw LocalMusicError.invalidData }
        guard inserted else { return }
        try execute("CREATE TABLE IF NOT EXISTS cluster_identity (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL, member_id TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS cluster_peers (id TEXT PRIMARY KEY, name TEXT NOT NULL, address TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS cluster_objects (sha256 TEXT PRIMARY KEY, bytes INTEGER NOT NULL CHECK(bytes > 0))")
        try execute("CREATE TABLE IF NOT EXISTS cluster_locations (library_id TEXT NOT NULL, track_id TEXT NOT NULL, member_id TEXT NOT NULL, sha256 TEXT NOT NULL, PRIMARY KEY(library_id, track_id, member_id))")
        try execute("CREATE TABLE IF NOT EXISTS cluster_pending_changes (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS cluster_jobs (id TEXT PRIMARY KEY, sha256 TEXT NOT NULL, source TEXT NOT NULL, destination TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('queued', 'running', 'complete')))")
        if let snapshot = try readSnapshot() { try indexClusterCatalog(snapshot.catalog, memberID: nil) }
    }

    private func indexClusterCatalog(_ catalog: LocalCatalog, memberID: String?) throws {
        guard !catalog.id.isEmpty, memberID.map(ClusterIdentity.isLowercaseHex256) ?? true else { throw LocalMusicError.invalidData }
        for entry in catalog.entries {
            guard ClusterIdentity.isLowercaseHex256(entry.sha256), !entry.track.id.isEmpty,
                  let size = entry.track.size, size > 0, size <= 20 * 1024 * 1024 * 1024 else { throw LocalMusicError.invalidData }
            try execute("INSERT OR IGNORE INTO cluster_objects VALUES (?, ?)", [entry.sha256, String(size)])
            guard try rows("SELECT bytes FROM cluster_objects WHERE sha256 = ?", [entry.sha256]).first?.first == String(size) else { throw LocalMusicError.invalidData }
            try execute("INSERT INTO cluster_locations VALUES (?, ?, ?, ?) ON CONFLICT(library_id, track_id, member_id) DO UPDATE SET sha256 = excluded.sha256",
                [catalog.id, entry.track.id, memberID ?? "", entry.sha256])
        }
    }

    func observeClusterCatalog(_ catalog: LocalCatalog, memberID: String? = nil) throws {
        try transaction { try indexClusterCatalog(catalog, memberID: memberID) }
    }

    func createCluster(memberID: String) throws -> ClusterIdentity {
        guard ClusterIdentity.isLowercaseHex256(memberID) else { throw LocalMusicError.invalidData }
        return try transaction {
            try execute("INSERT OR IGNORE INTO cluster_identity VALUES (1, ?, ?)", [UUID().uuidString.lowercased(), memberID])
            guard let row = try rows("SELECT id, member_id FROM cluster_identity WHERE singleton = 1").first,
                  let id = row[0], row[1] == memberID else { throw LocalMusicError.invalidData }
            return ClusterIdentity(id: id, memberID: memberID)
        }
    }

    func rememberClusterPeer(_ peer: ClusterKnownPeer) throws {
        guard ClusterIdentity.isLowercaseHex256(peer.id), peer.name.utf8.count <= 2048,
              peer.address.map({ $0.utf8.count <= 16384 }) ?? true else { throw LocalMusicError.invalidData }
        if let address = peer.address {
            guard let value = try JSONSerialization.jsonObject(with: Data(address.utf8)) as? [String: Any],
                  value["id"] as? String == peer.id else { throw LocalMusicError.invalidData }
        }
        try execute("INSERT INTO cluster_peers VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, address = excluded.address", [peer.id, peer.name, peer.address])
    }

    func forgetClusterPeer(_ id: String) throws {
        try execute("DELETE FROM cluster_peers WHERE id = ?", [id])
    }

    func clusterInventory() throws -> ClusterInventory {
        try transaction {
            let identity = try rows("SELECT id, member_id FROM cluster_identity WHERE singleton = 1").first.map { row -> ClusterIdentity in
                guard let id = row[0], let member = row[1] else { throw LocalMusicError.invalidData }
                return ClusterIdentity(id: id, memberID: member)
            }
            let peers = try rows("SELECT id, name, address FROM cluster_peers ORDER BY id").map { row -> ClusterKnownPeer in
                guard let id = row[0], let name = row[1] else { throw LocalMusicError.invalidData }
                return ClusterKnownPeer(id: id, name: name, address: row[2])
            }
            let objects = try rows("SELECT sha256, bytes FROM cluster_objects ORDER BY sha256").map { row -> ClusterObject in
                guard let hash = row[0], let size = row[1].flatMap(Int64.init) else { throw LocalMusicError.invalidData }
                let locations = try rows("SELECT library_id, track_id, NULLIF(member_id, '') FROM cluster_locations WHERE sha256 = ? ORDER BY library_id, track_id, member_id", [hash]).map { row -> ClusterLocation in
                    guard let library = row[0], let track = row[1] else { throw LocalMusicError.invalidData }
                    return ClusterLocation(libraryID: library, trackID: track, memberID: row[2])
                }
                return ClusterObject(sha256: hash, bytes: size, locations: locations)
            }
            return ClusterInventory(cluster: identity, peers: peers, objects: objects)
        }
    }

    func savePendingClusterChange(_ change: ClusterPendingChange) throws {
        try change.validate()
        try transaction {
            let payload = String(decoding: try JSONEncoder().encode(change), as: UTF8.self)
            try execute("INSERT OR IGNORE INTO cluster_pending_changes VALUES (?, CAST(? AS BLOB))", [change.id, payload])
            guard let stored = try rows("SELECT payload FROM cluster_pending_changes WHERE id = ?", [change.id]).first?.first ?? nil,
                  try JSONDecoder().decode(ClusterPendingChange.self, from: Data(stored.utf8)) == change else { throw LocalMusicError.invalidData }
        }
    }

    func pendingClusterChanges() throws -> [ClusterPendingChange] {
        try rows("SELECT payload FROM cluster_pending_changes ORDER BY rowid").map { row in
            guard let payload = row[0] else { throw LocalMusicError.invalidData }
            return try JSONDecoder().decode(ClusterPendingChange.self, from: Data(payload.utf8))
        }
    }

    func enqueueClusterJob(_ job: ClusterTransferJob) throws {
        guard UUID(uuidString: job.id) != nil, job.state == .queued, job.source != job.destination,
              ClusterIdentity.isLowercaseHex256(job.source), ClusterIdentity.isLowercaseHex256(job.destination) else { throw LocalMusicError.invalidData }
        try transaction {
            guard try rows("SELECT EXISTS(SELECT 1 FROM cluster_objects WHERE sha256 = ?)", [job.sha256]).first?.first == "1" else { throw LocalMusicError.invalidData }
            try execute("INSERT OR IGNORE INTO cluster_jobs VALUES (?, ?, ?, ?, 'queued')", [job.id, job.sha256, job.source, job.destination])
            guard let row = try rows("SELECT sha256, source, destination FROM cluster_jobs WHERE id = ?", [job.id]).first,
                  row == [job.sha256, job.source, job.destination] else { throw LocalMusicError.invalidData }
        }
    }

    func beginClusterJob(_ id: String) throws {
        try execute("UPDATE cluster_jobs SET state = 'running' WHERE id = ? AND state = 'queued'", [id])
        guard sqlite3_changes(connection) == 1 else { throw LocalMusicError.invalidData }
    }

    func recoverClusterJobs() throws {
        try execute("UPDATE cluster_jobs SET state = 'queued' WHERE state = 'running'")
    }

    func clusterJobs() throws -> [ClusterTransferJob] {
        try rows("SELECT id, sha256, source, destination, state FROM cluster_jobs ORDER BY rowid").map { row in
            guard let id = row[0], let hash = row[1], let source = row[2], let destination = row[3],
                  let state = row[4].flatMap(ClusterTransferJob.State.init(rawValue:)) else { throw LocalMusicError.invalidData }
            return ClusterTransferJob(id: id, sha256: hash, source: source, destination: destination, state: state)
        }
    }
}
