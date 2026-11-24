import AVFoundation
import Foundation

struct CheckFailure: Error {
    let message: String
}

@main
struct LibraryCheck {
    static func require(_ condition: Bool, line: UInt = #line) throws {
        if !condition { throw CheckFailure(message: "Assertion failed at line \(line)") }
    }

    @MainActor
    static func wait(_ description: String, until condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CheckFailure(message: description)
    }

    /// The fixture tracks are about 4 seconds long, so a wrap could come from playing to the end.
    /// Pause first and require the same player to reach the target, so a seek that does nothing fails.
    /// pause() and resumePlayback() are explicit because togglePlayback() pauses while playback is only wanted.
    @MainActor
    static func seekNearEnd(_ library: Library, player: () -> AVPlayer) async throws {
        try await wait("Track was not ready to seek") { library.canSeek }
        library.pause()
        try await wait("Pause before seeking failed") { !library.playing }
        let seeking = player()
        library.seek(to: 3.5)
        try await wait("Seek did not reach the target") { player() === seeking && abs(seeking.currentTime().seconds - 3.5) < 0.2 }
        library.resumePlayback()
        try await wait("Playback did not resume after seeking") { library.playing }
    }

    static func silence(at url: URL, frames: AVAudioFrameCount) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData!.pointee.initialize(repeating: 0, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Saves a disconnected host's catalog with every track pinned, as a device keeps it for offline playback.
    static func saveRetainedHostLibrary(in store: LocalMusicStore, audio folder: URL) throws {
        try store.prepare()
        let tracks = [
            Track(id: "first", title: "First", artist: "Artist A", album: "Album A", albumId: "album-a", track: 1, suffix: "wav"),
            Track(id: "second", title: "Second", artist: "Artist A", album: "Album A", albumId: "album-a", track: 2, suffix: "wav"),
            Track(id: "third", title: "Third", artist: "Artist B", album: "Album B", albumId: "album-b", track: 1, suffix: "wav")
        ]
        var entries: [LocalEntry] = []
        for (index, var track) in tracks.enumerated() {
            // Distinct lengths keep the content hashes, and so the saved files, apart.
            let source = folder.appendingPathComponent(track.title + ".wav")
            try silence(at: source, frames: 32000 + AVAudioFrameCount(index) * 800)
            track.size = UInt64(try Data(contentsOf: source).count)
            let entry = LocalEntry(track: track, sha256: try LocalMusicStore.digest(file: source), artwork: nil)
            try FileManager.default.copyItem(at: source, to: store.fileURL(entry))
            entries.append(entry)
        }
        let database = try store.database()
        let catalog = LocalCatalog(id: "check-library", name: "Check", entries: entries, source: .host)
        let host = try HostConnection(address: HostAddress("https://music.example.test"), library: catalog.id, name: catalog.name, hosts: [])
        try database.saveHostCatalog(CatalogUpdate(catalog: catalog, etag: "check"), connection: host, replacing: nil)
        for entry in entries { try database.saveAudioPin(entry) }
        _ = try database.forgetHost()
    }

    @MainActor
    static func stableAlbumOrder(in folder: URL) throws {
        let library = Library(localStore: LocalMusicStore(root: folder.appendingPathComponent("order")))
        let tracks = [
            Track(id: "c", title: "Third", artist: "Artist B", album: "Unknown Album", albumId: "album-c"),
            Track(id: "b", title: "Second", artist: "Artist A", album: "Unknown Album", albumId: "album-b"),
            Track(id: "a", title: "First", artist: "Artist A", album: "Unknown Album", albumId: "album-a")
        ]
        library.tracks = tracks
        let initialOrder = library.visibleAlbums.map(\.id)
        for tick in 0..<128 {
            library.position = Double(tick)
            library.playing = tick.isMultiple(of: 2)
            library.current = tracks[tick % tracks.count]
            if tick == 64 { library.tracks.reverse() }
            let order = library.visibleAlbums.map(\.id)
            guard order == initialOrder else {
                throw CheckFailure(message: "Same-title album order changed at playback tick \(tick): \(order)")
            }
        }
        try require(initialOrder == ["album-a", "album-b", "album-c"])
        print("PASS: same-title albums retain artist/ID order through playback updates and reversed input")
    }

    @MainActor
    static func main() async throws {
        // Every Library here gets a store in this folder; the default store is the person's real library.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try stableAlbumOrder(in: folder)
        let unset = [Track(id: "unset-a", title: "First", artist: nil, album: nil, albumId: "unset-a"),
                     Track(id: "unset-b", title: "Second", artist: nil, album: "", albumId: "unset-b")]
        let unsetLibrary = Library(localStore: LocalMusicStore(root: folder.appendingPathComponent("unset")))
        unsetLibrary.tracks = unset
        try require(unsetLibrary.albums.count == 2)
        try require(unsetLibrary.albums.map(\.title) == ["First", "Second"])
        try require(unsetLibrary.tracks == unset)
        var mediaPlayers: [AVPlayer] = []
        let localFiles = LocalMusicStore(root: folder.appendingPathComponent("local"))
        try saveRetainedHostLibrary(in: localFiles, audio: folder)
        let library = Library(makePlayer: { url in
            let player = AVPlayer(url: url)
            player.isMuted = true
            mediaPlayers.append(player)
            return player
        }, localStore: localFiles)
        await library.restoreLibrary()
        try require(library.connected && library.tracks.count == 3 && library.message == nil && !library.restoringSession)
        try require(library.transfer.retainsHostCatalog)
        print("PASS: a saved host catalog restores without a connection")

        try require(library.destination == .albums)
        try require(library.albums.map(\.title) == ["Album A", "Album B"])
        library.search = "Album B"
        try require(library.visibleAlbums.map(\.title) == ["Album B"])
        library.search = "Artist A"
        try require(library.visibleAlbums.map(\.title) == ["Album A"])
        try require(library.artists == ["Artist A"])
        library.search = "Third"
        try require(library.visibleAlbums.isEmpty)
        try require(library.artists.isEmpty)
        library.search = ""
        let albumTracks = library.albums[0].tracks
        try require(albumTracks.map(\.title) == ["First", "Second"])
        library.selectedAlbum = library.albums[0].id
        library.search = "Third"
        try require(library.visibleTracks.map(\.title) == ["Third"])
        library.search = ""
        library.togglePlayback(in: [])
        try require(library.current == nil)
        library.togglePlayback(in: library.albums[1].tracks)
        try await wait("Other album did not play") { library.playing }
        library.togglePlayback(in: albumTracks)
        try await wait("First track did not play") { library.playing && library.position > 0 }
        print("PASS: saved host audio plays offline")
        try require(library.canGoPrevious && library.canGoNext)
        library.navigate(.artists)
        library.next()
        try require(library.current?.title == "Second")
        try require(library.canGoPrevious && !library.canGoNext)
        try await wait("Second track did not play") { library.playing && library.position > 0 }
        library.pause()
        try await wait("Album pause failed") { !library.playing && !library.loading }
        let pausedPlayer = mediaPlayers.last!
        let pausedPosition = pausedPlayer.currentTime().seconds
        library.resumePlayback()
        try await wait("Album resume failed") { library.playing }
        try require(library.current?.title == "Second" && library.queue.map(\.title) == ["First", "Second"])
        try require(mediaPlayers.last! === pausedPlayer && pausedPlayer.currentTime().seconds >= pausedPosition)
        print("PASS: album actions start playback; player pause/resume preserves position and queue")
        library.setShuffle(true)
        try require(library.queue.map(\.title) == ["First", "Second"])
        try require(mediaPlayers.last! === pausedPlayer && library.current?.title == "Second")
        library.setShuffle(false)
        try require(library.queue.map(\.title) == ["First", "Second"])
        library.setVolume(0.4)
        try require(abs(mediaPlayers.last!.volume - 0.4) < 0.001)
        library.previous()
        try require(library.current?.title == "First")
        try require(abs(mediaPlayers.last!.volume - 0.4) < 0.001)
        try await wait("Previous track did not play") { library.playing && library.position > 0 }
        library.togglePlayback()
        try await wait("Pause failed") { !library.playing }
        library.seek(to: 2)
        try await wait("Seek failed") { abs(mediaPlayers.last!.currentTime().seconds - 2) < 0.2 }
        try require(!library.playing)
        print("PASS: album order, global search, navigation, previous/next and paused seek")

        library.togglePlayback()
        try await wait("Did not advance at track end") { library.current?.title == "Second" }
        try await wait("Last track did not stop") { !library.playing && library.position >= 3.8 }
        try require(library.current?.title == "Second" && !library.canGoNext)
        library.togglePlayback()
        try await wait("Last track did not restart") { library.playing && library.position < 2 }
        library.setVolume(-1)
        try require(library.volume == 0 && mediaPlayers.last!.volume == 0)
        library.setVolume(2)
        try require(library.volume == 1 && mediaPlayers.last!.volume == 1)
        library.setVolume(.nan)
        try require(library.volume == 1)
        library.repeatMode = .all
        library.next()
        try require(library.current?.title == "First")
        library.previous()
        try require(library.current?.title == "Second")
        try await seekNearEnd(library, player: { mediaPlayers.last! })
        try await wait("Repeat all did not wrap at track end") { library.current?.title == "First" }
        library.repeatMode = .one
        try await seekNearEnd(library, player: { mediaPlayers.last! })
        let repeatedPlayer = mediaPlayers.last!
        try await wait("Repeat one did not restart") { mediaPlayers.last! !== repeatedPlayer }
        try require(library.current?.title == "First" && library.queue.map(\.title) == ["First", "Second"])
        library.repeatMode = .off
        print("PASS: shuffle preserves the player and restores order; repeat all/one follow real track endings; volume clamps and survives track changes")
        library.closeLibrary()
        try require(!library.connected && library.current == nil && library.queue.isEmpty)
        try require(mediaPlayers.allSatisfy { $0.rate == 0 })
        try require(localFiles.load()?.entries.count == 3)
        print("PASS: real AVPlayer advances, stops, restarts, and releases playback on library closure")
    }
}
