import AVFoundation
import Foundation

final class LibraryFixtureProtocol: URLProtocol {
    static var reject = false
    static var searches = 0
    static var addTrackAfter = Int.max
    static var addSecondTrackAfter = Int.max
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url!.lastPathComponent == "download.view" {
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "id" }!.value!
            let data = Data((id == "uploaded" ? "abc" : (id == "uploaded-two" ? "def" : "bad")).utf8)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let payload: [String: Any]
        if Self.reject {
            payload = ["status": "failed", "error": ["code": 40]]
        } else if request.url!.lastPathComponent == "ping.view" {
            payload = ["status": "ok"]
        } else {
            Self.searches += 1
            var songs: [[String: Any]] = [
                ["id": "second", "title": "Second", "artist": "Artist A", "album": "Album A", "albumId": "album-a", "track": 2, "duration": 4],
                ["id": "first", "title": "First", "artist": "Artist A", "album": "Album A", "albumId": "album-a", "track": 1, "duration": 4],
                ["id": "third", "title": "Third", "artist": "Artist B", "album": "Album B", "albumId": "album-b", "track": 1, "duration": 4]
            ]
            if Self.addTrackAfter != Int.max { songs.append(["id": "unrelated", "title": "Unrelated", "size": 3]) }
            if Self.searches >= Self.addTrackAfter { songs.append(["id": "uploaded", "title": "Uploaded", "size": 3]) }
            if Self.searches >= Self.addSecondTrackAfter { songs.append(["id": "uploaded-two", "title": "Uploaded Two", "size": 3]) }
            if Self.searches % 2 == 0 { songs.reverse() }
            payload = ["status": "ok", "searchResult3": ["song": songs]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["subsonic-response": payload])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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
    static func main() async throws {
        let service = "as.ason.syncstr.test." + UUID().uuidString
        let store = CredentialStore(service: service)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("silence.wav")
        try silence(at: audio)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var mediaPlayers: [AVPlayer] = []
        var pollingDelays: [Duration] = []
        var holdPolling = false
        var pollingStep: (() -> Void)?
        let library = Library(session: session, credentials: store, makePlayer: { _ in
            let player = AVPlayer(url: audio)
            player.isMuted = true
            mediaPlayers.append(player)
            return player
        }, pollingSleep: { delay in
            pollingDelays.append(delay)
            pollingStep?()
            if holdPolling { try await Task.sleep(for: .seconds(60)) }
            else { await Task.yield() }
        })

        do {
            await library.restoreCredentials()
            try require(library.password.isEmpty && !library.connected && !library.restoringSession)
            library.connect(server: "https://fixture.invalid", username: "listener", password: "fixture-one")
            try await wait("Login did not finish") { !library.refreshing }
            try require(library.connected && library.message == nil)
            let saved = try await store.load()
            try require(saved == LoginCredentials(server: "https://fixture.invalid", username: "listener", password: "fixture-one"))
            let reopened = Library(session: session, credentials: store)
            await reopened.restoreCredentials()
            try require(reopened.connected && reopened.tracks.count == 3 && reopened.password.isEmpty && !reopened.restoringSession)

            library.connect(server: "https://fixture.invalid", username: "listener", password: "fixture-two")
            try await wait("Credential update did not finish") { !library.refreshing }
            try require(try await store.load()?.password == "fixture-two")
            LibraryFixtureProtocol.reject = true
            let rejected = Library(session: session, credentials: store)
            await rejected.restoreCredentials()
            try require(!rejected.connected && !rejected.restoringSession && rejected.message != nil)
            try require(rejected.username == "listener" && rejected.password == "fixture-two")
            library.connect(server: "https://fixture.invalid", username: "listener", password: "wrong")
            try await wait("Rejected login did not finish") { !library.refreshing }
            try require(try await store.load()?.password == "fixture-two")
            LibraryFixtureProtocol.reject = false
            print("PASS: saved credentials automatically connect; rejected startup returns to login and preserves credentials")

            LibraryFixtureProtocol.searches = 0
            LibraryFixtureProtocol.addTrackAfter = 3
            LibraryFixtureProtocol.addSecondTrackAfter = 5
            let upload = LibraryUpload(filename: "first.mp3", bytes: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            let secondUpload = LibraryUpload(filename: "second.mp3", bytes: 3, sha256: "cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34")
            var restarted: Task<Void, Never>?
            pollingStep = {
                if pollingDelays.count == 2 {
                    pollingStep = nil
                    restarted = library.pollForLibraryUpdates(uploads: [secondUpload])
                }
            }
            await library.pollForLibraryUpdates(uploads: [upload])?.value
            await restarted?.value
            try require(LibraryFixtureProtocol.searches == 5)
            try require(pollingDelays == [1, 2, 1, 2, 4, 8].map { .seconds($0) })
            try require(library.tracks.contains { $0.id == "uploaded" })
            try require(library.tracks.contains { $0.id == "uploaded-two" })
            LibraryFixtureProtocol.addTrackAfter = Int.max
            LibraryFixtureProtocol.addSecondTrackAfter = Int.max
            library.reload()
            try await wait("Reset library did not finish") { !library.refreshing }
            LibraryFixtureProtocol.searches = 0
            pollingDelays = []
            await library.pollForLibraryUpdates(uploads: [upload])?.value
            try require(LibraryFixtureProtocol.searches == 10)
            try require(pollingDelays == [1, 2, 4, 8, 16, 32, 64, 128, 256, 512].map { .seconds($0) })
            print("PASS: additional uploads retain earlier targets and reset polling; unrelated or partial updates do not stop polling; 10 exponentially spaced refreshes are bounded")

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
            try require(albumTracks.map(\.id) == ["first", "second"])
            library.selectedAlbum = "album-a"
            library.search = "Third"
            try require(library.visibleTracks.map(\.id) == ["third"])
            library.search = ""
            library.play(albumTracks[0], in: albumTracks)
            try await wait("First track did not play") { library.playing && library.position > 0 }
            try require(!library.canGoPrevious && library.canGoNext)
            library.navigate(.artists)
            library.next()
            try require(library.current?.id == "second")
            try require(library.canGoPrevious && !library.canGoNext)
            library.previous()
            try require(library.current?.id == "first")
            try await wait("Previous track did not play") { library.playing && library.position > 0 }
            library.togglePlayback()
            try await wait("Pause failed") { !library.playing }
            library.seek(to: 2)
            try await wait("Seek failed") { abs(mediaPlayers.last!.currentTime().seconds - 2) < 0.2 }
            try require(!library.playing)
            print("PASS: album order, global search, navigation, previous/next and paused seek")

            library.togglePlayback()
            try await wait("Did not advance at track end") { library.current?.id == "second" }
            try await wait("Last track did not stop") { !library.playing && library.position >= 3.8 }
            try require(library.current?.id == "second" && !library.canGoNext)
            library.togglePlayback()
            try await wait("Last track did not restart") { library.playing && library.position < 2 }
            holdPolling = true
            pollingDelays = []
            let polling = library.pollForLibraryUpdates(uploads: [secondUpload])
            try await wait("Polling did not start") { !pollingDelays.isEmpty }
            let searchesBeforeLogout = LibraryFixtureProtocol.searches
            library.disconnect()
            await polling?.value
            try require(LibraryFixtureProtocol.searches == searchesBeforeLogout)
            try await wait("Logout did not finish") { !library.refreshing }
            try require(!library.connected && library.current == nil && library.queue.isEmpty)
            try require(try await store.load() == nil)
            try require(mediaPlayers.allSatisfy { $0.rate == 0 })
            print("PASS: real AVPlayer end notifications advance, stop at end, restart and logout")

            try await store.remove()
        } catch {
            try? await store.remove()
            throw error
        }
    }
}
