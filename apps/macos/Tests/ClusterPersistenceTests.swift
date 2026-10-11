import Foundation
import SQLite3
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

final class ClusterPersistenceTests: XCTestCase {
    func testRustFixtureRoundTripsWithoutChangingClusterIdentityOrPendingState() throws {
        struct Fixture: Codable {
            let inventory: ClusterInventory
            let change: ClusterPendingChange
            let job: ClusterTransferJob
            let capabilities: ClusterCapabilities
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cluster-state", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertEqual(fixture.inventory.objects.count, 1)
        XCTAssertEqual(fixture.inventory.objects[0].locations.count, 2)
        XCTAssertEqual(fixture.inventory.objects[0].bytes, 3)
        XCTAssertEqual(fixture.job.state, .queued)
        XCTAssertFalse(fixture.capabilities.allowsAutomaticWriter)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as? NSDictionary,
            try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func catalog() -> LocalCatalog {
        LocalCatalog(id: "legacy-library", name: "Original", entries: [LocalEntry(
            track: Track(id: "original-track", title: "Original", artist: "Artist", album: "Album", suffix: "wav", size: 3),
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", artwork: nil)])
    }

    private func catalogValue(_ catalog: LocalCatalog?) throws -> NSDictionary? {
        guard let catalog else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? NSDictionary)
    }

    func testMigrationPreservesSavedFilesMetadataAndIdentities() throws {
        let root = try root()
        let store = LocalMusicStore(root: root)
        let catalog = catalog()
        try Data("abc".utf8).write(to: store.fileURL(catalog.entries[0]))
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("catalog.json"))
        try store.save(catalog)
        let original = try XCTUnwrap(store.load())
        var sql: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &sql), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(sql, "DROP TABLE cluster_locations; DROP TABLE cluster_objects; DROP TABLE cluster_peers; DROP TABLE cluster_identity; DROP TABLE cluster_schema;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(sql)
        let database = try CatalogDatabase(root.appendingPathComponent("catalog.sqlite"))
        XCTAssertNil(try database.clusterInventory().cluster)
        let cluster = try database.createCluster(memberID: String(repeating: "1", count: 64))
        XCTAssertNotEqual(cluster.id, original.id)
        XCTAssertEqual(try CatalogDatabase(root.appendingPathComponent("catalog.sqlite")).createCluster(memberID: cluster.memberID), cluster)
        XCTAssertEqual(try catalogValue(store.load()), try catalogValue(original))
        XCTAssertTrue(store.hasFile(catalog.entries[0]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL(catalog.entries[0])), Data("abc".utf8))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("catalog.json"))) as? NSDictionary, try catalogValue(catalog))
        XCTAssertEqual(try database.clusterInventory().objects.count, 1)
    }

    func testTwoLocationsDeduplicateBytesWithoutReplacingOriginalAliases() throws {
        let database = try CatalogDatabase(try root().appendingPathComponent("catalog.sqlite"))
        let first = catalog()
        var second = first
        second.id = "another-library"
        second.entries[0].track.id = "another-track"
        second.entries[0].track.suffix = "mp3"
        try database.observeClusterCatalog(first)
        try database.observeClusterCatalog(second)
        try database.observeClusterCatalog(first)
        let inventory = try database.clusterInventory()
        XCTAssertEqual(inventory.objects.count, 1)
        XCTAssertEqual(inventory.objects[0].locations.map(\.trackID).sorted(), ["another-track", "original-track"])
        second.entries[0].track.size = 4
        XCTAssertThrowsError(try database.observeClusterCatalog(second))
        XCTAssertEqual(try database.clusterInventory(), inventory)
    }

    func testPendingChangesAndJobsPersistAndRecoverExplicitly() throws {
        let url = try root().appendingPathComponent("catalog.sqlite")
        let database = try CatalogDatabase(url)
        let change = ClusterPendingChange(id: UUID().uuidString, author: String(repeating: "1", count: 64), parents: [], operation: "{\"kind\":\"import\"}")
        try database.savePendingClusterChange(change)
        try database.savePendingClusterChange(change)
        XCTAssertThrowsError(try database.savePendingClusterChange(ClusterPendingChange(id: change.id, author: change.author, parents: [], operation: "{\"kind\":\"delete\"}")))
        let catalog = catalog()
        try database.observeClusterCatalog(catalog)
        let job = ClusterTransferJob(id: UUID().uuidString, sha256: catalog.entries[0].sha256, source: change.author, destination: String(repeating: "2", count: 64), state: .queued)
        try database.enqueueClusterJob(job)
        try database.beginClusterJob(job.id)
        let reopened = try CatalogDatabase(url)
        XCTAssertEqual(try reopened.clusterJobs().first?.state, .running)
        try reopened.recoverClusterJobs()
        XCTAssertEqual(try reopened.clusterJobs(), [job])
        XCTAssertEqual(try reopened.pendingClusterChanges(), [change])
        XCTAssertNil(try reopened.clusterInventory().cluster)
        XCTAssertFalse(try JSONDecoder().decode(ClusterCapabilities.self, from: Data("{}".utf8)).allowsAutomaticWriter)
        XCTAssertFalse(ClusterCapabilities(version: 1, membership: true, conflicts: true).allowsAutomaticWriter)
        XCTAssertTrue(ClusterCapabilities(version: 1, membership: true, deletions: true, conflicts: true).allowsAutomaticWriter)
        XCTAssertFalse(ClusterCapabilities(version: 2, membership: true, deletions: true, conflicts: true).allowsAutomaticWriter)
    }

    func testFailedProjectionRollsBackAndCanRetry() throws {
        let root = try root()
        let store = LocalMusicStore(root: root)
        try store.save(catalog())
        let original = try store.load()
        var sql: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &sql), SQLITE_OK)
        defer { sqlite3_close(sql) }
        XCTAssertEqual(sqlite3_exec(sql, "DELETE FROM cluster_locations; DELETE FROM cluster_objects; DROP TABLE cluster_schema; CREATE TRIGGER reject_cluster_object BEFORE INSERT ON cluster_objects BEGIN SELECT RAISE(ABORT, 'fixture interruption'); END;", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.load())
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(sql, "SELECT count(*) FROM sqlite_master WHERE name = 'cluster_schema'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_exec(sql, "DROP TRIGGER reject_cluster_object", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try catalogValue(store.load()), try catalogValue(original))
    }
}
