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
            guard let version, let number = Int(version), (0...10).contains(number) else { throw LocalMusicError.invalidData }
            if number == 10 {
                let required: Set<String> = ["device_transfer_settings", "verified_audio_files", "retained_host_catalog",
                    "host_connection", "host_entries", "host_playlists", "shared_audio_saves", "received_files"]
                let existing = Set(try rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0] })
                if required.isSubset(of: existing) { return }
            }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS verified_audio_files (path TEXT PRIMARY KEY, stamp TEXT NOT NULL, hash TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS received_files (relative_path TEXT PRIMARY KEY, sha256 TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS shared_audio_saves (track TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY(track, hash))")
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
                if try !rows("PRAGMA table_info(host_connection)").contains(where: { $0[1] == "refreshed_at" }) {
                    try execute("ALTER TABLE host_connection ADD COLUMN refreshed_at REAL")
                }
                for table in ["cluster_schema", "cluster_identity", "cluster_peers", "cluster_objects", "cluster_locations",
                              "cluster_pending_changes", "cluster_jobs", "cluster_registration", "cluster_signed_changes",
                              "cluster_peer_cursors", "cluster_track_ids", "cluster_import_batches", "cluster_metadata_queue",
                              "cluster_transfer_settings", "shared_audio_snapshot", "shared_audio_refresh_notice",
                              "playlist_records", "playlist_cursors", "playlist_authorities"] {
                    try execute("DROP TABLE IF EXISTS \(table)")
                }
                try purgeLegacyLocalLibrary()
                try execute("PRAGMA user_version = 10")
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
            guard try hostCatalogLibrary() != nil else { return nil }
            guard let payload = try rows("SELECT header FROM host_connection UNION ALL SELECT header FROM retained_host_catalog").first?.first ?? nil else { return nil }
            var catalog = try JSONDecoder().decode(LocalCatalog.self, from: Data(payload.utf8))
            catalog.source = .host
            catalog.entries = try rows("SELECT payload FROM host_entries ORDER BY position").map {
                try JSONDecoder().decode(LocalEntry.self, from: Data(($0[0] ?? "").utf8))
            }
            return CatalogSnapshot(catalog: catalog)
        }
    }

    func retainedHostLibrary() throws -> String? {
        try rows("SELECT library FROM retained_host_catalog").first?.first ?? nil
    }

    func retainedLibrary(at address: HostAddress) throws -> String? {
        try rows("SELECT library FROM retained_host_catalog WHERE address = ?", [address.origin.absoluteString]).first?.first ?? nil
    }

    /// Removes the library that the retired folder and import modes kept on this device.
    /// Audio stays when a host entry or a saved-audio pin shares its content.
    /// Files go before rows, so an interrupted run finds the same rows on the next launch.
    private func purgeLegacyLocalLibrary() throws {
        let manager = FileManager.default
        for name in ["active", "folder.bookmark", "catalog.json"] {
            let url = root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        let tables = Set(try rows("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0[0] })
        if tables.contains("entries") {
            var kept = Set(try rows("SELECT hash FROM shared_audio_saves").compactMap { $0[0] })
            for row in try rows("SELECT payload FROM host_entries") {
                kept.insert(try JSONDecoder().decode(LocalEntry.self, from: Data((row[0] ?? "").utf8)).sha256)
            }
            let store = LocalMusicStore(root: root)
            for row in try rows("SELECT payload FROM entries") {
                let entry = try JSONDecoder().decode(LocalEntry.self, from: Data((row[0] ?? "").utf8))
                guard LocalMusicStore.valid(entry), !kept.contains(entry.sha256) else { continue }
                for url in store.hostFileURLs(entry) where manager.fileExists(atPath: url.path) {
                    try manager.removeItem(at: url)
                }
                try execute("DELETE FROM received_files WHERE sha256 = ?", [entry.sha256])
                try execute("DELETE FROM verified_audio_files WHERE hash = ?", [entry.sha256])
            }
        }
        for table in ["catalog", "entries", "organization", "artwork_assets"] {
            try execute("DROP TABLE IF EXISTS \(table)")
        }
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

    func hostRefreshedAt() throws -> Date? {
        guard let value = try rows("SELECT refreshed_at FROM host_connection").first?.first ?? nil else { return nil }
        return Double(value).map(Date.init(timeIntervalSince1970:))
    }

    func markHostRefreshed(_ host: HostConnection, at date: Date) throws {
        try transaction {
            guard try hostConnection() == host else { throw CancellationError() }
            try execute("UPDATE host_connection SET refreshed_at = ?", [String(date.timeIntervalSince1970)])
        }
    }

    func forgetHost() throws -> String? {
        try transaction {
            try execute("INSERT OR REPLACE INTO retained_host_catalog(library,header,address) SELECT library,header,address FROM host_connection WHERE header IS NOT NULL")
            try execute("DELETE FROM host_connection")
            return try retainedHostLibrary()
        }
    }

    func saveHostCatalog(_ update: CatalogUpdate, connection: HostConnection, replacing previous: HostConnection?, refreshedAt: Date = .now) throws {
        try transaction {
            guard try hostConnection() == previous, update.catalog.id == connection.library else { throw CancellationError() }
            let hosts = String(decoding: try JSONEncoder().encode(connection.hosts), as: UTF8.self)
            var header = update.catalog
            header.entries = []
            try execute("DELETE FROM retained_host_catalog")
            try execute("INSERT OR REPLACE INTO host_connection(singleton,address,library,name,hosts,etag,marker,header,host_switch,refreshed_at) VALUES(1,?,?,?,?,?,?,?,?,?)",
                        [connection.address.origin.absoluteString, connection.library, header.name, hosts, update.etag, update.marker,
                         String(decoding: try JSONEncoder().encode(header), as: UTF8.self), update.hostSwitch, String(refreshedAt.timeIntervalSince1970)])
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
        try rows("SELECT CASE WHEN EXISTS(SELECT 1 FROM host_connection) THEN EXISTS(SELECT 1 FROM host_connection WHERE header IS NOT NULL) ELSE EXISTS(SELECT 1 FROM retained_host_catalog) END").first?.first == "1"
    }

    func playbackEntry(_ id: String, hash: String? = nil) throws -> (library: String, entry: LocalEntry)? {
        if let library = try hostCatalogLibrary() {
            guard let payload = try rows("SELECT payload FROM host_entries WHERE id = ?", [id]).first?.first ?? nil else { return nil }
            let entry = try JSONDecoder().decode(LocalEntry.self, from: Data(payload.utf8))
            guard hash == nil || entry.sha256 == hash else { return nil }
            return (library, entry)
        }
        return nil
    }


    func recordReceived(_ entry: LocalEntry) throws {
        try execute("INSERT OR REPLACE INTO received_files VALUES (?, ?)",
            [entry.sha256 + "." + (entry.track.suffix ?? "audio"), entry.sha256])
    }

    func forgetReceived(_ entry: LocalEntry) throws {
        try execute("DELETE FROM received_files WHERE relative_path = ? AND sha256 = ?",
            [entry.sha256 + "." + (entry.track.suffix ?? "audio"), entry.sha256])
    }

}
