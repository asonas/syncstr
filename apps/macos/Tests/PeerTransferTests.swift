import Foundation
import AudioTags
import XCTest

@MainActor
final class PeerTransferTests: XCTestCase {
    func testSavedPeerSettingsRestoreWithoutConnectingAndClearOnRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = CredentialStore(service: "syncstr-settings-identity-" + UUID().uuidString)
        let pairing = CredentialStore(service: "syncstr-settings-peer-" + UUID().uuidString)
        let originalKey = PairingCredentials(libraryID: "p2p", name: "device", key: Data(repeating: 7, count: 32).base64EncodedString())
        try await identity.save(originalKey)
        let text = "{\"version\":1,\"id\":\"\(String(repeating: "a", count: 64))\",\"addresses\":[\"192.0.2.10:40000\"],\"relay\":null}"
        try await pairing.save(PairingCredentials(libraryID: String(repeating: "a", count: 64),
            name: "Fixture Node", key: Data(text.utf8).base64EncodedString()))
        let transfer = LocalTransfer(store: LocalMusicStore(root: root), peerSecrets: identity, peerPairing: pairing)
        await transfer.restorePeer()
        XCTAssertEqual(transfer.peerName, "Fixture Node")
        XCTAssertEqual(transfer.peerAddressText, text)
        XCTAssertFalse(transfer.connected)
        let inventory = try CatalogDatabase(root.appendingPathComponent("catalog.sqlite")).clusterInventory()
        XCTAssertNil(inventory.cluster)
        XCTAssertEqual(inventory.peers, [ClusterKnownPeer(id: String(repeating: "a", count: 64), name: "Fixture Node", address: text)])
        let restoredKey = try await identity.load()
        XCTAssertEqual(restoredKey, originalKey)
        await transfer.forgetPeer()
        await transfer.restorePeer()
        XCTAssertNil(transfer.peerName)
        XCTAssertEqual(transfer.peerAddressText, "")
        XCTAssertTrue(try CatalogDatabase(root.appendingPathComponent("catalog.sqlite")).clusterInventory().peers.isEmpty)
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

    func testNativeClientUploadsAfterIdleSessionExpires() async throws {
        try await exerciseNativeClient(directory: nil, idleSeconds: 125)
    }

    func testNativeClientTransfersThroughSignedDirectoryDiscovery() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SYNCSTR_DIRECTORY_TEST_URL"] else {
            throw XCTSkip("Set SYNCSTR_DIRECTORY_TEST_URL to test a deployed directory")
        }
        try await exerciseNativeClient(directory: directory)
    }

    func testExternalUploadBatchAgainstRustNode() async throws {
        guard let path = ProcessInfo.processInfo.environment["SYNCSTR_UPLOAD_TEST_DIRECTORY"] else {
            throw XCTSkip("Set SYNCSTR_UPLOAD_TEST_DIRECTORY to reproduce a real upload batch")
        }
        let idle = Double(ProcessInfo.processInfo.environment["SYNCSTR_UPLOAD_TEST_IDLE_SECONDS"] ?? "0") ?? 0
        try await exerciseNativeClient(directory: nil, externalDirectory: URL(fileURLWithPath: path), idleSeconds: idle)
    }

    private func exerciseNativeClient(directory: String?, externalDirectory: URL? = nil, idleSeconds: Double = 0) async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["SYNCSTR_HEADLESS_TEST_BINARY"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent("headless/target/debug/syncstr-headless")
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
        transfer.onCatalog = { prepared in
            displayedCatalog = prepared.catalog
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
        try await Task.sleep(for: .seconds(idleSeconds))
        if let externalDirectory {
            let uploads = try FileManager.default.contentsOfDirectory(at: externalDirectory, includingPropertiesForKeys: nil)
                .filter { ["mp3", "m4a"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            transfer.uploadPeer(files: uploads)
            for _ in 0..<4000 {
                if !transfer.busy { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertFalse(transfer.busy)
            XCTAssertEqual(transfer.completed, uploads.count, transfer.status ?? "")
            XCTAssertEqual(try files.load()?.entries.count, uploads.count)
            await transfer.forgetPeer()
            try await secrets.remove()
            try await pairing.remove()
            try await localPairing.remove()
            return
        }
        let fixture = root.appendingPathComponent("12345.mp3")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.mp3")
        try FileManager.default.copyItem(at: source, to: fixture)
        try AudioTags.writeFile(fixture, fields: ["TITLE": "Tagged title", "ARTIST": "Tagged artist", "ALBUM": "Tagged album",
            "TRACKNUMBER": "3/12", "DISCNUMBER": "2/3", "COMPILATION": "1"], artwork: nil, mimeType: nil, changeArtwork: false)
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
        XCTAssertFalse(transfer.busy)
        try await wait { !transfer.busy }
        XCTAssertEqual(try files.load()?.entries.first?.track.title, "Tagged title")
        XCTAssertEqual(try files.load()?.entries.first?.track.artist, "Tagged artist")
        XCTAssertTrue(files.hasFile(entry))
        let reopened = LocalMusicStore(root: files.root)
        XCTAssertTrue(reopened.hasFile(entry))
        XCTAssertEqual(try reopened.load()?.entries.count, 1)
        let albumID = try XCTUnwrap(reopened.load()?.organization?.albumID(for: entry.track.id))
        let companion = root.appendingPathComponent("companion.mp3")
        try FileManager.default.copyItem(at: source, to: companion)
        try AudioTags.writeFile(companion, fields: ["TITLE": "Another artist", "ARTIST": "Second artist", "ALBUM": "Tagged album", "COMPILATION": "1"], artwork: nil, mimeType: nil, changeArtwork: false)
        transfer.uploadPeer(files: [companion])
        try await wait { !transfer.busy }
        XCTAssertEqual(transfer.completed, 1, transfer.status ?? "")
        let compilation = try XCTUnwrap(reopened.load())
        XCTAssertEqual(compilation.entries.count, 2)
        XCTAssertEqual(Set(compilation.entries.compactMap { compilation.organization?.albumID(for: $0.track.id) }), [albumID])
        XCTAssertTrue(compilation.organization?.choices.isEmpty == true)
        let artwork = try AlbumArtworkTests.fixture()
        let modified = try files.fileURL(entry).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        transfer.onOrganization = { organization in
            do {
                var catalog = try XCTUnwrap(files.load())
                catalog.organization = organization
                try files.save(catalog)
            } catch { XCTFail("Could not persist image synchronization: \(error)") }
        }
        var withImage = try XCTUnwrap(files.load())
        try withImage.organization?.captureArtwork(try XCTUnwrap(artwork.organization.artwork?.assets[artwork.blue]), track: entry.track.id, source: "music", context: "fixture-music-item")
        withImage.organization?.artwork?.assets[artwork.red] = artwork.organization.artwork?.assets[artwork.red]
        withImage.organization?.set(subject: albumID, kind: "artwork", value: artwork.red)
        try files.save(withImage)
        transfer.syncOrganization()
        try await wait { !transfer.busy }
        XCTAssertTrue(transfer.connected, transfer.status ?? "")
        // Drop local image metadata to prove the next copy comes from the Rust host.
        try files.save(compilation)
        await transfer.reconnectPeer()
        try await wait { !transfer.busy }
        XCTAssertEqual(try files.load()?.organization?.coverAsset(for: albumID), artwork.red)
        XCTAssertEqual(try files.load()?.organization?.artwork?.assets[artwork.blue], artwork.organization.artwork?.assets[artwork.blue])
        var cleared = try XCTUnwrap(files.load())
        cleared.organization?.set(subject: albumID, kind: "artwork", value: nil)
        try files.save(cleared)
        transfer.syncOrganization()
        try await wait { !transfer.busy }
        try files.save(compilation)
        await transfer.reconnectPeer()
        try await wait { !transfer.busy }
        XCTAssertEqual(try files.load()?.organization?.coverAsset(for: albumID), artwork.blue)
        XCTAssertEqual(try files.fileURL(entry).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(try Data(contentsOf: files.fileURL(entry)), payload)
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
