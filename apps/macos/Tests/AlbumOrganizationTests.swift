import Foundation
import XCTest
#if os(iOS)
@testable import Syncstr
#else
import AudioTags
#endif

final class AlbumOrganizationTests: XCTestCase {
    func testConcurrentVisibilityConvergesAndExplicitUnhideSupersedesBoth() throws {
        var base = AlbumOrganization()
        base.importEntries([entry("one", artist: "A", release: "edition")])
        let album = try XCTUnwrap(base.albumID(for: "one"))
        var hidden = base
        var visible = base
        hidden.set(subject: album, kind: "visibility", value: "true")
        visible.set(subject: album, kind: "visibility", value: "false")
        let otherOrder = hidden
        try hidden.merge(visible)
        try visible.merge(otherOrder)
        XCTAssertTrue(hidden.isHidden(album))
        XCTAssertTrue(visible.isHidden(album))
        visible.set(subject: album, kind: "visibility", value: "false")
        try hidden.merge(visible)
        XCTAssertFalse(hidden.isHidden(album))
        XCTAssertFalse(try hidden.forClusterObject(hidden.tracks[0].sha256).isHidden(album))
        try hidden.validate()
    }

    func testReleaseReconciliationDoesNotInventClassificationRevisions() throws {
        var local = AlbumOrganization()
        local.importEntries([entry("one", artist: "A", release: "edition")])
        local.set(subject: try XCTUnwrap(local.albumID(for: "one")), kind: "classification", value: "true")
        var incoming = AlbumOrganization()
        var second = entry("two", artist: "B", release: "edition")
        second.sha256 = String(repeating: "b", count: 64)
        incoming.importEntries([second])
        let choices = local.choices
        try local.merge(incoming)
        XCTAssertEqual(local.albumID(for: "one"), local.albumID(for: "two"))
        XCTAssertEqual(local.choices, choices)
    }

    func testProposalsStayWithinSourceAndRememberSeparationAfterMoreTracksArrive() throws {
        var organization = AlbumOrganization()
        organization.importEntries([entry("one", artist: "A"), entry("two", artist: "B")], folders: ["one": "Collection/Disc 1", "two": "Collection/Disc 2"], sourceID: "source-a")
        organization.importEntries([entry("other", artist: "C")], folders: ["other": "Collection/Disc 1"], sourceID: "unrelated-source")
        let proposal = try XCTUnwrap(organization.proposals.first)
        XCTAssertEqual(proposal.count, 2)
        XCTAssertEqual(organization.proposals.count, 1)
        organization.set(subject: proposal.map(\.id).sorted().joined(separator: ","), kind: "proposal", value: "separate")
        organization.importEntries([entry("three", artist: "D")], folders: ["three": "Collection/Disc 3"], sourceID: "source-a")
        XCTAssertTrue(organization.proposals.isEmpty)
        let reopened = try JSONDecoder().decode(AlbumOrganization.self, from: JSONEncoder().encode(organization))
        XCTAssertTrue(reopened.proposals.isEmpty)
    }

    func testSharedMembershipCasesAndReorderedEvidence() throws {
        struct Fixture: Decodable { var name: String; var organization: AlbumOrganization; var groups: [[String]] }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "compilation-membership", withExtension: "json"))
        for fixture in try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: file)) {
            for reversed in [false, true] {
                var organization = fixture.organization
                if reversed { organization.tracks.reverse(); organization.albums.reverse() }
                organization.repairMembership()
                try organization.validate()
                let groups = Dictionary(grouping: organization.tracks, by: { organization.albumID(for: $0.id)! }).values.map { $0.map(\.id).sorted() }
                XCTAssertEqual(Set(groups), Set(fixture.groups.map { $0.sorted() }), fixture.name)
                XCTAssertEqual(organization.choices, fixture.organization.choices, fixture.name)
                let repaired = organization
                organization.repairMembership()
                XCTAssertEqual(organization, repaired, fixture.name)
            }
        }
    }

    func testLaterDiscKeepsIdentityAndLateContradictionWithdrawsOnlyAutomaticLinks() throws {
        var one = entry("one", artist: "A", compilation: ["1"])
        one.track.discNumber = 1
        var catalog = LocalCatalog(id: "source", name: "Collection", entries: [one])
        catalog.organize(folders: ["one": "Collection/Disc 1"])
        let original = catalog.organization?.albumID(for: "one")
        var two = entry("two", artist: "B")
        two.track.discNumber = 2
        catalog.entries.append(two)
        catalog.organize(folders: ["one": "Collection/Disc 1", "two": "Collection/Disc 2"])
        XCTAssertEqual(catalog.organization?.albumID(for: "two"), original)
        XCTAssertTrue(catalog.organization?.aliases.isEmpty == true)
        let merged = catalog.organization
        catalog.entries = []
        catalog.organize()
        XCTAssertEqual(catalog.organization, merged, "Unavailable audio retains its evidence")
        two.importedAlbum?.compilationValues = ["0"]
        catalog.entries = [two]
        catalog.organize(folders: ["two": "Moved"])
        XCTAssertNotEqual(catalog.organization?.albumID(for: "two"), original)
        XCTAssertEqual(catalog.organization?.tracks.first { $0.id == "two" }?.importContext?.folder, "Collection/Disc 2")
        XCTAssertTrue(catalog.organization?.choices.isEmpty == true)
        try catalog.organization?.validate()
    }

    func testClassificationHistorySurvivesAutomaticMergeAndReassessment() throws {
        var catalog = LocalCatalog(id: "source", name: "Collection", entries: [entry("one", artist: "A", compilation: ["1"]), entry("two", artist: "B")])
        catalog.organize(folders: ["one": "Collection", "two": "Collection"])
        let album = try XCTUnwrap(catalog.organization?.albumID(for: "one"))
        catalog.organization?.set(subject: album, kind: "classification", value: "true")
        catalog.organization?.set(subject: album, kind: "classification", value: nil)
        catalog.entries[1].importedAlbum?.compilationValues = ["0"]
        catalog.organize()
        XCTAssertNotEqual(catalog.organization?.albumID(for: "one"), catalog.organization?.albumID(for: "two"))
        try catalog.organization?.validate()
        let reopened = try JSONDecoder().decode(AlbumOrganization.self, from: JSONEncoder().encode(catalog.organization!))
        try reopened.validate()
        XCTAssertEqual(reopened.choices, catalog.organization?.choices)
    }

    func testLaterDiscFromPeerKeepsEstablishedAlbumID() throws {
        struct Fixture: Decodable { var name: String; var organization: AlbumOrganization }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "compilation-membership", withExtension: "json"))
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: file))
        let incoming = try XCTUnwrap(cases.first { $0.name == "sibling discs" }?.organization)
        var local = incoming
        local.albums.removeFirst()
        local.tracks.removeFirst()
        try local.merge(incoming)
        XCTAssertEqual(local.albumID(for: "track-01"), "album-02")
        XCTAssertEqual(local.albumID(for: "track-02"), "album-02")
        let merged = local
        try local.merge(incoming)
        XCTAssertEqual(local, merged)
    }

    func testRepairPersistsAcrossDatabaseReopenWithoutInventingCacheContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = [entry("one", artist: "A", compilation: ["1"]), entry("two", artist: "B")]
        let catalog = LocalCatalog(id: "source", name: "Collection", entries: entries)
        let url = root.appendingPathComponent("catalog.sqlite")
        try CatalogDatabase(url).save(catalog)
        let unavailable = try XCTUnwrap(CatalogDatabase(url).snapshot()?.catalog.organization)
        XCTAssertNotEqual(unavailable.albumID(for: "one"), unavailable.albumID(for: "two"))
        try CatalogDatabase(url).save(catalog, sourceRoot: root.appendingPathComponent("source"), sourcePaths: ["one": "Collection/one.mp3", "two": "Collection/two.mp3"])
        let repaired = try XCTUnwrap(CatalogDatabase(url).snapshot()?.catalog.organization)
        XCTAssertEqual(repaired.albumID(for: "one"), repaired.albumID(for: "two"))
        XCTAssertEqual(try CatalogDatabase(url).snapshot()?.catalog.organization, repaired)
    }

    func testLocalCompilationRepairsExistingSplitWithoutCreatingManualChoices() throws {
        let entries = [entry("one", artist: "A", compilation: ["1"]), entry("two", artist: "B")]
        var legacy = AlbumOrganization()
        legacy.importEntries(entries)
        let former = legacy.albums.map(\.id)
        var catalog = LocalCatalog(id: "import-a", name: "Music", entries: entries, organization: legacy)
        catalog.organize(folders: ["one": "Collection", "two": "Collection"])
        let organized = try XCTUnwrap(catalog.organization)
        XCTAssertEqual(organized.albumID(for: "one"), organized.albumID(for: "two"))
        XCTAssertTrue(organized.choices.isEmpty)
        XCTAssertEqual(Set(former.map(organized.canonical)).count, 1)
        XCTAssertNil(organized.tracks.first { $0.id == "two" }?.imported.compilation)
        catalog.organize(folders: ["one": "Collection", "two": "Collection"])
        XCTAssertEqual(catalog.organization, organized)
        try organized.validate()
    }
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
