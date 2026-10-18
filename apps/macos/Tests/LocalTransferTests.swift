import AVFoundation
import AppKit
import AudioTags
import CryptoKit
import Network
import Security
import XCTest

@MainActor
final class LocalTransferTests: XCTestCase {
    func testCompilationUpgradeRereadsOriginalTagsAndRetainsContextAfterMove() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let album = source.appendingPathComponent("Collection")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.m4a")
        var originals: [URL: Data] = [:]
        for number in 1...20 {
            let url = album.appendingPathComponent("Track \(number).m4a")
            try FileManager.default.copyItem(at: fixture, to: url)
            try AudioTags.writeFile(url, fields: ["TITLE": "Track \(number)", "ARTIST": "Artist \(number)", "ALBUM": "Collection", "COMPILATION": "1", "TRACKNUMBER": "\(number)"], artwork: nil, mimeType: nil, changeArtwork: false)
            originals[url] = try Data(contentsOf: url)
        }
        let initial = try await LocalFolder.scan(source, id: "source-a")
        XCTAssertEqual(Set(initial.catalog.entries.compactMap { initial.catalog.organization?.albumID(for: $0.track.id) }).count, 1)
        var legacy = initial
        legacy.catalog.organization = nil
        for index in legacy.catalog.entries.indices { legacy.catalog.entries[index].importedAlbum = nil }
        legacy.catalog.organize()
        XCTAssertEqual(legacy.catalog.organization?.albums.count, 20)
        let store = LocalMusicStore(root: root.appendingPathComponent("catalog"))
        try store.save(legacy)
        let repaired = try await LocalFolder.scan(source, id: "source-a", previous: store.snapshot())
        XCTAssertEqual(Set(repaired.catalog.entries.map { $0.track.id }), Set(initial.catalog.entries.map { $0.track.id }))
        XCTAssertEqual(Set(repaired.catalog.entries.compactMap { repaired.catalog.organization?.albumID(for: $0.track.id) }).count, 1)
        XCTAssertTrue(repaired.catalog.organization?.choices.isEmpty == true)
        try store.save(repaired)
        let moved = source.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: album, to: moved)
        let rescanned = try await LocalFolder.scan(source, id: "source-a", previous: store.snapshot())
        XCTAssertEqual(rescanned.catalog.organization, repaired.catalog.organization)
        for (url, bytes) in originals { XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(url.lastPathComponent)), bytes) }
        let prepared = try await UploadedMusic.prepare(Array(rescanned.files.values), organization: AlbumOrganization(), sourceID: "uploader")
        XCTAssertEqual(Set(prepared.organization.tracks.compactMap { prepared.organization.albumID(for: $0.id) }).count, 1)
        XCTAssertTrue(prepared.organization.tracks.allSatisfy { !($0.importContext?.folder.contains(root.path) ?? true) })
    }

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

    func testUnavailableTrackReturnsByExactContentWithoutLosingOrganization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let first = try fixture(source)
        _ = try fixture(source, name: "Second")
        let store = LocalMusicStore(root: root.appendingPathComponent("catalog"))
        var initial = try await LocalFolder.scan(source, id: "fixture-library")
        let entry = try XCTUnwrap(initial.catalog.entries.first { initial.files[$0.track.id] == first })
        let album = try XCTUnwrap(initial.catalog.organization?.albumID(for: entry.track.id))
        initial.catalog.organization?.set(subject: album, kind: "classification", value: "true")
        try store.save(initial)
        let absent = root.appendingPathComponent("unavailable.wav")
        try FileManager.default.moveItem(at: first, to: absent)
        let reduced = try await LocalFolder.scan(source, id: "fixture-library", previous: store.snapshot())
        try store.save(reduced)
        XCTAssertFalse(reduced.catalog.entries.contains { $0.track.id == entry.track.id })
        XCTAssertNil(reduced.files[entry.track.id])
        XCTAssertEqual(reduced.catalog.organization?.albumID(for: entry.track.id), album)
        try FileManager.default.moveItem(at: absent, to: source.appendingPathComponent("Returned.wav"))
        let returned = try await LocalFolder.scan(source, id: "fixture-library", previous: store.snapshot())
        XCTAssertTrue(returned.catalog.entries.contains { $0.track.id == entry.track.id })
        XCTAssertEqual(returned.catalog.organization?.choice(subject: album, kind: "classification")?.value, "true")
        XCTAssertEqual(try LocalMusicStore.digest(file: returned.files[entry.track.id]!), entry.sha256)
    }

    func testPairTransferRetryAndRestorePreserveOriginalAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("album")
        let original = try fixture(source)
        let second = try fixture(source, name: "Second")
        let originalBytes = try Data(contentsOf: original)
        let expected = SHA256.hash(data: originalBytes).map { String(format: "%02x", $0) }.joined()
        var folder = try await LocalFolder.scan(source, id: UUID().uuidString)
        let organizedAlbum = try XCTUnwrap(folder.catalog.organization?.albumID(for: folder.catalog.entries[0].track.id))
        folder.catalog.organization?.set(subject: organizedAlbum, kind: "classification", value: "true")
        XCTAssertEqual(folder.catalog.entries.count, 2)
        let senderStore = CredentialStore(service: "syncstr-test-sender-" + UUID().uuidString)
        let receiverStore = CredentialStore(service: "syncstr-test-receiver-" + UUID().uuidString)
        let files = LocalMusicStore(root: root.appendingPathComponent("received"))
        let sender = LocalTransfer(store: LocalMusicStore(root: root.appendingPathComponent("sender")), secrets: senderStore)
        let diagnostics = PlaybackDiagnostics(root: root.appendingPathComponent("diagnostics"))
        let receiver = LocalTransfer(store: files, secrets: receiverStore, diagnostics: diagnostics)
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
            XCTAssertEqual(try files.load()?.organization?.choice(subject: organizedAlbum, kind: "classification")?.value, "true")
            let trace = diagnostics.begin(title: "Fixture", track: folder.catalog.entries[0].track.id,
                sha256: folder.catalog.entries[0].sha256, library: folder.catalog.id)
            let cached = try await receiver.playbackFile(folder.catalog.entries[0].track, diagnostic: trace)
            let diagnosticTrace = await diagnostics.recent().first
            XCTAssertTrue(diagnosticTrace?.events.contains { $0.event == "connect_tls" && $0.outcome == "succeeded" } == true)
            XCTAssertTrue(diagnosticTrace?.events.contains { $0.stage == "selection" && $0.fields["mode"] == "tls_psk_channel" } == true)
            XCTAssertTrue(diagnosticTrace?.events.contains { $0.stage == "verification" && $0.event == "hash" && $0.outcome == "matched" } == true)
            XCTAssertTrue(diagnosticTrace?.events.contains { $0.stage == "save" && $0.outcome == "succeeded" } == true)
            XCTAssertEqual(try LocalMusicStore.digest(file: cached), folder.catalog.entries[0].sha256)
            XCTAssertFalse(files.hasFile(folder.catalog.entries[0]))
            receiver.cancel()
            let uncached = folder.catalog.entries[1]
            let recovered = try await receiver.playbackFile(uncached.track)
            XCTAssertTrue(receiver.connected, receiver.status ?? "")
            XCTAssertEqual(try LocalMusicStore.digest(file: recovered), uncached.sha256)
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
            var phoneCatalog = try XCTUnwrap(files.load())
            phoneCatalog.organization?.set(subject: organizedAlbum, kind: "classification", value: "false")
            try files.save(phoneCatalog)
            reduced.catalog.organization?.set(subject: organizedAlbum, kind: "classification", value: nil)
            reduced.catalog.entries.removeFirst()
            reduced.catalog.entries[0].track = Track(id: reduced.catalog.entries[0].track.id, title: "Changed title",
                artist: nil, suffix: "wav", size: reduced.catalog.entries[0].track.size)
            try await sender.host(reduced)
            try await wait { sender.advertisedPort != nil }
            device.endpoint = .hostPort(host: "127.0.0.1", port: sender.advertisedPort!)
            receiver.connect(device, code: "", name: "Fixture Phone")
            try await wait { !receiver.busy }
            let retained = try XCTUnwrap(files.load())
            XCTAssertTrue(retained.organization?.hasConflict(subject: organizedAlbum, kind: "classification") ?? false)
            XCTAssertEqual(retained.organization?.choice(subject: organizedAlbum, kind: "classification")?.value, "false")
            let removed = folder.catalog.entries[0]
            XCTAssertEqual(retained.entries.first { $0.track.id == removed.track.id }?.track.title, removed.track.title)
            XCTAssertEqual(retained.entries.first { $0.track.id == reduced.catalog.entries[0].track.id }?.track.title, "Changed title")
            XCTAssertTrue(retained.entries.allSatisfy(files.hasFile), "Metadata refresh must retain completed local audio")
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
            let cluster = MusicConnection(NWConnection(to: .hostPort(host: "127.0.0.1", port: sender.advertisedPort!),
                using: try MusicConnection.parameters(code: sender.code, identity: folder.catalog.id)))
            try await cluster.start()
            try await cluster.send(MusicMessage(kind: "cluster-hello", clusterCapabilities: ClusterCapabilities(version: 1, membership: true, deletions: true, conflicts: true)))
            let upgrade = try await cluster.receive()
            XCTAssertEqual(upgrade.kind, "upgrade-required")
            XCTAssertFalse(try XCTUnwrap(upgrade.clusterCapabilities).allowsAutomaticWriter)
            XCTAssertNil(sender.pendingName)
            cluster.close()
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
        XCTAssertFalse(files.hasCatalog)
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
        let store = LocalMusicStore(root: root.appendingPathComponent("catalog"))
        try store.save(folder)
        let rescanned = try await LocalFolder.scan(source, id: id, previous: store.snapshot())
        XCTAssertEqual(rescanned.catalog.entries.map { $0.track.id }, folder.catalog.entries.map { $0.track.id })
    }

    func testSourceLocationsAndIdentitySurviveMigrationRenameAndDuplicateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let original = try fixture(source)
        let store = LocalMusicStore(root: root.appendingPathComponent("catalog"))
        var legacy = try await LocalFolder.scan(source, id: "fixture-library").catalog
        legacy.organization = nil
        let enumerated = try XCTUnwrap(FileManager.default.enumerator(at: source.standardizedFileURL.resolvingSymlinksInPath(),
            includingPropertiesForKeys: nil)?.nextObject() as? URL)
        let legacyRelative = String(enumerated.path.dropFirst(source.standardizedFileURL.resolvingSymlinksInPath().path.count))
        let legacyID = LocalMusicStore.digest(Data(("fixture-library" + legacyRelative).utf8))
        legacy.entries[0].track.id = legacyID
        try store.prepare()
        try JSONEncoder().encode(legacy).write(to: store.root.appendingPathComponent("catalog.json"))
        let migrated = try await LocalFolder.scan(source, id: legacy.id, previous: store.snapshot())
        XCTAssertEqual(migrated.catalog.entries[0].track.id, legacyID)
        try store.save(migrated)
        XCTAssertEqual(try store.snapshot()?.sourcePaths, [legacyID: "First.wav"])
        let renamed = source.appendingPathComponent("Renamed.wav")
        try FileManager.default.moveItem(at: original, to: renamed)
        let reopened = LocalMusicStore(root: store.root)
        let scanned = try await LocalFolder.scan(source, id: legacy.id, previous: reopened.snapshot())
        XCTAssertEqual(scanned.catalog.entries[0].track.id, legacyID)
        XCTAssertEqual(scanned.files[legacyID], renamed)
        try reopened.save(scanned)
        let duplicate = source.appendingPathComponent("Duplicate.wav")
        try FileManager.default.copyItem(at: renamed, to: duplicate)
        let copied = try await LocalFolder.scan(source, id: legacy.id, previous: reopened.snapshot())
        XCTAssertEqual(copied.catalog.entries.count, 2)
        XCTAssertEqual(Set(copied.catalog.entries.map { $0.track.id }).count, 2)
        XCTAssertEqual(copied.files[legacyID], renamed)
        try reopened.save(copied)
        try FileManager.default.moveItem(at: renamed, to: source.appendingPathComponent("A.wav"))
        try FileManager.default.moveItem(at: duplicate, to: source.appendingPathComponent("B.wav"))
        let ambiguous = try await LocalFolder.scan(source, id: legacy.id, previous: reopened.snapshot())
        XCTAssertTrue(Set(ambiguous.files.keys).isDisjoint(with: copied.files.keys))
        try reopened.save(ambiguous)
        XCTAssertEqual(try reopened.snapshot()?.sourceRoot?.path, source.path)
        XCTAssertEqual(Set(try XCTUnwrap(reopened.snapshot()).sourcePaths.values), ["A.wav", "B.wav"])
    }

    func testLegacyDuplicateIDsSurvivePathNormalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let original = try fixture(source)
        try FileManager.default.copyItem(at: original, to: source.appendingPathComponent("Copy.wav"))
        var catalog = try await LocalFolder.scan(source, id: "legacy").catalog
        catalog.organization = nil
        let canonical = source.standardizedFileURL.resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: nil))
        var idsByName: [String: String] = [:]
        for case let url as URL in enumerator {
            idsByName[url.deletingPathExtension().lastPathComponent] = LocalMusicStore.digest(
                Data(("legacy" + String(url.path.dropFirst(canonical.path.count))).utf8))
        }
        for index in catalog.entries.indices {
            catalog.entries[index].track.id = try XCTUnwrap(idsByName[catalog.entries[index].track.title])
        }
        let previous = CatalogSnapshot(catalog: catalog, sourceRoot: nil, sourcePaths: [:])
        let scanned = try await LocalFolder.scan(source, id: catalog.id, previous: previous)
        for entry in scanned.catalog.entries {
            XCTAssertEqual(entry.track.id, idsByName[entry.track.title])
        }
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
