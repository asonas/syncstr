import Foundation
import SQLite3
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

final class CatalogMigrationTests: XCTestCase {
    func testSchemaTwoRepairIsTransactionalAndRepeatable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        let entries = ["one", "two"].map { id in
            LocalEntry(track: Track(id: id, title: id, artist: id, album: "Collection", suffix: "mp3", size: 3),
                sha256: String(repeating: id == "one" ? "a" : "b", count: 64), artwork: nil,
                importedAlbum: ImportedAlbumMetadata(title: "Collection", artist: id, compilationValues: ["1"]))
        }
        try store.save(LocalCatalog(id: "source", name: "Collection", entries: entries))
        let original = try XCTUnwrap(store.load()?.organization)
        XCTAssertEqual(original.albums.count, 2)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE catalog SET source_root = 'unavailable-source'; UPDATE entries SET source_path = 'Collection/' || id || '.mp3'; PRAGMA user_version = 2; CREATE TRIGGER reject_repair BEFORE UPDATE ON organization BEGIN SELECT RAISE(ABORT, 'fixture failure'); END; CREATE TRIGGER reject_insert BEFORE INSERT ON organization BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.load())
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT payload FROM organization", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let payload = String(cString: sqlite3_column_text(statement, 0))
        sqlite3_finalize(statement)
        XCTAssertEqual(try JSONDecoder().decode(AlbumOrganization.self, from: Data(payload.utf8)), original)
        XCTAssertEqual(sqlite3_exec(connection, "DROP TRIGGER reject_repair; DROP TRIGGER reject_insert;", nil, nil, nil), SQLITE_OK)
        let repaired = try XCTUnwrap(store.load()?.organization)
        XCTAssertEqual(repaired.albumID(for: "one"), repaired.albumID(for: "two"))
        XCTAssertEqual(repaired.tracks.map(\.id), original.tracks.map(\.id))
        XCTAssertEqual(try store.load()?.organization, repaired)
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

    private func legacyStore() throws -> (LocalMusicStore, LocalCatalog) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        try store.prepare()
        let entry = LocalEntry(track: Track(id: "legacy-track", title: "Original", artist: "Artist", coverArt: "legacy-track", suffix: "wav", size: 3),
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", artwork: Data([1, 2, 3]))
        let catalog = LocalCatalog(id: "legacy-library", name: "Music", entries: [entry])
        try Data("abc".utf8).write(to: store.fileURL(entry))
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("catalog.json"))
        try Data("bookmark fixture".utf8).write(to: root.appendingPathComponent("folder.bookmark"))
        try Data().write(to: root.appendingPathComponent("active"))
        return (store, catalog)
    }

    func testMigrationRetainsIDsAudioArtworkAndIgnoresLegacyAfterCommit() throws {
        let (store, catalog) = try legacyStore()
        let legacy = store.root.appendingPathComponent("catalog.json")
        let original = try Data(contentsOf: legacy)
        let migrated = try XCTUnwrap(store.load())
        XCTAssertEqual(migrated.id, catalog.id)
        XCTAssertEqual(migrated.entries, catalog.entries)
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertEqual(try Data(contentsOf: store.artworkURL(catalog.entries[0])), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("folder.bookmark")), Data("bookmark fixture".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("active").path))
        var updated = catalog
        updated.name = "Renamed library"
        try store.save(updated)
        try Data("invalid legacy JSON".utf8).write(to: legacy)
        let reopened = LocalMusicStore(root: store.root)
        XCTAssertEqual(try reopened.load()?.name, "Renamed library")
        XCTAssertEqual(try Data(contentsOf: reopened.fileURL(catalog.entries[0])), Data("abc".utf8))
        XCTAssertTrue(reopened.hasFile(catalog.entries[0]))
    }

    func testFailedMigrationCanRetryWithoutLosingLegacyFiles() throws {
        let (store, catalog) = try legacyStore()
        var invalid = catalog
        invalid.entries.append(catalog.entries[0])
        let legacy = store.root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(invalid).write(to: legacy)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try JSONDecoder().decode(LocalCatalog.self, from: Data(contentsOf: legacy)).entries.count, 2)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(catalog.entries[0])), Data("abc".utf8))
        try JSONEncoder().encode(catalog).write(to: legacy)
        XCTAssertEqual(try store.load()?.entries, catalog.entries)
    }

    func testFailedReplacementRollsBackAndCorruptDatabaseDoesNotRestoreStaleJSON() throws {
        let (store, catalog) = try legacyStore()
        _ = try store.load()
        let url = store.root.appendingPathComponent("catalog.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TRIGGER reject_entry BEFORE INSERT ON entries BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)
        var updated = catalog
        updated.name = "Must not commit"
        XCTAssertThrowsError(try store.save(updated))
        XCTAssertEqual(try store.load()?.name, catalog.name)
        XCTAssertEqual(try store.load()?.entries, catalog.entries)
        try Data("broken database".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try LocalMusicStore(root: store.root).load())
        XCTAssertTrue(store.hasFile(catalog.entries[0]))
    }
}
