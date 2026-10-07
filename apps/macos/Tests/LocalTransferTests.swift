import AVFoundation
import AppKit
import AudioTags
import CryptoKit
import Network
import Security
import XCTest

@MainActor
final class LocalTransferTests: XCTestCase {
    func testExistingPairingRecordSurvivesAccountModelRemoval() async throws {
        let service = "syncstr-pairing-update-test-" + UUID().uuidString
        let store = CredentialStore(service: service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "last-login"
        ]
        defer { SecItemDelete(query as CFDictionary) }
        var item = query
        item[kSecValueData as String] = Data(#"{"server":"fixture-library","username":"Fixture Phone","password":"0123456789abcdef0123456789abcdef"}"#.utf8)
        item[kSecAttrSynchronizable as String] = false
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        let saved = try await store.load()
        XCTAssertEqual(saved, PairingCredentials(libraryID: "fixture-library", name: "Fixture Phone",
            key: "0123456789abcdef0123456789abcdef"))
        try await store.save(try XCTUnwrap(saved))
        let reopened = try await store.load()
        XCTAssertEqual(reopened, saved)
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for public state", file: file, line: line)
        throw LocalMusicError.disconnected
    }

    private func fixture(_ root: URL, name: String = "First") throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        if name == "Second" { buffer.floatChannelData![0][0] = 0.25 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testPairTransferRetryAndRestorePreserveOriginalAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("album")
        let original = try fixture(source)
        let second = try fixture(source, name: "Second")
        let originalBytes = try Data(contentsOf: original)
        let expected = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        let folder = try await LocalFolder.scan(source, id: UUID().uuidString)
        XCTAssertEqual(folder.catalog.entries.count, 2)
        let senderStore = CredentialStore(service: "syncstr-test-sender-" + UUID().uuidString)
        let receiverStore = CredentialStore(service: "syncstr-test-receiver-" + UUID().uuidString)
        let files = LocalMusicStore(root: root.appendingPathComponent("received"))
        let sender = LocalTransfer(store: LocalMusicStore(root: root.appendingPathComponent("sender")), secrets: senderStore)
        let receiver = LocalTransfer(store: files, secrets: receiverStore)
        do {
            try await sender.host(folder)
            try await wait { sender.advertisedPort != nil }
            var device = NearbyMusicDevice(id: "Syncstr-" + folder.catalog.id, name: "Fixture Mac",
                endpoint: .hostPort(host: "127.0.0.1", port: sender.advertisedPort!))
            receiver.connect(device, code: sender.code, name: "Fixture Phone")
            try await wait { sender.pendingName != nil || !receiver.busy }
            XCTAssertEqual(sender.pendingName, "Fixture Phone", receiver.status ?? "")
            XCTAssertNil(try files.load(), "Catalog must not be exposed before approval")
            sender.approve(true)
            try await wait { !receiver.busy }
            XCTAssertTrue(receiver.connected, receiver.status ?? "")
            receiver.onSaved = { if receiver.completed == 1 { receiver.cancel() } }
            receiver.copy(folder.catalog.entries.map(\.track))
            try await wait { !receiver.busy }
            XCTAssertEqual(receiver.completed, 1)
            XCTAssertEqual(folder.catalog.entries.filter { files.hasFile($0) }.count, 1)
            receiver.onSaved = nil
            receiver.connect(device, code: "", name: "Fixture Phone")
            try await wait { !receiver.busy }
            XCTAssertTrue(receiver.connected, receiver.status ?? "")
            receiver.copy(folder.catalog.entries.map(\.track))
            try await wait { !receiver.busy }
            XCTAssertEqual(receiver.completed, 2, receiver.status ?? "")
            let restored = try XCTUnwrap(files.load())
            XCTAssertEqual(restored.entries.count, 2)
            let entry = try XCTUnwrap(restored.entries.first { $0.track.title == "First" })
            XCTAssertEqual(entry.sha256, expected)
            XCTAssertEqual(try Data(contentsOf: files.fileURL(entry)), originalBytes)
            let before = try files.fileURL(entry).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            receiver.copy(folder.catalog.entries.map(\.track))
            try await wait { !receiver.busy }
            XCTAssertEqual(receiver.completed, 2)
            XCTAssertEqual(try files.fileURL(entry).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
            XCTAssertEqual(try Data(contentsOf: original), originalBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
            receiver.cancel()
            receiver.connect(device, code: "", name: "Fixture Phone")
            try await wait { !receiver.busy }
            XCTAssertTrue(receiver.connected, receiver.status ?? "")
            XCTAssertNil(sender.pendingName, "Saved pairing must reconnect without approval")
            receiver.cancel()
            var reduced = folder
            reduced.catalog.entries.removeFirst()
            reduced.catalog.entries[0].track = Track(id: reduced.catalog.entries[0].track.id, title: "Changed title",
                artist: nil, suffix: "wav", size: reduced.catalog.entries[0].track.size)
            try await sender.host(reduced)
            try await wait { sender.advertisedPort != nil }
            device.endpoint = .hostPort(host: "127.0.0.1", port: sender.advertisedPort!)
            receiver.connect(device, code: "", name: "Fixture Phone")
            try await wait { !receiver.busy }
            let retained = try XCTUnwrap(files.load())
            XCTAssertEqual(Set(retained.entries.map { $0.track.title }), ["First", "Second"],
                "Source deletions and tag edits must not replace completed local copies")
            let missing = reduced.catalog.entries[0]
            try FileManager.default.removeItem(at: files.fileURL(missing))
            try Data("changed source".utf8).write(to: folder.files[missing.track.id]!)
            receiver.copy([missing.track])
            try await wait { !receiver.busy }
            XCTAssertFalse(files.hasFile(missing))
            XCTAssertEqual(receiver.status, LocalMusicError.changedFile.localizedDescription)
            await sender.forget()
            receiver.cancel()
            XCTAssertEqual(folder.catalog.entries.filter { files.hasFile($0) }.count, 1, "Removing pairing must retain received music")
            await receiver.forget()
        } catch {
            await sender.forget()
            await receiver.forget()
            throw error
        }
    }

    func testRejectedPairingDoesNotPersistCredentialsOrExposeCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(root.appendingPathComponent("source"))
        let folder = try await LocalFolder.scan(root.appendingPathComponent("source"), id: UUID().uuidString)
        let senderStore = CredentialStore(service: "syncstr-test-sender-" + UUID().uuidString)
        let receiverStore = CredentialStore(service: "syncstr-test-receiver-" + UUID().uuidString)
        let files = LocalMusicStore(root: root.appendingPathComponent("received"))
        let sender = LocalTransfer(secrets: senderStore)
        let receiver = LocalTransfer(store: files, secrets: receiverStore)
        do {
            try await sender.host(folder)
            try await wait { sender.advertisedPort != nil }
            let wrongKey = MusicConnection(NWConnection(to: .hostPort(host: "127.0.0.1", port: sender.advertisedPort!),
                using: try MusicConnection.parameters(code: String(repeating: "0", count: 32), identity: folder.catalog.id)))
            do { try await wrongKey.start(); XCTFail("A different pairing key must not authenticate") }
            catch { XCTAssertNil(sender.pendingName) }
            wrongKey.close()
            receiver.connect(NearbyMusicDevice(id: "Syncstr-" + folder.catalog.id, name: "Fixture Mac",
                endpoint: .hostPort(host: "127.0.0.1", port: sender.advertisedPort!)), code: sender.code, name: "Fixture Phone")
            try await wait { sender.pendingName != nil }
            sender.approve(false)
            try await wait { !receiver.busy }
            XCTAssertFalse(receiver.connected)
            XCTAssertNil(try files.load())
            let senderSaved = try await senderStore.load()
            let receiverSaved = try await receiverStore.load()
            XCTAssertNil(senderSaved)
            XCTAssertNil(receiverSaved)
            await sender.forget()
            await receiver.forget()
        } catch { await sender.forget(); await receiver.forget(); throw error }
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
    }

    func testScanReadsTagsAndArtworkWithoutFollowingExternalLinksOrEditingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("album")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 6, bitsPerPixel: 24)!
        memset(bitmap.bitmapData!, 128, 12)
        let picture = bitmap.representation(using: .png, properties: [:])!
        var originals: [String: Data] = [:]
        for ext in ["mp3", "flac", "m4a"] {
            let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "untagged", withExtension: ext))
            let copy = source.appendingPathComponent("track." + ext)
            try FileManager.default.copyItem(at: fixture, to: copy)
            try AudioTags.writeFile(copy, fields: ["TITLE": "夜の音楽", "ARTIST": "音楽家", "ALBUM": "Album", "TRACKNUMBER": "2/12", "DISCNUMBER": "1"],
                artwork: picture, mimeType: "image/png", changeArtwork: true)
            originals[copy.lastPathComponent] = try Data(contentsOf: copy)
        }
        let external = try fixture(root, name: "External")
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("external.wav"), withDestinationURL: external)
        let id = UUID().uuidString
        let folder = try await Task.detached { try await LocalFolder.scan(source, id: id) }.value
        XCTAssertEqual(folder.catalog.entries.count, 3)
        XCTAssertEqual(Set(folder.catalog.entries.compactMap { $0.track.suffix }), ["mp3", "flac", "m4a"])
        for entry in folder.catalog.entries {
            XCTAssertEqual(entry.track.title, "夜の音楽")
            XCTAssertEqual(entry.track.artist, "音楽家")
            XCTAssertEqual(entry.track.track, 2)
            XCTAssertEqual(entry.track.discNumber, 1)
            XCTAssertNotNil(entry.artwork)
            XCTAssertEqual(try Data(contentsOf: folder.files[entry.track.id]!), originals[folder.files[entry.track.id]!.lastPathComponent])
        }
        let rescanned = try await LocalFolder.scan(source, id: id)
        XCTAssertEqual(rescanned.catalog.entries.map { $0.track.id }, folder.catalog.entries.map { $0.track.id })
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
