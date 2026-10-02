import AVFoundation
import Foundation

final class LibraryFixtureProtocol: URLProtocol {
    static var reject = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload: [String: Any]
        if Self.reject {
            payload = ["status": "failed", "error": ["code": 40]]
        } else if request.url!.lastPathComponent == "ping.view" {
            payload = ["status": "ok"]
        } else {
            payload = ["status": "ok", "searchResult3": ["song": [
                ["id": "second", "title": "Second", "artist": "Artist A", "album": "Album A", "albumId": "album-a", "track": 2, "duration": 4],
                ["id": "first", "title": "First", "artist": "Artist A", "album": "Album A", "albumId": "album-a", "track": 1, "duration": 4],
                ["id": "third", "title": "Third", "artist": "Artist B", "album": "Album B", "albumId": "album-b", "track": 1, "duration": 4]
            ]]]
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
        let library = Library(session: session, credentials: store, makePlayer: { _ in
            let player = AVPlayer(url: audio)
            player.isMuted = true
            mediaPlayers.append(player)
            return player
        })

        do {
            await library.restoreCredentials()
            try require(library.password.isEmpty)
            library.connect(server: "https://fixture.invalid", username: "listener", password: "fixture-one")
            try await wait("Login did not finish") { !library.refreshing }
            try require(library.connected && library.message == nil)
            let saved = try await store.load()
            try require(saved == LoginCredentials(server: "https://fixture.invalid", username: "listener", password: "fixture-one"))
            let reopened = Library(session: session, credentials: store)
            await reopened.restoreCredentials()
            try require(reopened.username == "listener" && reopened.password == "fixture-one")

            library.connect(server: "https://fixture.invalid", username: "listener", password: "fixture-two")
            try await wait("Credential update did not finish") { !library.refreshing }
            try require(try await store.load()?.password == "fixture-two")
            LibraryFixtureProtocol.reject = true
            library.connect(server: "https://fixture.invalid", username: "listener", password: "wrong")
            try await wait("Rejected login did not finish") { !library.refreshing }
            try require(try await store.load()?.password == "fixture-two")
            LibraryFixtureProtocol.reject = false
            print("PASS: successful login saves and restores credentials; rejected login does not replace them")

            try require(library.destination == .albums)
            try require(library.albums.map(\.title) == ["Album A", "Album B"])
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
            library.disconnect()
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
