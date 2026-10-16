import Foundation
import SQLite3
import Testing
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct LibraryPresentationTests {
    @Test
    func multipleAlbumsCanBeHiddenTogetherAndRestoredAfterReopening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = ["First", "Second", "Third"].enumerated().map { index, title in
            LocalEntry(track: Track(id: title, title: "Song", artist: "Artist", album: title, suffix: "mp3", size: 4),
                       sha256: String(repeating: String(index + 1), count: 64), artwork: nil)
        }
        let store = LocalMusicStore(root: root)
        let library = Library(localStore: store)
        defer { library.closeLibrary() }
        try library.openLocal(LocalCatalog(id: "fixture", name: "Fixture", entries: entries))
        let selected = Set(library.albums.filter { $0.title != "Third" }.map(\.id))
        library.queue = library.tracks
        let save = library.setAlbumsHidden(selected, hidden: true)
        #expect(selected.allSatisfy(library.isSavingAlbumVisibility))
        await save.value
        #expect(!selected.contains(where: library.isSavingAlbumVisibility))
        #expect(library.message == nil)
        #expect(library.visibleAlbums.map(\.title) == ["Third"])
        #expect(Set(library.hiddenAlbums.map(\.title)) == ["First", "Second"])
        #expect(library.queue.count == 3)

        let reopened = Library(localStore: store)
        defer { reopened.closeLibrary() }
        let saved = try store.load()
        try reopened.openLocal(try #require(saved))
        reopened.navigate(.hiddenAlbums)
        #expect(Set(reopened.visibleAlbums.map(\.id)) == selected)
        await reopened.setAlbumsHidden(selected, hidden: false).value
        #expect(reopened.visibleAlbums.isEmpty)
        reopened.navigate(.albums)
        #expect(reopened.visibleAlbums.map(\.title) == ["First", "Second", "Third"])
    }

#if os(macOS)
    @Test
    func albumSortingUsesNaturalOrderAndSecondaryFieldWithoutChangingQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(localStore: LocalMusicStore(root: root))
        defer { library.closeLibrary() }
        library.tracks = [
            Track(id: "ten", title: "Song", artist: "B", album: "Album 10"),
            Track(id: "two-b", title: "Song", artist: "B", album: "Album 2"),
            Track(id: "two-a", title: "Song", artist: "A", album: "Album 2"),
            Track(id: "one-b", title: "Song", artist: "B", album: "Album 1")
        ]
        library.queue = library.tracks
        #expect(library.visibleAlbums.map { $0.tracks[0].id } == ["one-b", "two-a", "two-b", "ten"])
        library.albumSortField = .artist
        #expect(library.visibleAlbums.map { $0.tracks[0].id } == ["two-a", "one-b", "two-b", "ten"])
        library.albumSortDescending = true
        #expect(library.visibleAlbums.map { $0.tracks[0].id } == ["ten", "two-b", "one-b", "two-a"])
        library.albumSortField = .title
        #expect(library.visibleAlbums.map { $0.tracks[0].id } == ["ten", "two-b", "two-a", "one-b"])
        library.search = "Album 2"
        #expect(library.visibleAlbums.map { $0.tracks[0].id } == ["two-b", "two-a"])
        #expect(library.queue.map(\.id) == ["ten", "two-b", "two-a", "one-b"])
    }
#endif

    @Test
    func closingLibraryDuringVisibilitySaveDoesNotReopenIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        let library = Library(localStore: store)
        let entry = LocalEntry(track: Track(id: "one", title: "Song", artist: "Artist", album: "Album", suffix: "mp3", size: 4),
                               sha256: String(repeating: "a", count: 64), artwork: nil)
        try library.openLocal(LocalCatalog(id: "fixture", name: "Fixture", entries: [entry]))
        let album = try #require(library.albums.first)
        var connection: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &connection) == SQLITE_OK)
        let writer = try #require(connection)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let save = library.setAlbumHidden(album.id, hidden: true)
        #expect(library.isSavingAlbumVisibility(album.id))
        let pulseStart = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(50))
        #expect(ProcessInfo.processInfo.systemUptime - pulseStart < 0.5)
        #expect(library.hiddenAlbums.isEmpty)
        library.closeLibrary()
        #expect(sqlite3_exec(writer, "COMMIT", nil, nil, nil) == SQLITE_OK)
        await save.value
        #expect(!library.connected)
        #expect(library.albums.isEmpty)
        #expect(library.hiddenAlbums.isEmpty)
        #expect(library.message == nil)
        #expect(!library.isSavingAlbumVisibility(album.id))
    }

    @Test
    func failedVisibilitySaveKeepsTheDisplayedAlbum() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        let library = Library(localStore: store)
        defer { library.closeLibrary() }
        let entry = LocalEntry(track: Track(id: "one", title: "Song", artist: "Artist", album: "Album", suffix: "mp3", size: 4),
                               sha256: String(repeating: "a", count: 64), artwork: nil)
        try library.openLocal(LocalCatalog(id: "fixture", name: "Fixture", entries: [entry]))
        let album = try #require(library.albums.first)
        try store.save(LocalCatalog(id: "replacement", name: "Replacement", entries: []))
        await library.setAlbumHidden(album.id, hidden: true).value
        #expect(library.message != nil)
        #expect(library.albums.map(\.id) == [album.id])
        #expect(library.hiddenAlbums.isEmpty)
        #expect(try store.load()?.id == "replacement")
        #expect(!library.isSavingAlbumVisibility(album.id))
    }

    @Test
    func hiddenAlbumsLeaveCatalogButKeepAudioQueueAndRestoreAfterReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = LocalEntry(track: Track(id: "one", title: "Song", artist: "Artist", album: "Album", suffix: "mp3", size: 4), sha256: String(repeating: "a", count: 64), artwork: nil)
        let store = LocalMusicStore(root: root)
        let library = Library(localStore: store)
        try library.openLocal(LocalCatalog(id: "fixture", name: "Fixture", entries: [entry]))
        let album = try #require(library.albums.first)
        library.queue = album.tracks
        await library.setAlbumHidden(album.id, hidden: true).value
        #expect(library.message == nil)
        #expect(library.albums.isEmpty)
        #expect(library.artists.isEmpty)
        #expect(library.catalogTracks.isEmpty)
        #expect(library.tracks(for: "Artist").isEmpty)
        #expect(library.queue.map(\.id) == ["one"])
        #expect(library.tracks.count == 1)
        library.search = "Song"
        #expect(library.visibleTracks.isEmpty)
        library.search = ""
        library.navigate(.hiddenAlbums)
        #expect(library.visibleAlbums.map(\.id) == [album.id])
        let reopened = Library(localStore: store)
        let saved = try store.load()
        try reopened.openLocal(try #require(saved))
        #expect(reopened.hiddenAlbums.map(\.id) == [album.id])
        await reopened.setAlbumHidden(album.id, hidden: false).value
        #expect(reopened.albums.map(\.id) == [album.id])
        #expect(reopened.hiddenAlbums.isEmpty)
        #expect(reopened.catalogTracks.map(\.id) == ["one"])
        library.closeLibrary()
        reopened.closeLibrary()
    }

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
    func testSelectionAndPlaybackUpdatesBrowseRetainedCatalogWithoutBlocking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let images = try AlbumArtworkTests.fixture()
        var organization = AlbumOrganization()
        organization.artwork = AlbumArtwork(assets: [images.blue: try #require(images.organization.artwork?.assets[images.blue])])
        var entries: [LocalEntry] = []
        for number in 0..<2000 {
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
            #expect(library.albums.count == 200)
            #expect(library.visibleTracks.count == 10)
            #expect(library.artists.count == 200)
            #expect(library.albums.first?.coverArt == images.blue)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.2,
                "Warm browsing must not rebuild the catalog for selection or playback updates")
        let hideStart = ProcessInfo.processInfo.systemUptime
        let hiding = library.setAlbumHidden("album-0", hidden: true)
        let hideDuration = ProcessInfo.processInfo.systemUptime - hideStart
        print("Visibility action main-actor time: \(hideDuration)s")
        #expect(hideDuration < 0.1, "Hiding an album must return control to the UI promptly")
        #expect(library.albums.count == 200)
        library.position = 12
        library.selectedAlbum = "album-1"
        let restoring = library.setAlbumHidden("album-0", hidden: false)
        let hidingAnother = library.setAlbumHidden("album-1", hidden: true)
        let pulseStart = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(10))
        #expect(ProcessInfo.processInfo.systemUptime - pulseStart < 0.2,
                "The main actor must remain responsive while visibility is saved")
        await hiding.value
        await restoring.value
        await hidingAnother.value
        #expect(library.message == nil)
        #expect(library.position == 12)
        #expect(library.albums.count == 199)
        #expect(library.hiddenAlbums.map(\.id) == ["album-1"])
        let saved = try #require(try library.localStore.load())
        #expect(saved.organization?.isHidden("album-0") == false)
        #expect(saved.organization?.isHidden("album-1") == true)
        library.closeLibrary()
    }
}
