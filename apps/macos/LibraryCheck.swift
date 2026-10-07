import AVFoundation
import Foundation
import AudioTags

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

    static func silence(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32000)!
        buffer.frameLength = 32000
        buffer.floatChannelData!.pointee.initialize(repeating: 0, count: 32000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @MainActor
    static func stableAlbumOrder() throws {
        let library = Library()
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
        try stableAlbumOrder()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["First", "Second", "Third"] { try silence(at: folder.appendingPathComponent(name + ".wav")) }
        try AudioTags.writeFile(folder.appendingPathComponent("First.wav"), fields: ["TITLE": "First", "ARTIST": "Artist A", "ALBUM": "Album A", "TRACKNUMBER": "1"], artwork: nil, mimeType: nil, changeArtwork: false)
        try AudioTags.writeFile(folder.appendingPathComponent("Second.wav"), fields: ["TITLE": "Second", "ARTIST": "Artist A", "ALBUM": "Album A", "TRACKNUMBER": "2"], artwork: nil, mimeType: nil, changeArtwork: false)
        try AudioTags.writeFile(folder.appendingPathComponent("Third.wav"), fields: ["TITLE": "Third", "ARTIST": "Artist B", "ALBUM": "Album B", "TRACKNUMBER": "1"], artwork: nil, mimeType: nil, changeArtwork: false)
        var mediaPlayers: [AVPlayer] = []
        let secrets = CredentialStore(service: "syncstr-library-check-" + UUID().uuidString)
        let localFiles = LocalMusicStore(root: folder.appendingPathComponent("local"))
        let library = Library(makePlayer: { url in
            let player = AVPlayer(url: url)
            player.isMuted = true
            mediaPlayers.append(player)
            return player
        }, localStore: localFiles, pairingSecrets: secrets)
        await library.restoreLibrary()
        try require(!library.connected && !library.restoringSession)
        await library.chooseFolder(folder)
        try require(library.connected && library.tracks.count == 3 && library.message == nil)
        let reopened = Library(localStore: localFiles, pairingSecrets: secrets)
        await reopened.restoreLibrary()
        try require(reopened.connected && reopened.tracks.count == 3 && !reopened.restoringSession)
        reopened.closeLibrary()
        await library.chooseFolder(folder)
        print("PASS: selected folder and catalog restore without a server account")

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
        try require(!library.canGoPrevious && library.canGoNext)
        library.navigate(.artists)
        library.next()
        try require(library.current?.title == "Second")
        try require(library.canGoPrevious && !library.canGoNext)
        try await wait("Second track did not play") { library.playing && library.position > 0 }
        library.togglePlayback(in: albumTracks)
        try await wait("Album pause failed") { !library.playing && !library.loading }
        let pausedPlayer = mediaPlayers.last!
        let pausedPosition = pausedPlayer.currentTime().seconds
        library.togglePlayback(in: albumTracks)
        try await wait("Album resume failed") { library.playing }
        try require(library.current?.title == "Second" && library.queue.map(\.title) == ["First", "Second"])
        try require(mediaPlayers.last! === pausedPlayer && pausedPlayer.currentTime().seconds >= pausedPosition)
        print("PASS: album action starts, switches albums, pauses and resumes without replacing the queue")
        library.previous()
        try require(library.current?.title == "First")
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
        library.closeLibrary()
        try require(!library.connected && library.current == nil && library.queue.isEmpty)
        try require(mediaPlayers.allSatisfy { $0.rate == 0 })
        try require(localFiles.load()?.entries.count == 3)
        print("PASS: real AVPlayer advances, stops, restarts, and releases playback on library closure")
    }
}
