import Foundation
import SQLite3

extension CatalogDatabase {
    func savedAudioPins() throws -> Set<String> {
        Set(try rows("SELECT track, hash FROM shared_audio_saves").compactMap { row in
            guard let track = row[0], let hash = row[1] else { return nil }
            return track + ":" + hash
        })
    }

    func matchesVerifiedAudio(_ url: URL, stamp: String, hash: String) -> Bool {
        (try? rows("SELECT 1 FROM verified_audio_files WHERE path = ? AND stamp = ? AND hash = ?",
                   [url.lastPathComponent, stamp, hash]).isEmpty) == false
    }

    func recordVerifiedAudio(_ url: URL, stamp: String, hash: String) {
        try? execute("INSERT OR REPLACE INTO verified_audio_files VALUES (?, ?, ?)", [url.lastPathComponent, stamp, hash])
    }

    func saveAudioPin(_ entry: LocalEntry) throws {
        try execute("INSERT OR REPLACE INTO shared_audio_saves VALUES (?, ?)", [entry.track.id, entry.sha256])
    }

    func hasAudioPin(_ entry: LocalEntry) throws -> Bool {
        try !rows("SELECT track FROM shared_audio_saves WHERE track = ? AND hash = ?", [entry.track.id, entry.sha256]).isEmpty
    }

    func removeAudioPin(_ entry: LocalEntry) throws -> Bool {
        try transaction {
            try execute("DELETE FROM shared_audio_saves WHERE track = ? AND hash = ?", [entry.track.id, entry.sha256])
            return try !rows("SELECT track FROM shared_audio_saves WHERE hash = ?", [entry.sha256]).isEmpty
        }
    }

}

struct CatalogSnapshot {
    var catalog: LocalCatalog
    var sourceRoot: URL?
    var sourcePaths: [String: String]
}

extension CatalogDatabase {
    func playlistDocuments() throws -> (documents: [PlaylistDocument], conflicts: Set<String>) {
        if try hostCatalogLibrary() != nil {
            var documents: [PlaylistDocument] = []
            var conflicts = Set<String>()
            for row in try rows("SELECT id, payload, conflicted FROM host_playlists ORDER BY position") {
                if let payload = row[1] { documents.append(try JSONDecoder().decode(PlaylistDocument.self, from: Data(payload.utf8))) }
                if row[2] == "1", let id = row[0] { conflicts.insert(id) }
            }
            return (documents, conflicts)
        }
        return ([], [])
    }
}

extension CatalogDatabase {
    func automaticCellular() throws -> Bool {
        try rows("SELECT cellular FROM device_transfer_settings WHERE singleton = 1").first?.first == "1"
    }

    func setAutomaticCellular(_ enabled: Bool) throws {
        try execute("INSERT OR REPLACE INTO device_transfer_settings VALUES (1, ?)", [enabled ? "1" : "0"])
    }
}
/// Catalog replacement commits as one transaction.
final class CatalogDatabase {
    private var connection: OpaquePointer?
    private var operation = "open"
    private let root: URL

    init(_ url: URL) throws {
        root = url.deletingLastPathComponent()
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(connection)
            connection = nil
            throw error
        }
        sqlite3_busy_timeout(connection, 5000)
        do {
            let version = try rows("PRAGMA user_version").first?.first ?? nil
            guard let version, let number = Int(version), (0...8).contains(number) else { throw LocalMusicError.invalidData }
            if number == 8 {
                let required: Set<String> = ["device_transfer_settings", "verified_audio_files", "retained_host_catalog",
                    "host_connection", "host_entries", "host_playlists", "shared_audio_saves", "catalog", "entries",
                    "received_files", "organization", "artwork_assets"]
                let existing = Set(try rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0] })
                if required.isSubset(of: existing) { return }
            }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS catalog (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL, name TEXT NOT NULL, source_root TEXT)")
                try execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, position INTEGER NOT NULL, sha256 TEXT NOT NULL, payload TEXT NOT NULL, source_path TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS entries_content ON entries(sha256)")
                try execute("CREATE TABLE IF NOT EXISTS verified_audio_files (path TEXT PRIMARY KEY, stamp TEXT NOT NULL, hash TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS received_files (relative_path TEXT PRIMARY KEY, sha256 TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS organization (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), payload TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS artwork_assets (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS shared_audio_saves (track TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY(track, hash))")
                if number < 4 { _ = try readSnapshot() }
                try execute("CREATE TABLE IF NOT EXISTS device_transfer_settings (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), cellular INTEGER NOT NULL CHECK(cellular IN (0, 1)))")
                if try !rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cluster_transfer_settings'").isEmpty {
                    try execute("INSERT OR IGNORE INTO device_transfer_settings(singleton, cellular) SELECT singleton, cellular FROM cluster_transfer_settings")
                }
                try execute("CREATE TABLE IF NOT EXISTS host_connection (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), address TEXT NOT NULL, library TEXT NOT NULL, name TEXT NOT NULL, hosts TEXT NOT NULL, etag TEXT, marker TEXT, header TEXT)")
                try execute("CREATE TABLE IF NOT EXISTS host_entries (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS host_playlists (id TEXT PRIMARY KEY, position INTEGER, payload TEXT, conflicted INTEGER NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS retained_host_catalog (library TEXT PRIMARY KEY, header TEXT NOT NULL)")
                if try !rows("PRAGMA table_info(host_connection)").contains(where: { $0[1] == "host_switch" }) {
                    try execute("ALTER TABLE host_connection ADD COLUMN host_switch TEXT")
                    let store = LocalMusicStore(root: root)
                    for row in try rows("SELECT payload FROM host_entries") {
                        let entry = try JSONDecoder().decode(LocalEntry.self, from: Data((row[0] ?? "").utf8))
                        if store.hasFile(entry) { try saveAudioPin(entry) }
                    }
                }
                if try !rows("PRAGMA table_info(retained_host_catalog)").contains(where: { $0[1] == "address" }) {
                    try execute("ALTER TABLE retained_host_catalog ADD COLUMN address TEXT")
                }
                for table in ["cluster_schema", "cluster_identity", "cluster_peers", "cluster_objects", "cluster_locations",
                              "cluster_pending_changes", "cluster_jobs", "cluster_registration", "cluster_signed_changes",
                              "cluster_peer_cursors", "cluster_track_ids", "cluster_import_batches", "cluster_metadata_queue",
                              "cluster_transfer_settings", "shared_audio_snapshot", "shared_audio_refresh_notice",
                              "playlist_records", "playlist_cursors", "playlist_authorities"] {
                    try execute("DROP TABLE IF EXISTS \(table)")
                }
                try execute("PRAGMA user_version = 8")
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
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection)),
                       "database_operation": operation])
    }

    private func statement(_ sql: String, _ values: [String?]) throws -> OpaquePointer {
        let verb = sql.split(separator: " ").first.map(String.init) ?? ""
        operation = ["BEGIN", "COMMIT", "ROLLBACK", "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "PRAGMA"].contains(verb) ? verb : "other"
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

    func transaction<T>(_ action: () throws -> T) throws -> T {
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
        try transaction {
            guard try hostCatalogLibrary() != nil else { return try readSnapshot() }
            guard let payload = try rows("SELECT header FROM host_connection UNION ALL SELECT header FROM retained_host_catalog").first?.first ?? nil else { return nil }
            var catalog = try JSONDecoder().decode(LocalCatalog.self, from: Data(payload.utf8))
            catalog.source = .host
            catalog.entries = try rows("SELECT payload FROM host_entries ORDER BY position").map {
                try JSONDecoder().decode(LocalEntry.self, from: Data(($0[0] ?? "").utf8))
            }
            return CatalogSnapshot(catalog: catalog, sourceRoot: nil, sourcePaths: [:])
        }
    }

    func retainedHostLibrary() throws -> String? {
        try rows("SELECT library FROM retained_host_catalog").first?.first ?? nil
    }

    func retainedLibrary(at address: HostAddress) throws -> String? {
        try rows("SELECT library FROM retained_host_catalog WHERE address = ?", [address.origin.absoluteString]).first?.first ?? nil
    }

    func otherCatalogFiles(for hash: String) throws -> Set<URL> {
        let store = LocalMusicStore(root: root)
        return Set(try rows("SELECT payload FROM entries WHERE sha256 = ?", [hash]).map { row in
            let entry = try JSONDecoder().decode(LocalEntry.self, from: Data((row[0] ?? "").utf8))
            return store.fileURL(entry)
        })
    }

    private func hostCatalogLibrary() throws -> String? {
        try rows("SELECT library FROM host_connection UNION ALL SELECT library FROM retained_host_catalog").first?.first ?? nil
    }

    func updateHosts(_ hosts: [HostLibraryInfo.Host], for host: HostConnection) throws {
        try transaction {
            guard try hostConnection() == host else { throw CancellationError() }
            try execute("UPDATE host_connection SET hosts = ?", [String(decoding: try JSONEncoder().encode(hosts), as: UTF8.self)])
        }
    }

    func hostConnection() throws -> HostConnection? {
        guard let row = try rows("SELECT address, library, name, hosts, etag, marker, host_switch FROM host_connection").first else { return nil }
        guard let address = row[0], let library = row[1], let name = row[2], let hosts = row[3] else { throw LocalMusicError.invalidData }
        return try HostConnection(address: HostAddress(address), library: library, name: name,
                                  hosts: JSONDecoder().decode([HostLibraryInfo.Host].self, from: Data(hosts.utf8)), etag: row[4], marker: row[5], hostSwitch: row[6])
    }

    func forgetHost() throws -> String? {
        try transaction {
            try execute("INSERT OR REPLACE INTO retained_host_catalog(library,header,address) SELECT library,header,address FROM host_connection WHERE header IS NOT NULL")
            try execute("DELETE FROM host_connection")
            return try retainedHostLibrary()
        }
    }

    func saveHostCatalog(_ update: CatalogUpdate, connection: HostConnection, replacing previous: HostConnection?) throws {
        try transaction {
            guard try hostConnection() == previous, update.catalog.id == connection.library else { throw CancellationError() }
            let hosts = String(decoding: try JSONEncoder().encode(connection.hosts), as: UTF8.self)
            var header = update.catalog
            header.entries = []
            try execute("DELETE FROM retained_host_catalog")
            try execute("INSERT OR REPLACE INTO host_connection(singleton,address,library,name,hosts,etag,marker,header,host_switch) VALUES(1,?,?,?,?,?,?,?,?)",
                        [connection.address.origin.absoluteString, connection.library, header.name, hosts, update.etag, update.marker,
                         String(decoding: try JSONEncoder().encode(header), as: UTF8.self), update.hostSwitch])
            try execute("DELETE FROM host_entries")
            for (index, entry) in update.catalog.entries.enumerated() {
                try Task.checkCancellation()
                try execute("INSERT INTO host_entries VALUES(?,?,?)", [entry.track.id, String(index), String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)])
            }
            try execute("DELETE FROM host_playlists")
            for (index, playlist) in update.playlists.enumerated() {
                try execute("INSERT INTO host_playlists VALUES(?,?,?,0)", [playlist.id, String(index), String(decoding: try JSONEncoder().encode(playlist), as: UTF8.self)])
            }
            for id in update.conflicts {
                try execute("INSERT INTO host_playlists(id,conflicted) VALUES(?,1) ON CONFLICT(id) DO UPDATE SET conflicted=1", [id])
            }
            try Task.checkCancellation()
        }
    }

    func containsCatalog() throws -> Bool {
        try rows("SELECT CASE WHEN EXISTS(SELECT 1 FROM host_connection) THEN EXISTS(SELECT 1 FROM host_connection WHERE header IS NOT NULL) ELSE EXISTS(SELECT 1 FROM retained_host_catalog) OR EXISTS(SELECT 1 FROM catalog) END").first?.first == "1"
    }

    func playbackEntry(_ id: String, hash: String? = nil) throws -> (library: String, entry: LocalEntry)? {
        if let library = try hostCatalogLibrary() {
            guard let payload = try rows("SELECT payload FROM host_entries WHERE id = ?", [id]).first?.first ?? nil else { return nil }
            let entry = try JSONDecoder().decode(LocalEntry.self, from: Data(payload.utf8))
            guard hash == nil || entry.sha256 == hash else { return nil }
            return (library, entry)
        }
        guard let row = try rows("SELECT catalog.id, entries.payload FROM catalog JOIN entries ON entries.id = ? WHERE catalog.singleton = 1", [id]).first,
              let library = row[0], let payload = row[1] else { return nil }
        let entry = try JSONDecoder().decode(LocalEntry.self, from: Data(payload.utf8))
        guard entry.track.id == id, LocalMusicStore.valid(entry) else { throw LocalMusicError.invalidData }
        return (library, entry)
    }


    func localSnapshot() throws -> CatalogSnapshot? { try transaction { try readSnapshot() } }

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
            try writeOrganization(organized.organization!)
            if sourceRoot != nil {
                guard try hostConnection() == nil else { throw CancellationError() }
                try execute("DELETE FROM retained_host_catalog")
                try execute("DELETE FROM host_entries")
                try execute("DELETE FROM host_playlists")
            }
            try execute("DELETE FROM entries")
            try execute("INSERT OR REPLACE INTO catalog VALUES (1, ?, ?, ?)", [catalog.id, catalog.name, root?.path])
            for (position, entry) in catalog.entries.enumerated() {
                let payload = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
                try execute("INSERT INTO entries VALUES (?, ?, ?, ?, ?)",
                    [entry.track.id, String(position), entry.sha256, payload, paths[entry.track.id]])
            }
            for entry in received { try recordReceived(entry) }
        }
    }

    func setAlbumHidden(_ id: String, hidden: Bool, libraryID: String) throws -> AlbumOrganization {
        try setAlbumsHidden([id], hidden: hidden, libraryID: libraryID)
    }

    func setAlbumsHidden(_ ids: Set<String>, hidden: Bool, libraryID: String) throws -> AlbumOrganization {
        try transaction {
            guard try hostCatalogLibrary() == nil else { throw LocalMusicError.readOnlyCatalog }
            guard let catalog = try readSnapshot()?.catalog, catalog.id == libraryID,
                  var organization = catalog.organization else { throw LocalMusicError.invalidData }
            for id in ids.sorted() {
                organization.set(subject: id, kind: "visibility", value: hidden ? "true" : "false")
            }
            try writeOrganization(organization)
            return organization
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
