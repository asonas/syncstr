import Foundation
import AudioTags
import XCTest

@MainActor
final class PeerTransferTests: XCTestCase {
    func testSavedPeerSettingsRestoreWithoutConnectingAndClearOnRemoval() async throws {
        let identity = CredentialStore(service: "syncstr-settings-identity-" + UUID().uuidString)
        let pairing = CredentialStore(service: "syncstr-settings-peer-" + UUID().uuidString)
        let text = "{\"version\":1,\"id\":\"\(String(repeating: "a", count: 64))\",\"addresses\":[\"192.0.2.10:40000\"],\"relay\":null}"
        try await pairing.save(PairingCredentials(libraryID: String(repeating: "a", count: 64),
            name: "Fixture Node", key: Data(text.utf8).base64EncodedString()))
        let transfer = LocalTransfer(peerSecrets: identity, peerPairing: pairing)
        await transfer.restorePeer()
        XCTAssertEqual(transfer.peerName, "Fixture Node")
        XCTAssertEqual(transfer.peerAddressText, text)
        XCTAssertFalse(transfer.connected)
        await transfer.forgetPeer()
        await transfer.restorePeer()
        XCTAssertNil(transfer.peerName)
        XCTAssertEqual(transfer.peerAddressText, "")
        try await identity.remove()
    }

    func testEnrollmentReadsTheAdvertisedIdentityAndRejectsInvalidRecords() throws {
        let id = String(repeating: "a", count: 64)
        let text = "{\"version\":1,\"id\":\"\(id)\",\"addresses\":[\"192.0.2.10:40000\"],\"relay\":null}"
        XCTAssertEqual(try PeerAddress.parse(text).id, id)
        XCTAssertEqual(try PeerAddress.parse(text).addresses, ["192.0.2.10:40000"])
        XCTAssertThrowsError(try PeerAddress.parse(text.replacingOccurrences(of: id, with: "invalid")))
        XCTAssertThrowsError(try PeerAddress.parse(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2")))
        XCTAssertThrowsError(try PeerAddress.parse(text.replacingOccurrences(of: "[\"192.0.2.10:40000\"]", with: "[]")))
        XCTAssertThrowsError(try PeerAddress.parse(String(repeating: " ", count: 16385) + text))
        XCTAssertThrowsError(try PeerAddress.parse("https://example.com"))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("P2P operation timed out")
        throw LocalMusicError.disconnected
    }

    func testNativeClientUploadsRetriesDownloadsAndRestoresAgainstRustNode() async throws {
        try await exerciseNativeClient(directory: nil)
    }

    func testNativeClientTransfersThroughSignedDirectoryDiscovery() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SYNCSTR_DIRECTORY_TEST_URL"] else {
            throw XCTSkip("Set SYNCSTR_DIRECTORY_TEST_URL to test a deployed directory")
        }
        try await exerciseNativeClient(directory: directory)
    }

    private func exerciseNativeClient(directory: String?) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = repository.appendingPathComponent("headless/target/debug/syncstr-headless")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build headless with --features p2p before running interoperability tests")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let identity = root.appendingPathComponent("identity")
        let peer = root.appendingPathComponent("peer")
        let address = root.appendingPathComponent("address.json")
        let data = root.appendingPathComponent("data")
        _ = try run(["init", "--identity", identity.path])
        let serverID = try run(["peer-init", "--state", peer.path])
        let secrets = CredentialStore(service: "syncstr-p2p-test-identity-" + UUID().uuidString)
        let pairing = CredentialStore(service: "syncstr-p2p-test-peer-" + UUID().uuidString)
        let localPairing = CredentialStore(service: "syncstr-p2p-test-lan-" + UUID().uuidString)
        let files = LocalMusicStore(root: root.appendingPathComponent("received"))
        let transfer = LocalTransfer(store: files, secrets: localPairing, peerSecrets: secrets, peerPairing: pairing)
        var displayedCatalog: LocalCatalog?
        transfer.onCatalog = { catalog in
            try files.save(catalog)
            displayedCatalog = catalog
        }
        await transfer.restorePeer()
        _ = try run(["peer-pair", "--state", peer.path, "--peer", transfer.peerID])
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve", "--data", data.path, "--identity", identity.path, "--listen", "127.0.0.1:0",
            "--peer-state", peer.path, "--peer-address-out", address.path]
        if let directory { process.arguments?.append(contentsOf: ["--peer-directory", directory]) }
        process.standardOutput = Pipe()
        try process.run()
        defer { transfer.cancel(); process.terminate(); process.waitUntilExit() }
        try await wait { FileManager.default.fileExists(atPath: address.path) }
        var record = try JSONDecoder().decode(PeerAddress.self, from: Data(contentsOf: address))
        if let directory {
            record = PeerAddress(version: 1, id: serverID, addresses: [], relay: nil, directory: directory)
        }
        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        transfer.connectPeer(addressText: text, expected: String(repeating: "0", count: 64), name: "Fixture Node")
        try await wait { !transfer.busy }
        XCTAssertFalse(transfer.connected)
        transfer.connectPeer(addressText: text, expected: serverID, name: "Fixture Node")
        try await wait { !transfer.busy }
        XCTAssertTrue(transfer.peerConnected, transfer.status ?? "")
        let fixture = root.appendingPathComponent("12345.mp3")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.mp3")
        try FileManager.default.copyItem(at: source, to: fixture)
        try AudioTags.writeFile(fixture, fields: ["TITLE": "Tagged title", "ARTIST": "Tagged artist", "ALBUM": "Tagged album",
            "TRACKNUMBER": "3/12", "DISCNUMBER": "2/3"], artwork: nil, mimeType: nil, changeArtwork: false)
        let payload = try Data(contentsOf: fixture)
        for _ in 0..<2 {
            transfer.uploadPeer(files: [fixture])
            try await wait { !transfer.busy }
            XCTAssertEqual(transfer.completed, 1, transfer.status ?? "")
            XCTAssertTrue(transfer.connected, transfer.status ?? "")
            XCTAssertEqual(try files.load()?.entries.count, 1)
            XCTAssertEqual(try files.load()?.entries.first?.track.title, "Tagged title")
            XCTAssertEqual(try files.load()?.entries.first?.track.artist, "Tagged artist")
            XCTAssertEqual(displayedCatalog?.entries.first?.track.title, "Tagged title")
            XCTAssertGreaterThan(try files.load()?.entries.first?.track.duration ?? 0, 0)
        }
        let catalog = try XCTUnwrap(files.load())
        XCTAssertEqual(catalog.entries.count, 1)
        XCTAssertEqual(catalog.entries.first?.track.title, "Tagged title")
        XCTAssertEqual(catalog.entries.first?.track.artist, "Tagged artist")
        XCTAssertEqual(catalog.entries.first?.track.album, "Tagged album")
        XCTAssertEqual(catalog.entries.first?.track.track, 3)
        XCTAssertEqual(catalog.entries.first?.track.discNumber, 2)
        XCTAssertGreaterThan(catalog.entries.first?.track.duration ?? 0, 0)
        transfer.copy(catalog.entries.map(\.track))
        try await wait { !transfer.busy }
        let entry = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(try Data(contentsOf: files.fileURL(entry)), payload)
        var stale = entry
        stale.track = Track(id: entry.track.id, title: "12345", artist: nil, suffix: entry.track.suffix, size: entry.track.size)
        try files.save(LocalCatalog(id: catalog.id, name: catalog.name, entries: [stale]))
        await transfer.reconnectPeer()
        try await wait { !transfer.busy }
        XCTAssertEqual(try files.load()?.entries.first?.track.title, "Tagged title")
        XCTAssertEqual(try files.load()?.entries.first?.track.artist, "Tagged artist")
        XCTAssertTrue(files.hasFile(entry))
        let reopened = LocalMusicStore(root: files.root)
        XCTAssertTrue(reopened.hasFile(entry))
        XCTAssertEqual(try reopened.load()?.entries.count, 1)
        _ = try run(["peer-pair", "--state", peer.path, "--peer", transfer.peerID, "--revoke"])
        transfer.cancel()
        await transfer.reconnectPeer()
        try await wait { !transfer.busy }
        XCTAssertFalse(transfer.connected)
        await transfer.forgetPeer()
        XCTAssertTrue(files.hasFile(entry))
        try await secrets.remove()
        try await pairing.remove()
        try await localPairing.remove()
    }
}
