import AVFoundation
import AppKit
import AudioTags
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
