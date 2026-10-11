import Foundation
import SQLite3

struct CatalogSnapshot {
    var catalog: LocalCatalog
    var sourceRoot: URL?
    var sourcePaths: [String: String]
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
            guard ["0", "1", "2", "3"].contains(version) else { throw LocalMusicError.invalidData }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS catalog (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL, name TEXT NOT NULL, source_root TEXT)")
                try execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, position INTEGER NOT NULL, sha256 TEXT NOT NULL, payload TEXT NOT NULL, source_path TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS entries_content ON entries(sha256)")
                try execute("CREATE TABLE IF NOT EXISTS received_files (relative_path TEXT PRIMARY KEY, sha256 TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS organization (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), payload TEXT NOT NULL)")
                _ = try readSnapshot()
                try migrateCluster()
                try execute("PRAGMA user_version = 3")
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
            guard let trackID = row[0], let payload = row[1] else { throw LocalMusicError.invalidData }
            let entry = try JSONDecoder().decode(LocalEntry.self, from: Data(payload.utf8))
            guard LocalMusicStore.valid(entry), entry.track.id == trackID else { throw LocalMusicError.invalidData }
            entries.append(entry)
            paths[trackID] = row[2]
        }
        var catalog = LocalCatalog(id: id, name: name, entries: entries)
        if let payload = try rows("SELECT payload FROM organization WHERE singleton = 1").first?.first ?? nil {
            catalog.organization = try JSONDecoder().decode(AlbumOrganization.self, from: Data(payload.utf8))
            try catalog.organization?.validate()
        }
        let previous = catalog.organization
        catalog.organize(folders: header[2] == nil ? [:] : paths.mapValues { ($0 as NSString).deletingLastPathComponent })
        try catalog.organization?.validate()
        if previous != catalog.organization {
            try execute("INSERT OR REPLACE INTO organization VALUES (1, ?)",
                [String(decoding: try JSONEncoder().encode(catalog.organization!), as: UTF8.self)])
        }
        return CatalogSnapshot(catalog: catalog,
            sourceRoot: header[2].map { URL(fileURLWithPath: $0, isDirectory: true) }, sourcePaths: paths)
    }

    func save(_ catalog: LocalCatalog, sourceRoot: URL? = nil, sourcePaths: [String: String]? = nil,
              received: [LocalEntry] = []) throws {
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
            let organization = String(decoding: try JSONEncoder().encode(organized.organization!), as: UTF8.self)
            try execute("INSERT OR REPLACE INTO organization VALUES (1, ?)", [organization])
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
