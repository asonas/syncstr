import Foundation
import SQLite3
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

final class CatalogMigrationTests: XCTestCase {
    func testDeviceCellularSettingMigratesOnceAndDefaultsOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        XCTAssertFalse(try store.database().automaticCellular())
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let legacy = "PRAGMA user_version = 7; DROP TABLE device_transfer_settings; CREATE TABLE cluster_transfer_settings(singleton INTEGER PRIMARY KEY, cellular INTEGER); INSERT INTO cluster_transfer_settings VALUES (1, 1)"
        XCTAssertEqual(sqlite3_exec(connection, legacy, nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try store.database().automaticCellular())
        try store.database().setAutomaticCellular(false)
        XCTAssertFalse(try store.database().automaticCellular())
    }

    @MainActor
    func testCellularPreferenceRestoresWithoutAHost() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalMusicStore(root: root)
        let transfer = LocalTransfer(store: files, pathMonitor: nil)
        XCTAssertFalse(transfer.automaticCellular)
        transfer.setAutomaticCellular(true)
        let restored = LocalTransfer(store: files, pathMonitor: nil)
        await restored.restoreHost()
        XCTAssertTrue(restored.automaticCellular)
        restored.setAutomaticCellular(false)
        XCTAssertFalse(try files.database().automaticCellular())
    }

    func testVersionSevenPreservesConnectedAndRetainedHostData() throws {
        for retained in [false, true] {
            let (store, catalog) = try storeWithAudio()
            let db = try store.database()
            let entry = catalog.entries[0]
            let host = HostConnection(address: try HostAddress("https://host.example.test"),
                                      library: catalog.id, name: catalog.name, hosts: [])
            try db.saveHostCatalog(CatalogUpdate(catalog: catalog), connection: host, replacing: nil)
            if retained { _ = try db.forgetHost() }
            try db.saveAudioPin(entry)
            let file = store.fileURL(entry)
            db.recordVerifiedAudio(file, stamp: "stamp", hash: entry.sha256)
            var connection: OpaquePointer?
            XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &connection), SQLITE_OK)
            defer { sqlite3_close(connection) }
            let removed = ["cluster_schema", "cluster_identity", "cluster_peers", "cluster_objects", "cluster_locations",
                           "cluster_pending_changes", "cluster_jobs", "cluster_registration", "cluster_signed_changes",
                           "cluster_peer_cursors", "cluster_track_ids", "cluster_import_batches", "cluster_metadata_queue",
                           "shared_audio_snapshot", "shared_audio_refresh_notice", "playlist_records", "playlist_cursors", "playlist_authorities"]
            for table in removed {
                XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE \(table)(payload TEXT)", nil, nil, nil), SQLITE_OK)
            }
            let oldSettings = """
                DROP TABLE device_transfer_settings;
                CREATE TABLE cluster_transfer_settings(singleton INTEGER PRIMARY KEY, cellular INTEGER);
                INSERT INTO cluster_transfer_settings VALUES(1, 1);
                PRAGMA user_version = 7;
                """
            XCTAssertEqual(sqlite3_exec(connection, oldSettings, nil, nil, nil), SQLITE_OK)
            let migrated = try store.database()
            XCTAssertEqual(try migrated.hostConnection(), retained ? nil : host)
            XCTAssertEqual(try migrated.retainedLibrary(at: host.address), retained ? catalog.id : nil)
            XCTAssertEqual(try migrated.snapshot()?.catalog.source, .host)
            XCTAssertEqual(try migrated.snapshot()?.catalog.entries, catalog.entries)
            XCTAssertTrue(try migrated.hasAudioPin(entry))
            XCTAssertTrue(migrated.matchesVerifiedAudio(file, stamp: "stamp", hash: entry.sha256))
            XCTAssertTrue(try migrated.automaticCellular())
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 10)
            sqlite3_finalize(statement)
            XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil), SQLITE_OK)
            var tables = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                tables.insert(String(cString: sqlite3_column_text(statement, 0)))
            }
            sqlite3_finalize(statement)
            XCTAssertTrue(tables.isDisjoint(with: removed + ["cluster_transfer_settings"]))
        }
    }

    func testLegacyLocalLibraryIsPurgedWithoutTouchingHostAudioOrFailingOnBrokenRows() throws {
        let (store, catalog) = try storeWithAudio()
        let shared = catalog.entries[0]
        let localOnly = LocalEntry(track: Track(id: "local-only", title: "Imported", artist: "Artist", suffix: "mp3", size: 3),
            sha256: String(repeating: "c", count: 64))
        try Data("xyz".utf8).write(to: store.fileURL(localOnly))
        let db = try store.database()
        let host = HostConnection(address: try HostAddress("https://host.example.test"),
                                  library: catalog.id, name: catalog.name, hosts: [])
        try db.saveHostCatalog(CatalogUpdate(catalog: catalog), connection: host, replacing: nil)
        try db.recordReceived(localOnly)
        for name in ["active", "folder.bookmark", "catalog.json"] {
            try Data().write(to: store.root.appendingPathComponent(name))
        }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let payload = { (entry: LocalEntry) in String(decoding: try JSONEncoder().encode(entry), as: UTF8.self).replacingOccurrences(of: "'", with: "''") }
        let legacy = """
            CREATE TABLE catalog (singleton INTEGER PRIMARY KEY, id TEXT NOT NULL, name TEXT NOT NULL, source_root TEXT);
            CREATE TABLE entries (id TEXT PRIMARY KEY, position INTEGER NOT NULL, sha256 TEXT NOT NULL, payload TEXT NOT NULL, source_path TEXT);
            CREATE TABLE organization (singleton INTEGER PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE artwork_assets (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            INSERT INTO catalog VALUES (1, 'local-library', 'Folder', 'Music');
            INSERT INTO entries VALUES ('shared', 0, '\(shared.sha256)', '\(try payload(shared))', 'a.wav');
            INSERT INTO entries VALUES ('local-only', 1, '\(localOnly.sha256)', '\(try payload(localOnly))', 'b.mp3');
            INSERT INTO entries VALUES ('broken', 2, 'not-a-hash', '{', NULL);
            PRAGMA user_version = 9;
            """
        XCTAssertEqual(sqlite3_exec(connection, legacy, nil, nil, nil), SQLITE_OK)

        for _ in 0..<2 {
            let migrated = try store.database()
            XCTAssertEqual(try migrated.hostConnection(), host)
            XCTAssertEqual(try migrated.snapshot()?.catalog.entries, catalog.entries)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(shared).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(localOnly).path))
        for name in ["active", "folder.bookmark", "catalog.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(name).path))
        }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil), SQLITE_OK)
        var tables = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { tables.insert(String(cString: sqlite3_column_text(statement, 0))) }
        sqlite3_finalize(statement)
        XCTAssertTrue(tables.isDisjoint(with: ["catalog", "entries", "organization", "artwork_assets"]))
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT count(*) FROM received_files WHERE sha256 = '\(localOnly.sha256)'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
    }

    func testPinBackfillSkipsAnUnreadableHostEntry() throws {
        let (store, catalog) = try storeWithAudio()
        let entry = catalog.entries[0]
        let host = HostConnection(address: try HostAddress("https://host.example.test"),
                                  library: catalog.id, name: catalog.name, hosts: [])
        try store.database().saveHostCatalog(CatalogUpdate(catalog: catalog), connection: host, replacing: nil)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        // A database from before host_switch, holding one host entry that no longer decodes.
        let legacy = """
            ALTER TABLE host_connection DROP COLUMN host_switch;
            INSERT INTO host_entries VALUES ('broken', 1, '{');
            PRAGMA user_version = 7;
            """
        XCTAssertEqual(sqlite3_exec(connection, legacy, nil, nil, nil), SQLITE_OK)

        let migrated = try store.database()
        XCTAssertTrue(try migrated.hasAudioPin(entry))
        XCTAssertEqual(try migrated.hostConnection()?.library, catalog.id)
    }

    func testVersionSevenWithOnlyASharedSnapshotOpensWithoutALibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalMusicStore(root: root)
        try files.prepare()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db), SQLITE_OK)
        let schema = """
            CREATE TABLE shared_audio_snapshot(singleton INTEGER PRIMARY KEY, payload TEXT NOT NULL);
            INSERT INTO shared_audio_snapshot VALUES (1, '{}');
            PRAGMA user_version = 7;
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertNil(try files.snapshot())
        XCTAssertFalse(files.hasCatalog)
    }

    func testStoredHostHeaderWithoutSourceRestoresAsHostCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        let database = try store.database()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let legacy = """
            INSERT INTO host_connection(singleton,address,library,name,hosts,header)
            VALUES(1,'https://host.example.test','library','Fixture','[]',
                   '{"id":"library","name":"Fixture","entries":[],"remoteArtwork":[]}')
            """
        XCTAssertEqual(sqlite3_exec(connection, legacy, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try store.load()?.source, .host)
        _ = try database.forgetHost()
        XCTAssertEqual(try store.load()?.source, .host)
    }

    func testCatalogReadRetainsUnchangedArtworkFileAndRepairsMissingCopy() throws {
        let (store, catalog) = try storeWithAudio()
        try saveHostFixture(catalog.entries, in: store)
        _ = try store.load()
        let image = store.artworkURL(catalog.entries[0])
        let originalDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: image.path)
        _ = try store.load()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: image.path)[.modificationDate] as? Date, originalDate)
        try FileManager.default.removeItem(at: image)
        XCTAssertEqual(try store.load()?.entries, catalog.entries)
        XCTAssertEqual(try Data(contentsOf: image), Data([1, 2, 3]))
    }

    func testCurrentSchemaMetadataAccessDoesNotDecodeEntriesButSnapshotStillValidates() throws {
        let (store, catalog) = try storeWithAudio()
        try saveHostFixture(catalog.entries, in: store)
        _ = try store.load()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE host_entries SET payload = 'invalid JSON'", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(try store.database().containsCatalog())
        XCTAssertThrowsError(try store.load())
    }

    func testHeadlessEntryJSONContractRoundTripsInNativeModel() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "local-entry", withExtension: "json"))
        let data = try Data(contentsOf: fixture)
        let entry = try JSONDecoder().decode(LocalEntry.self, from: data)
        XCTAssertEqual(entry.track.id, "fixture-track")
        XCTAssertEqual(entry.track.title, "夜の音楽")
        XCTAssertEqual(entry.track.albumId, "fixture-album")
        XCTAssertEqual(entry.track.duration, 1.25)
        XCTAssertEqual(entry.track.discNumber, 1)
        XCTAssertEqual(entry.artwork, Data([1, 2, 3]))
        XCTAssertTrue(LocalMusicStore.valid(entry))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let encoded = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary, original)
    }

    private func storeWithAudio() throws -> (LocalMusicStore, LocalCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        try store.prepare()
        let entry = LocalEntry(track: Track(id: "legacy-track", title: "Original", artist: "Artist", coverArt: "legacy-track", suffix: "wav", size: 3),
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", artwork: Data([1, 2, 3]))
        let catalog = LocalCatalog(id: "legacy-library", name: "Music", entries: [entry])
        try Data("abc".utf8).write(to: store.fileURL(entry))
        return (store, catalog)
    }

}
