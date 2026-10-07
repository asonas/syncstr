import Foundation
import SQLite3
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

final class CatalogMigrationTests: XCTestCase {
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
