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
            guard version == "0" || version == "1" else { throw LocalMusicError.invalidData }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS catalog (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), id TEXT NOT NULL, name TEXT NOT NULL, source_root TEXT)")
                try execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, position INTEGER NOT NULL, sha256 TEXT NOT NULL, payload TEXT NOT NULL, source_path TEXT)")
                try execute("CREATE INDEX IF NOT EXISTS entries_content ON entries(sha256)")
                try execute("CREATE TABLE IF NOT EXISTS received_files (relative_path TEXT PRIMARY KEY, sha256 TEXT NOT NULL)")
                try execute("PRAGMA user_version = 1")
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
        return CatalogSnapshot(catalog: LocalCatalog(id: id, name: name, entries: entries),
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

    func recordReceived(_ entry: LocalEntry) throws {
        try execute("INSERT OR REPLACE INTO received_files VALUES (?, ?)",
            [entry.sha256 + "." + (entry.track.suffix ?? "audio"), entry.sha256])
    }
}
