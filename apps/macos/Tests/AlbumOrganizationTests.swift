import Foundation
import XCTest
#if os(iOS)
@testable import Syncstr
#else
import AudioTags
#endif

final class AlbumOrganizationTests: XCTestCase {
    func testOrganizationWireFixturePreservesNativeNamesAndClearRevision() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "album-organization", withExtension: "json"))
        let data = try Data(contentsOf: fixture)
        let organization = try JSONDecoder().decode(AlbumOrganization.self, from: data)
        try organization.validate()
        XCTAssertNil(organization.choice(subject: "album-a", kind: "classification")?.value)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(organization)) as? NSDictionary,
            try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
    private func entry(_ id: String, artist: String, release: String? = nil, compilation: [String] = []) -> LocalEntry {
        LocalEntry(track: Track(id: id, title: id, artist: artist, album: "Collection", suffix: "mp3", size: 3),
            sha256: String(repeating: "a", count: 64), artwork: nil,
            importedAlbum: ImportedAlbumMetadata(title: "Collection", artist: artist, albumArtist: nil,
                compilationValues: compilation, release: release.map { ReleaseIdentifier(source: "musicbrainz-release", value: $0) }))
    }

    func testReleaseGroupsArtistsAndDiscsWithoutFlatteningAssertions() throws {
        let entries = [entry("one", artist: "Artist A", release: "edition", compilation: ["1"]),
            entry("two", artist: "Artist B", release: "edition"),
            entry("deluxe", artist: "Artist A", release: "deluxe")]
        var organization = AlbumOrganization()
        organization.importEntries(entries)
        XCTAssertEqual(organization.albumID(for: "one"), organization.albumID(for: "two"))
        XCTAssertNotEqual(organization.albumID(for: "one"), organization.albumID(for: "deluxe"))
        XCTAssertEqual(organization.tracks[0].imported.compilation, true)
        XCTAssertNil(organization.tracks[1].imported.compilation)
        XCTAssertEqual(organization.artistCredit(for: Array(entries.prefix(2)).map(\.track)), "Artist A、Artist B")
        try organization.validate()
    }

    func testClearOverrideAndConcurrentPeerChoicesSurviveRestart() throws {
        var organization = AlbumOrganization()
        organization.importEntries([entry("one", artist: "Artist A")])
        let album = try XCTUnwrap(organization.albumID(for: "one"))
        organization.set(subject: album, kind: "classification", value: "true")
        let oldPeer = organization
        organization.set(subject: album, kind: "classification", value: nil)
        try organization.merge(oldPeer)
        XCTAssertNil(organization.choice(subject: album, kind: "classification")?.value)
        XCTAssertFalse(organization.hasConflict(subject: album, kind: "classification"))
        var peer = organization
        organization.set(subject: album, kind: "classification", value: "true")
        peer.set(subject: album, kind: "classification", value: "false")
        try organization.merge(peer)
        XCTAssertTrue(organization.hasConflict(subject: album, kind: "classification"))
        XCTAssertEqual(organization.choice(subject: album, kind: "classification")?.value, "true")
        let reopened = try JSONDecoder().decode(AlbumOrganization.self, from: JSONEncoder().encode(organization))
        XCTAssertEqual(reopened, organization)
        organization.set(subject: album, kind: "classification", value: "false")
        try organization.merge(peer)
        XCTAssertFalse(organization.hasConflict(subject: album, kind: "classification"))
        XCTAssertEqual(organization.choice(subject: album, kind: "classification")?.value, "false")
    }

    func testRescanKeepsUnavailableMembershipAndOriginalCredits() throws {
        var organization = AlbumOrganization()
        organization.importEntries([entry("one", artist: "Artist A"), entry("two", artist: "Artist B")])
        let ids = organization.albums.map(\.id)
        try organization.join(ids, confirmed: true)
        let album = organization.albumID(for: "two")
        var changed = entry("one", artist: "Artist C", compilation: ["0"])
        changed.importedAlbum?.title = "New title"
        organization.importEntries([changed])
        XCTAssertEqual(organization.albumID(for: "two"), album)
        XCTAssertEqual(organization.tracks.count, 2)
        XCTAssertEqual(organization.tracks[0].imported.artist, "Artist C")
        XCTAssertEqual(organization.canonical(ids[0]), organization.canonical(ids[1]))
        try organization.validate()
    }

    func testInvalidRevisionAndAliasCyclesAreRejected() throws {
        var organization = AlbumOrganization()
        organization.importEntries([entry("one", artist: "A")])
        organization.aliases = ["a": "b", "b": "a"]
        XCTAssertThrowsError(try organization.validate())
        organization.aliases = [:]
        organization.choices = [OrganizationChoice(id: "cycle", subject: "one", kind: "membership", value: nil, parents: ["cycle"])]
        XCTAssertThrowsError(try organization.validate())
    }

    func testLongSerialChoiceHistoryRemainsValid() throws {
        var organization = AlbumOrganization()
        organization.importEntries([entry("one", artist: "A")])
        let album = try XCTUnwrap(organization.albumID(for: "one"))
        for index in 0..<256 {
            organization.set(subject: album, kind: "classification", value: index.isMultiple(of: 2) ? "true" : nil)
        }
        try organization.validate()
        XCTAssertEqual(organization.heads(subject: album, kind: "classification").count, 1)
        XCTAssertNil(organization.choice(subject: album, kind: "classification")?.value)
    }

    func testIndependentReleaseAlbumsReconcileAndExplicitMembershipCanReturnToTags() throws {
        let releaseEntry = entry("one", artist: "A", release: "edition")
        var first = AlbumOrganization()
        first.importEntries([releaseEntry])
        var second = AlbumOrganization()
        second.importEntries([releaseEntry])
        let former = try XCTUnwrap(second.albumID(for: "one"))
        try first.merge(second)
        XCTAssertEqual(first.canonical(former), first.albumID(for: "one"))
        var third = AlbumOrganization()
        third.importEntries([releaseEntry])
        let thirdID = try XCTUnwrap(third.albumID(for: "one"))
        try third.merge(second)
        try first.merge(third)
        XCTAssertEqual(first.canonical(thirdID), first.albumID(for: "one"))
        try first.validate()

        var provisional = AlbumOrganization()
        provisional.importEntries([entry("one", artist: "A"), entry("two", artist: "B")])
        provisional.albums[0].id = "album-a"
        provisional.albums[1].id = "album-b"
        provisional.tracks[0].importedAlbumID = "album-a"
        provisional.tracks[1].importedAlbumID = "album-b"
        let ids = ["album-a", "album-b"]
        try provisional.join(ids, confirmed: true)
        let merged = provisional.albumID(for: "two")
        provisional.set(subject: "two", kind: "membership", value: nil)
        let restored = try XCTUnwrap(provisional.albumID(for: "two"))
        XCTAssertNotEqual(restored, merged)
        XCTAssertNil(provisional.choice(subject: "two", kind: "membership")?.value)
        try provisional.validate()
    }

    func testIncomingManualMergeKeepsCompetingLocalMembership() throws {
        var local = AlbumOrganization()
        local.importEntries([entry("one", artist: "A"), entry("two", artist: "B")])
        local.albums[0].id = "album-a"
        local.albums[1].id = "album-b"
        local.tracks[0].importedAlbumID = "album-a"
        local.tracks[1].importedAlbumID = "album-b"
        let original = try XCTUnwrap(local.albumID(for: "two"))
        var peer = local
        local.set(subject: "two", kind: "membership", value: original)
        try peer.join(peer.albums.map(\.id), confirmed: true)
        try local.merge(peer)
        XCTAssertEqual(local.albumID(for: "two"), original)
        XCTAssertTrue(local.hasConflict(subject: "two", kind: "membership"))
        XCTAssertEqual(local.heads(subject: "two", kind: "membership").count, 2)
    }

    func testStoredOrganizationKeepsUnavailableChoicesAndIDsAcrossReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        var catalog = LocalCatalog(id: "fixture-library", name: "Collection", entries: [entry("one", artist: "A")])
        catalog.organize()
        let album = try XCTUnwrap(catalog.organization?.albumID(for: "one"))
        catalog.organization?.set(subject: album, kind: "classification", value: "false")
        try store.save(catalog)
        catalog.entries = []
        try store.save(catalog)
        let reopened = try XCTUnwrap(LocalMusicStore(root: root).load())
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertEqual(reopened.organization?.albumID(for: "one"), album)
        XCTAssertEqual(reopened.organization?.choice(subject: album, kind: "classification")?.value, "false")
        catalog.entries = [entry("one", artist: "Updated credit")]
        try store.save(catalog)
        XCTAssertEqual(try store.load()?.organization?.tracks[0].imported.artist, "Updated credit")
        XCTAssertEqual(try store.load()?.organization?.albumID(for: "one"), album)
    }

#if os(macOS)
    func testPinnedTagReaderRetainsCompilationAlbumArtistAndEditionAcrossFormats() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for suffix in ["mp3", "flac", "m4a"] {
            let source = fixtureRoot.appendingPathComponent("untagged." + suffix)
            let copy = root.appendingPathComponent("tagged." + suffix)
            try FileManager.default.copyItem(at: source, to: copy)
            let original = try Data(contentsOf: source)
            try AudioTags.writeFile(copy, fields: ["ALBUM": "Collection", "ARTIST": "Artist A",
                "ALBUMARTIST": "Various Artists", "COMPILATION": "1",
                "MUSICBRAINZ_ALBUMID": "d72058b8-9814-4d5e-aee3-64de34d49c08"],
                artwork: nil, mimeType: nil, changeArtwork: false)
            let tags = try AudioTags.readFile(copy)
            XCTAssertEqual(tags["COMPILATION"] as? [String], ["1"], suffix)
            let imported = ImportedAlbumMetadata.read(tags)
            XCTAssertEqual(imported.albumArtist, "Various Artists", suffix)
            XCTAssertEqual(imported.compilation, true, suffix)
            XCTAssertEqual(imported.release?.value, "d72058b8-9814-4d5e-aee3-64de34d49c08", suffix)
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }
#endif
}
