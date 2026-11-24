import Security
import XCTest

@MainActor
final class LocalTransferTests: XCTestCase {
    func testLegacyKeychainCleanupRunsOnceAndAcceptsMissingItems() async {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cleanup = LegacyKeychainCleanup()
        var services: [String] = []
        await cleanup.run(defaults: defaults) { service in
            services.append(service)
            return service.hasSuffix("identity") ? errSecSuccess : errSecItemNotFound
        }
        await cleanup.run(defaults: defaults) { _ in XCTFail("Repeated cleanup"); return errSecSuccess }
        XCTAssertEqual(services, ["as.ason.syncstr.local-pair", "as.ason.syncstr.p2p.identity", "as.ason.syncstr.p2p.peer"])
    }

    func testCorruptAndPartialFilesNeverBecomeAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = LocalMusicStore(root: root)
        try files.prepare()
        let entry = LocalEntry(track: Track(id: "sample", title: "Sample", artist: nil, suffix: "wav", size: 3),
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", artwork: nil)
        let temporary = root.appendingPathComponent("partial")
        try Data("ab".utf8).write(to: temporary)
        XCTAssertThrowsError(try files.importFile(temporary, entry: entry))
        XCTAssertFalse(files.hasFile(entry))
        try Data("xyz".utf8).write(to: temporary)
        XCTAssertThrowsError(try files.importFile(temporary, entry: entry))
        XCTAssertFalse(files.hasFile(entry))
        try Data("abc".utf8).write(to: temporary)
        try files.importFile(temporary, entry: entry)
        XCTAssertTrue(files.hasFile(entry))
        XCTAssertFalse(files.hasCatalog)
    }

    func testStorageFailureDoesNotPublishAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let temporary = root.appendingPathComponent("partial")
        try Data("abc".utf8).write(to: temporary)
        let files = LocalMusicStore(root: blocked)
        let entry = LocalEntry(track: Track(id: "sample", title: "Sample", artist: nil, suffix: "wav", size: 3),
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", artwork: nil)
        XCTAssertThrowsError(try files.importFile(temporary, entry: entry))
        XCTAssertFalse(files.hasFile(entry))
        XCTAssertEqual(try Data(contentsOf: temporary), Data("abc".utf8))
    }
}
