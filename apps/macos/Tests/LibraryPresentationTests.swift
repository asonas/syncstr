import Foundation
import Testing
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct LibraryPresentationTests {
    @Test
    func testCatalogAndOrganizationUpdatesRefreshAlbumsArtistsAndArtwork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = try AlbumArtworkTests.fixture()
        let blue = try #require(images.organization.artwork?.assets[images.blue])
        let red = try #require(images.organization.artwork?.assets[images.red])
        let first = LocalEntry(track: Track(id: "one", title: "First disc", artist: "B", album: "Collection", track: 9, discNumber: 1, suffix: "mp3", size: 4),
                               sha256: String(repeating: "a", count: 64), artwork: nil,
                               importedAlbum: ImportedAlbumMetadata(title: "Collection", artist: "B", albumArtist: nil, compilationValues: ["1"], release: nil))
        let second = LocalEntry(track: Track(id: "two", title: "Second disc", artist: "A", album: "Collection", track: 1, discNumber: 2, suffix: "mp3", size: 4),
                                sha256: String(repeating: "b", count: 64), artwork: nil,
                                importedAlbum: ImportedAlbumMetadata(title: "Collection", artist: "A", albumArtist: nil, compilationValues: ["1"], release: nil))
        var catalog = LocalCatalog(id: "fixture", name: "Fixture", entries: [second, first])
        catalog.organize(folders: ["one": "Collection", "two": "Collection"])
        try catalog.organization?.captureArtwork(blue, track: "one", source: "music", context: first.sha256)
        try catalog.organization?.captureArtwork(red, track: "two", source: "embedded", context: second.sha256)
        let library = Library(localStore: LocalMusicStore(root: root))
        try library.openLocal(catalog)
        let album = try #require(library.albums.first)
        #expect(library.albums.count == 1)
        #expect(album.tracks.map(\.id) == ["one", "two"])
        #expect(album.artist == "B、A")
        #expect(album.coverArt == images.red)
        #expect(library.album(id: album.id)?.tracks.map(\.id) == ["one", "two"])
        #expect(library.albums(for: "B").map(\.id) == [album.id])
        #expect(library.tracks(for: "A").map(\.id) == ["two"])

        var organization = try #require(library.localCatalog?.organization)
        try organization.chooseArtwork(blue, album: album.id)
        try library.saveOrganization(organization)
        #expect(library.album(id: album.id)?.coverArt == images.blue)
        organization.set(subject: album.id, kind: "artwork", value: nil)
        try library.saveOrganization(organization)
        #expect(library.album(id: album.id)?.coverArt == images.red)

        var replacement = first
        replacement.track = Track(id: "one", title: "Renamed track", artist: "C", album: "Renamed album", suffix: "mp3", size: 4)
        replacement.importedAlbum = ImportedAlbumMetadata(title: "Renamed album", artist: "C", albumArtist: "Album artist", compilationValues: [], release: nil)
        try library.openLocal(LocalCatalog(id: "fixture", name: "Fixture", entries: [replacement]))
        #expect(library.albums.count == 1)
        #expect(library.albums.first?.title == "Renamed album")
        #expect(library.albums.first?.artist == "Album artist")
        #expect(library.artists == ["C"])
        #expect(library.albums(for: "B").isEmpty)
        #expect(library.tracks(for: "A").isEmpty)
        #expect(library.album(id: album.id) == nil)
        library.closeLibrary()
        #expect(library.albums.isEmpty)
        #expect(library.artists.isEmpty)
        #expect(library.tracks(for: "C").isEmpty)
    }

    @Test
    func testSelectionAndPlaybackUpdatesBrowseRetainedCatalogWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = try AlbumArtworkTests.fixture()
        var organization = AlbumOrganization()
        organization.artwork = AlbumArtwork(assets: [images.blue: try #require(images.organization.artwork?.assets[images.blue])])
        var entries: [LocalEntry] = []
        for number in 0..<200 {
            let id = "track-\(number)"
            let album = "album-\(number / 10)"
            let metadata = ImportedAlbumMetadata(title: album, artist: "Artist \(number / 10)", albumArtist: nil, compilationValues: [], release: nil)
            let track = Track(id: id, title: "Track \(number)", artist: metadata.artist, album: album,
                              albumId: album, track: number % 10, suffix: "mp3", size: 4)
            entries.append(LocalEntry(track: track, sha256: String(repeating: "a", count: 64), artwork: nil, importedAlbum: metadata))
            organization.tracks.append(OrganizationTrack(id: id, sha256: String(repeating: "a", count: 64), imported: metadata, importedAlbumID: album))
            if number % 10 == 0 { organization.albums.append(OrganizationAlbum(id: album, title: album)) }
            organization.artwork?.candidates.append(ArtworkCandidate(id: id, track: id, source: "embedded", context: "file", asset: images.blue, parents: []))
        }
        let library = Library(localStore: LocalMusicStore(root: root))
        try library.openLocal(LocalCatalog(id: "fixture", name: "Fixture", entries: entries, organization: organization))
        let start = ProcessInfo.processInfo.systemUptime
        for number in 0..<3 {
            library.selectedAlbum = "album-\(number)"
            library.position = Double(number)
            #expect(library.albums.count == 20)
            #expect(library.visibleTracks.count == 10)
            #expect(library.artists.count == 20)
            #expect(library.albums.first?.coverArt == images.blue)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.2,
                "Warm browsing must not rebuild the catalog for selection or playback updates")
        library.closeLibrary()
    }
}
