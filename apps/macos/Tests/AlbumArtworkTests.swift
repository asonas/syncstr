import Foundation
import XCTest
import AudioTags
#if os(iOS)
@testable import Syncstr
#endif

final class AlbumArtworkTests: XCTestCase {
    struct Fixture: Decodable {
        var organization: AlbumOrganization
        var blue: String
        var red: String
    }

    static func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "album-artwork", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testFolderArtworkSurvivesCatalogRestartWithoutAudio() throws {
        let fixture = try Self.fixture()
        let image = try XCTUnwrap(fixture.organization.artwork?.assets[fixture.blue])
        let entry = LocalEntry(track: Track(id: "track", title: "Track", artist: "Artist", album: "Collection", suffix: "mp3", size: 3), sha256: String(repeating: "a", count: 64))
        var catalog = LocalCatalog(id: "source", name: "Collection", entries: [entry])
        catalog.organize(folders: ["track": "Collection"])
        let album = try XCTUnwrap(catalog.organization?.albumID(for: "track"))
        try catalog.organization?.captureArtwork(image, track: "track", source: "folder", context: "source/Collection/cover.jpg")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        try store.save(catalog)
        let reopened = try XCTUnwrap(store.load())
        let asset = try XCTUnwrap(reopened.organization?.coverAsset(for: album))
        XCTAssertEqual(reopened.organization?.artwork?.assets[asset], image)
        XCTAssertNil(reopened.entries[0].artwork)
        XCTAssertFalse(store.hasFile(entry))
    }

    func testConcurrentManualChoicesClearAndReorderedDeliveryRetainImages() throws {
        let fixture = try Self.fixture()
        var local = fixture.organization
        var peer = local
        local.set(subject: "album-a", kind: "artwork", value: fixture.blue)
        peer.set(subject: "album-a", kind: "artwork", value: fixture.red)
        let before = local
        try local.merge(peer)
        XCTAssertTrue(local.hasArtworkConflict("album-a"))
        XCTAssertEqual(local.coverAsset(for: "album-a"), fixture.blue)
        local.set(subject: "album-a", kind: "artwork", value: nil)
        try local.merge(before)
        try local.merge(peer)
        XCTAssertFalse(local.hasArtworkConflict("album-a"))
        XCTAssertEqual(local.coverAsset(for: "album-a"), fixture.blue)
        XCTAssertEqual(local.artwork?.assets.count, 2)
        try local.validate()
    }

    func testConcurrentAcquisitionKeepsLocalCoverUntilManualResolution() throws {
        let fixture = try Self.fixture()
        var local = fixture.organization
        var peer = local
        let red = try XCTUnwrap(local.artwork?.assets[fixture.red])
        try local.captureArtwork(red, track: "track-a", source: "folder", context: "source-context")
        try peer.captureArtwork(try XCTUnwrap(local.artwork?.assets[fixture.blue]), track: "track-a", source: "folder", context: "independent-import")
        try local.merge(peer)
        XCTAssertTrue(local.hasArtworkConflict("album-a"))
        XCTAssertEqual(local.coverAsset(for: "album-a"), fixture.red)
        try local.chooseArtwork(red, album: "album-a")
        XCTAssertFalse(local.hasArtworkConflict("album-a"))
    }

    func testCorruptImageMergeDoesNotReplaceSavedCatalog() throws {
        let fixture = try Self.fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        var catalog = LocalCatalog(id: "source", name: "Collection", entries: [], organization: fixture.organization)
        try store.save(catalog)
        catalog.organization?.artwork?.assets[fixture.blue] = Data([0, 1, 2])
        XCTAssertThrowsError(try store.save(catalog))
        XCTAssertEqual(try store.load()?.organization?.coverAsset(for: "album-a"), fixture.blue)
        XCTAssertEqual(try store.load()?.organization?.artwork?.assets[fixture.blue], fixture.organization.artwork?.assets[fixture.blue])
    }

    func testAcquisitionUsesEmbeddedThenRecognizedFolderThenExactMusicAndRetainsOnFailure() throws {
        let fixture = try Self.fixture()
        let blue = try XCTUnwrap(fixture.organization.artwork?.assets[fixture.blue])
        let red = try XCTUnwrap(fixture.organization.artwork?.assets[fixture.red])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("track.m4a")
        let entry = LocalEntry(track: Track(id: "track-a", title: "Track", artist: nil, suffix: "m4a", size: 3), sha256: String(repeating: "a", count: 64))
        var organization = fixture.organization
        organization.artwork = nil
        try red.write(to: root.appendingPathComponent("folder.jpg"))
        try blue.write(to: root.appendingPathComponent("COVER.JPG"))
        try ArtworkAcquisition.collect(entries: [entry], originals: ["track-a": original], organization: &organization, music: { _ in XCTFail("Folder image should avoid Music access"); return nil })
        XCTAssertEqual(organization.coverAsset(for: "album-a"), fixture.blue)
        try FileManager.default.removeItem(at: root.appendingPathComponent("COVER.JPG"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("folder.jpg"))
        try Data("corrupt image".utf8).write(to: root.appendingPathComponent("cover.png"))
        organization.artwork = nil
        try ArtworkAcquisition.collect(entries: [entry], originals: ["track-a": original], organization: &organization, music: { url in
            XCTAssertEqual(url, original); return red
        })
        XCTAssertEqual(organization.coverAsset(for: "album-a"), fixture.red)
        let retained = organization
        try ArtworkAcquisition.collect(entries: [entry], originals: ["track-a": original], organization: &organization, music: { _ in nil })
        XCTAssertEqual(organization, retained)
        var embedded = entry
        embedded.artwork = blue
        try ArtworkAcquisition.collect(entries: [embedded], originals: ["track-a": original], organization: &organization, music: { _ in XCTFail("Embedded image should avoid Music access"); return nil })
        XCTAssertEqual(organization.coverAsset(for: "album-a"), fixture.blue)
    }

#if os(macOS)
    func testRealMP3M4AAndFLACEmbeddedImagesImport() async throws {
        let fixture = try Self.fixture()
        let blue = try XCTUnwrap(fixture.organization.artwork?.assets[fixture.blue])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        var files: [URL] = []
        for suffix in ["mp3", "m4a", "flac"] {
            let file = root.appendingPathComponent("track." + suffix)
            try FileManager.default.copyItem(at: sources.appendingPathComponent("untagged." + suffix), to: file)
            try AudioTags.writeFile(file, fields: ["ALBUM": "Collection", "ARTIST": "Artist", "COMPILATION": "1"], artwork: blue, mimeType: "image/jpeg", changeArtwork: true)
            files.append(file)
        }
        let prepared = try await UploadedMusic.prepare(files, organization: AlbumOrganization(), sourceID: "fixture-source")
        XCTAssertEqual(prepared.organization.artwork?.candidates.filter { $0.source == "embedded" }.count, 3)
        XCTAssertTrue(prepared.entries.allSatisfy { $0.artwork == blue })
    }
#endif

    func testMusicSnapshotIsLazyExactAndAmbiguousLocationsAreNotGuessed() throws {
        let fixture = try Self.fixture()
        let image = try XCTUnwrap(fixture.organization.artwork?.assets[fixture.blue])
        let exact = URL(fileURLWithPath: "/fixture/Collection/First.m4a")
        let ambiguous = URL(fileURLWithPath: "/fixture/Collection/Second.m4a")
        var reads = 0
        let reader = ArtworkAcquisition.musicReader {
            reads += 1
            return [(exact, { image }), (ambiguous, { image }), (ambiguous, { image })]
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(reader(exact), image)
        XCTAssertNil(reader(ambiguous))
        XCTAssertNil(reader(URL(fileURLWithPath: "/other/Collection/First.m4a")))
        XCTAssertEqual(reads, 1)
        XCTAssertNil(ArtworkAcquisition.musicReader(snapshot: { [] })(exact))
    }

    func testSwitchingCatalogsDoesNotAttachUnrelatedRetainedImages() throws {
        let fixture = try Self.fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        try store.save(LocalCatalog(id: "previous", name: "Previous", entries: [], organization: fixture.organization))
        var next = fixture.organization
        next.artwork?.assets.removeValue(forKey: fixture.red)
        try store.save(LocalCatalog(id: "next", name: "Next", entries: [], organization: next))
        let reopened = try XCTUnwrap(store.load())
        XCTAssertEqual(reopened.id, "next")
        XCTAssertEqual(Set(reopened.organization?.artwork?.assets.keys.map { $0 } ?? []), [fixture.blue])
    }

}
