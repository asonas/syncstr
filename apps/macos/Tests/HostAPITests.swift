import AVFoundation
import Combine
import Foundation
import SQLite3
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

private struct HostReply {
    var status = 200
    var headers: [String: String] = [:]
    var data = Data()
    var gate: HostResponseGate?
}

private final class HostResponseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [() -> Void] = []
    private var released = false
    let started: XCTestExpectation
    let cancelled: XCTestExpectation?
    let duplicate: XCTestExpectation?

    init(started: XCTestExpectation, cancelled: XCTestExpectation? = nil, duplicate: XCTestExpectation? = nil) {
        self.started = started
        self.cancelled = cancelled
        self.duplicate = duplicate
    }

    func hold(_ response: @escaping () -> Void) {
        let alreadyReleased = lock.withLock {
            if !responses.isEmpty || released { duplicate?.fulfill() }
            if !released { responses.append(response) }
            return released
        }
        started.fulfill()
        if alreadyReleased { response() }
    }

    func release() {
        let held = lock.withLock {
            released = true
            defer { responses.removeAll() }
            return responses
        }
        held.forEach { $0() }
    }
}

private final class HostProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> HostReply
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(_ handler: @escaping Handler) -> URLSessionConfiguration {
        let key = UUID().uuidString
        lock.withLock { handlers[key] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HostProtocol.self]
        config.httpAdditionalHeaders = ["X-Fixture": key]
        return config
    }

    static func unregister(_ configuration: URLSessionConfiguration) {
        guard let key = configuration.httpAdditionalHeaders?["X-Fixture"] as? String else { return }
        _ = lock.withLock { handlers.removeValue(forKey: key) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var gate: HostResponseGate?
    override func startLoading() {
        do {
            let key = request.value(forHTTPHeaderField: "X-Fixture") ?? ""
            guard let handler = Self.lock.withLock({ Self.handlers[key] }), let url = request.url else { throw URLError(.badURL) }
            let reply = try handler(request)
            let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            if (300..<400).contains(reply.status), let location = reply.headers["Location"], let target = URL(string: location) {
                var next = request
                next.url = target
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: http)
            }
            let finish = { [weak self] in
                guard let self else { return }
                client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            }
            gate = reply.gate
            if let gate { gate.hold(finish) } else { finish() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { gate?.cancelled?.fulfill() }
}

@MainActor
final class HostAPITests: XCTestCase {
    private let audioSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let libraryID = "2cda036e-e0e7-41c1-8cec-91bb91bc3ea1"
    private let node = "884b012a-9e94-4e12-b142-83601fe897e0"
    private var marker: String { "1.\(node).\(String(repeating: "a", count: 64))" }

    private func fixture() throws -> (HostReply, String, Data) {
        let bundle = Bundle(for: Self.self)
        func object(_ name: String) throws -> [String: Any] {
            let file = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        }
        let images = try object("album-artwork")
        var organization = try XCTUnwrap(images["organization"] as? [String: Any])
        var member = try XCTUnwrap((organization["tracks"] as? [[String: Any]])?.first)
        member["sha256"] = audioSHA256
        var second = member
        second["id"] = "track-b"
        organization["tracks"] = [member, second]
        var artwork = try XCTUnwrap(organization["artwork"] as? [String: Any])
        let assets = try XCTUnwrap(artwork["assets"] as? [String: String])
        let blue = try XCTUnwrap(images["blue"] as? String)
        let jpeg = try XCTUnwrap(assets[blue].flatMap { Data(base64Encoded: $0) })
        artwork["assets"] = assets.mapValues { _ in "" }
        organization["artwork"] = artwork
        var entry = try object("local-entry")
        entry.removeValue(forKey: "artwork")
        entry["importedAlbum"] = ["title": "Collection", "compilationValues": ["1"]] as [String: Any]
        func track(_ id: String) throws -> [String: Any] {
            var result = entry
            var track = try XCTUnwrap(entry["track"] as? [String: Any])
            track["id"] = id
            track["coverArt"] = id
            track["albumId"] = "album-a"
            result["track"] = track
            return result
        }
        let playlist: [String: Any] = ["id": "xml:list", "sourceLibrary": "xml", "sourcePlaylist": "list",
            "sourceFingerprint": audioSHA256, "name": "Fixture playlist", "kind": "manual", "definition": [:],
            "items": [["id": "item", "sourceTrack": "item", "title": "Fixture", "trackId": "track-a", "sha256": audioSHA256]]]
        let catalog: [String: Any] = ["id": libraryID, "name": "Fixture", "marker": marker, "organization": organization,
            "entries": try [track("track-a"), track("track-b")], "playlists": [playlist], "conflictedPlaylists": ["xml:list"], "extra": true]
        return try (HostReply(headers: ["ETag": "W/\"\(libraryID).\(marker)\""], data: JSONSerialization.data(withJSONObject: catalog)), blue, jpeg)
    }

    private func store() -> LocalMusicStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LocalMusicStore(root: root)
    }

    private func configuration(_ handler: @escaping HostProtocol.Handler) -> URLSessionConfiguration {
        let config = HostProtocol.register(handler)
        addTeardownBlock { HostProtocol.unregister(config) }
        return config
    }

    private func hostInformation(_ address: HostAddress) -> HostLibraryInfo {
        let host = HostLibraryInfo.Host(id: node, address: address.origin.absoluteString)
        return HostLibraryInfo(library: libraryID, name: "Fixture", host: host, hosts: [host], role: "primary", marker: marker)
    }

    private func informationReply(library: String) throws -> HostReply {
        let host = ["id": node, "address": "https://advertised.example.test"]
        let object: [String: Any] = ["library": library, "name": "Remote", "host": host, "hosts": [host],
                                     "role": "primary", "marker": marker]
        return try HostReply(data: JSONSerialization.data(withJSONObject: object))
    }

    func testAddressScanAndLinkOnlyReadInformationUntilConfirmed() async throws {
        let link = try XCTUnwrap(URL(string: "syncstr://open?host=https%3A%2F%2Fmusic.example.test%3A8441&extra=1"))
        let reply = try informationReply(library: libraryID)
        let files = store()
        let transfer = LocalTransfer(store: files, hostConfiguration: configuration { request in
            XCTAssertEqual(request.url?.absoluteString, "https://music.example.test:8441/api/v1/library")
            return reply
        })
        for input in [HostInput.text("music.example.test:8441"), .text(link.absoluteString), .link(link)] {
            let flow = HostConnectionFlow()
            await flow.read(input, using: transfer)
            guard case .confirmation(let address, let info) = flow.phase else { return XCTFail("Expected confirmation") }
            XCTAssertEqual(address.displayName, "music.example.test:8441")
            XCTAssertEqual(info.name, "Remote")
            XCTAssertNil(try files.database().hostConnection())
        }
        let invalid = try XCTUnwrap(URL(string: "syncstr://open?extra=1"))
        let flow = HostConnectionFlow()
        await flow.read(.link(invalid), using: transfer)
        guard case .failure = flow.phase else { return XCTFail("Invalid link accepted") }
    }

    func testReplacementNeedsSeparateConsentForTheDisplayedCandidate() async throws {
        let (catalog, _, _) = try fixture()
        let files = store()
        let address = try HostAddress("https://music.example.test:443")
        let first = LocalTransfer(store: files, hostConfiguration: configuration { _ in catalog })
        XCTAssertTrue(first.showsLibraryEditControls)
        _ = try await first.confirmHost(address, information: hostInformation(address))
        XCTAssertFalse(first.showsLibraryEditControls)
        try await first.disconnectHost()
        XCTAssertFalse(first.showsLibraryEditControls)
        let nextID = UUID().uuidString.lowercased()
        let info = try informationReply(library: nextID)
        let data = try XCTUnwrap(String(data: catalog.data, encoding: .utf8)).replacingOccurrences(of: libraryID, with: nextID)
        let etag = try XCTUnwrap(catalog.headers["ETag"]).replacingOccurrences(of: libraryID, with: nextID)
        let transfer = LocalTransfer(store: files, hostConfiguration: configuration { request in
            request.url?.lastPathComponent == "library" ? info : HostReply(headers: ["ETag": etag], data: Data(data.utf8))
        })
        let flow = HostConnectionFlow()
        await flow.read(.text(address.origin.absoluteString), using: transfer)
        await flow.confirm(using: transfer, replacing: true)
        guard case .confirmation = flow.phase else { return XCTFail("Skipped first confirmation") }
        await flow.confirm(using: transfer)
        guard case .replacement(let candidate, let information) = flow.phase else { return XCTFail("Skipped replacement consent") }
        XCTAssertEqual(candidate.displayName, "music.example.test")
        XCTAssertEqual(information.library, nextID)
        await flow.confirm(using: transfer)
        XCTAssertNil(try files.database().hostConnection())
        XCTAssertEqual(try files.database().retainedHostLibrary(), libraryID)
        await flow.confirm(using: transfer, replacing: true)
        guard case .connected = flow.phase else { return XCTFail("Replacement failed") }
        XCTAssertEqual(try files.database().hostConnection()?.library, nextID)
    }

    func testCancelledReadDoesNotPresentConfirmationOrFailure() async throws {
        let started = expectation(description: "information request")
        let cancelled = expectation(description: "information request cancelled")
        let gate = HostResponseGate(started: started, cancelled: cancelled)
        let transfer = LocalTransfer(store: store(), hostConfiguration: configuration { _ in HostReply(gate: gate) })
        let flow = HostConnectionFlow()
        let read = Task { await flow.read(.text("music.example.test"), using: transfer) }
        await fulfillment(of: [started], timeout: 3)
        read.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        await read.value
        guard case .reading = flow.phase else { return XCTFail("Cancelled read published a result") }
    }

    func testStoppingDownloadingSourceCancelsHeldRequest() async throws {
        let (reply, _, _) = try fixture()
        let started = expectation(description: "audio GET started")
        let cancelled = expectation(description: "URLProtocol stopped")
        let gate = HostResponseGate(started: started, cancelled: cancelled)
        let files = store()
        let config = configuration { $0.url?.lastPathComponent == "catalog" ? reply : HostReply(gate: gate) }
        let transfer = LocalTransfer(store: files, hostConfiguration: config)
        let address = try HostAddress("https://music.example.test")
        _ = try await transfer.confirmHost(address, information: hostInformation(address))
        let entry = try XCTUnwrap(files.load()?.entries.first)
        let source = transfer.makeLibrarySource()
        let task = Task { try await source.download(entry, cache: nil, diagnostic: nil) { _ in } }
        await fulfillment(of: [started], timeout: 3)
        source.stop()
        await fulfillment(of: [cancelled], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Stopped download succeeded") } catch {}
    }

    func testOnlyHTTPSOriginsAndHostLinksAreAccepted() throws {
        let address = try HostAddress("  HTTPS://Music.Example.Test:443/ \n")
        XCTAssertEqual(address.host, "music.example.test")
        XCTAssertNil(address.port)
        XCTAssertEqual(address.origin.absoluteString, "https://music.example.test")
        let link = try XCTUnwrap(URL(string: "syncstr://open?future=yes&host=https%3A%2F%2FMUSIC.example.test%3A8441"))
        XCTAssertEqual(try HostAddress(link: link).port, 8441)
        for text in ["http://example.test", "https://u:p@example.test", "https://example.test/a",
                     "https://example.test?", "https://example.test/#", "https://example.test:65536", "example.test"] {
            XCTAssertThrowsError(try HostAddress(text), text)
        }
        XCTAssertThrowsError(try HostAddress(link: XCTUnwrap(URL(string: "syncstr://open?address=https%3A%2F%2Fexample.test"))))
    }

    func testCatalogArtworkPlaybackAndOfflineShareOneVerifiedFile() async throws {
        let (reply, imageID, jpeg) = try fixture()
        let audio = expectation(description: "one audio GET across destinations")
        let duplicate = expectation(description: "duplicate audio GET while first response is held")
        duplicate.isInverted = true
        let gate = HostResponseGate(started: audio, duplicate: duplicate)
        var firstArtworkRequest = true
        let image = expectation(description: "image retry without redraw")
        audio.assertForOverFulfill = true
        image.assertForOverFulfill = true
        let address = try HostAddress("https://confirmed.example.test")
        let hash = audioSHA256
        let advertised: [String: String] = ["id": node, "address": "https://advertised.example.test", "role": "future-role"]
        let infoJSON = try JSONSerialization.data(withJSONObject: ["library": libraryID, "name": "Fixture", "marker": marker,
            "host": advertised, "hosts": [advertised], "role": "future-role", "futureField": 123] as [String: Any])
        let config = configuration { request in
            XCTAssertEqual(request.url?.host, address.host)
            switch request.url?.path {
            case "/api/v1/library": return HostReply(data: infoJSON)
            case "/api/v1/catalog": return reply
            case "/api/v1/audio/" + hash:
                return HostReply(data: Data("abc".utf8), gate: gate)
            case "/api/v1/artwork/" + imageID:
                if firstArtworkRequest { firstArtworkRequest = false; throw URLError(.networkConnectionLost) }
                image.fulfill()
                return HostReply(data: jpeg)
            default: throw URLError(.unsupportedURL)
            }
        }
        let cluster = try SharedAudioTests.Fixture()
        let files = cluster.store
        addTeardownBlock { try? FileManager.default.removeItem(at: files.root) }
        try cluster.database.receiveSharedAudio(cluster.snapshot(), peer: cluster.host)
        let identity = CredentialStore(service: "syncstr-host-fixture-identity-" + UUID().uuidString)
        let pairing = CredentialStore(service: "syncstr-host-fixture-pairing-" + UUID().uuidString)
        addTeardownBlock { try await identity.remove(); try await pairing.remove() }
        let library = Library(localStore: files, hostConfiguration: config, peerSecrets: identity, peerPairing: pairing)
        let transfer = library.transfer
        await transfer.restorePeer(readIdentity: { throw LocalMusicError.unauthorized })
        XCTAssertNotNil(transfer.clusterRegistration)
        let info = try await transfer.libraryInformation(at: address)
        XCTAssertEqual(info.role, "future-role")
        let result = try await transfer.confirmHost(address, information: info)
        XCTAssertEqual(result, .updated)
        XCTAssertEqual(transfer.connectionMode, "host")
        XCTAssertFalse(transfer.canSyncPlaylists)
        XCTAssertEqual(library.playlists.map(\.id), ["xml:list"])
        XCTAssertEqual(library.playlistConflicts, ["xml:list"])
        XCTAssertEqual(library.localCatalog?.organization?.artwork?.assets.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.artworkURL(asset: imageID).path))
        let entries = try XCTUnwrap(library.localCatalog?.entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].importedAlbum?.compilation, true)
        let ready = expectation(description: "stored artwork")
        let observation = library.$artworkURLs.compactMap { $0[imageID] }.first().sink { url in
            XCTAssertEqual(try? Data(contentsOf: url), jpeg)
            ready.fulfill()
        }
        XCTAssertEqual(library.albums.first?.coverArt, imageID)
        XCTAssertNil(library.artworkURL(for: imageID))
        await fulfillment(of: [image, ready], timeout: 6)
        observation.cancel()
        let stored = expectation(description: "already stored artwork")
        transfer.requestHostArtwork(imageID) { _, _ in stored.fulfill() }
        await fulfillment(of: [stored], timeout: 3)
        let offline = transfer.makeLibrarySource()
        defer { offline.stop() }
        async let playback = transfer.playbackFile(entries[0].track)
        await fulfillment(of: [audio], timeout: 3)
        let saving = expectation(description: "second download started")
        let save = Task {
            try await offline.download(entries[1], cache: nil, diagnostic: nil) { if $0 == 0 { saving.fulfill() } }
        }
        await fulfillment(of: [saving], timeout: 3)
        await fulfillment(of: [duplicate], timeout: 0.2)
        gate.release()
        try await save.value
        let playbackURL = try await playback
        XCTAssertEqual(try Data(contentsOf: playbackURL), Data("abc".utf8))
        XCTAssertEqual(try Data(contentsOf: files.fileURL(entries[1])), Data("abc".utf8))
        try await transfer.disconnectHost()
        XCTAssertNil(try files.database().hostConnection())
        XCTAssertEqual(transfer.connectionMode, "offline")
        XCTAssertNotNil(try files.database().clusterRegistration())
        let playerReady = expectation(description: "host-only save reached the player after relaunch")
        let reopened = Library(makePlayer: { url in
            XCTAssertEqual(url, files.fileURL(entries[1]))
            XCTAssertEqual(try? Data(contentsOf: url), Data("abc".utf8))
            playerReady.fulfill()
            return AVPlayer()
        }, localStore: files, hostConfiguration: config)
        await reopened.openSavedLocalLibrary()
        XCTAssertEqual(reopened.localCatalog?.id, libraryID)
        reopened.play(entries[1].track)
        await fulfillment(of: [playerReady], timeout: 3)
        XCTAssertEqual(reopened.artworkURL(for: imageID), files.artworkURL(asset: imageID))
        XCTAssertEqual(try Data(contentsOf: files.fileURL(entries[1])), Data("abc".utf8))
    }

    func testConditionalRefreshFailureAndChangedLibraryPreservePublishedSnapshot() async throws {
        let (reply, _, _) = try fixture()
        let files = store()
        let address = try HostAddress("https://confirmed.example.test")
        let host = HostLibraryInfo.Host(id: node, address: address.origin.absoluteString)
        let first = HostLibraryInfo(library: libraryID, name: "Fixture", host: host, hosts: [host], role: "primary", marker: marker)
        let initial = LocalTransfer(store: files, hostConfiguration: configuration { _ in reply })
        _ = try await initial.confirmHost(address, information: first)
        let otherID = "6208d00e-4bb5-401e-9faf-ad20fd6dad79"
        let changed = HostLibraryInfo(library: otherID, name: "Other fixture", host: host, hosts: [host], role: "primary", marker: marker)
        let confirmation = try await initial.confirmHost(address, information: changed)
        XCTAssertEqual(confirmation, .differentLibrary(otherID))
        XCTAssertEqual(initial.hostConnection?.library, libraryID)
        let other = try XCTUnwrap(String(data: reply.data, encoding: .utf8)).replacingOccurrences(of: libraryID, with: otherID)
        let etag = try XCTUnwrap(reply.headers["ETag"])
        for scenario in ["unchanged", "offline", "different"] {
            let config = configuration { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), etag)
                switch scenario {
                case "unchanged": return HostReply(status: 304)
                case "different": return HostReply(headers: ["ETag": etag.replacingOccurrences(of: first.library, with: otherID)], data: Data(other.utf8))
                default: throw URLError(.notConnectedToInternet)
                }
            }
            let reopened = LocalTransfer(store: files, hostConfiguration: config)
            await reopened.restorePeer()
            reopened.connected = true
            reopened.onCatalog = { _ in XCTFail("Replaced the stored catalog") }
            do {
                let result = try await reopened.refreshHost()
                XCTAssertEqual(result, scenario == "unchanged" ? .unchanged : .differentLibrary(otherID))
                XCTAssertEqual(reopened.connected, scenario == "unchanged")
                XCTAssertNotEqual(scenario, "offline")
            } catch {
                XCTAssertEqual(scenario, "offline")
                XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
            }
            XCTAssertEqual(try files.load()?.id, libraryID)
            XCTAssertEqual(try files.database().hostConnection()?.etag, etag)
            XCTAssertEqual(try files.database().playlistDocuments().documents.map(\.id), ["xml:list"])
        }
    }

    func testCommittedSwitchIsPublishedBeforeConditionalRefresh() async throws {
        let (reply, _, _) = try fixture()
        let a = try HostAddress("https://first.example.test")
        let b = try HostAddress("https://second.example.test")
        var body = try XCTUnwrap(JSONSerialization.jsonObject(with: reply.data) as? [String: Any])
        body["marker"] = "second-marker"
        body["name"] = "Second catalog"
        body["playlists"] = []
        let tag = "W/\"\(libraryID).second-marker\""
        let replacement = HostReply(headers: ["ETag": tag], data: try JSONSerialization.data(withJSONObject: body))
        for restoreFirst in [false, true] {
            let files = store()
            let library = Library(localStore: files, hostConfiguration: configuration { request in
                if request.url?.host == a.host { return reply }
                XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), tag)
                return HostReply(status: 304)
            })
            _ = try await library.transfer.confirmHost(a, information: hostInformation(a))
            // Leave the same durable state as a host switch cancelled immediately after commit.
            let writer = LocalTransfer(store: files, hostConfiguration: configuration { _ in replacement })
            _ = try await writer.confirmHost(b, information: hostInformation(b))
            library.transfer.cancel()
            XCTAssertEqual(library.localCatalog?.name, "Fixture")
            XCTAssertFalse(library.playlists.isEmpty)
            if restoreFirst { await library.transfer.restorePeer() }
            let result = try await library.transfer.refreshHost()
            XCTAssertEqual(result, .unchanged)
            XCTAssertEqual(library.transfer.hostConnection?.address, b)
            XCTAssertEqual(library.localCatalog?.name, "Second catalog")
            XCTAssertTrue(library.playlists.isEmpty)
        }
    }

    func testHostFindsLegacySaveAndResolvesQueuedEntryByTrackAndHash() async throws {
        var (reply, _, _) = try fixture()
        reply.data = Data(String(decoding: reply.data, as: UTF8.self)
            .replacingOccurrences(of: "track-a", with: "A").replacingOccurrences(of: "track-b", with: "B").utf8)
        let cluster = try SharedAudioTests.Fixture()
        let files = cluster.store
        defer { try? FileManager.default.removeItem(at: files.root) }
        let previous = try cluster.changedSnapshot { $0["library"] = libraryID }
        try cluster.database.receiveSharedAudio(previous, peer: cluster.host)
        let address = try HostAddress("https://confirmed.example.test")
        let config = configuration { request in
            XCTAssertEqual(request.url?.lastPathComponent, "catalog", "Redownloaded an existing verified file")
            return reply
        }
        let library = Library(localStore: files, hostConfiguration: config)
        let client = HostAPIClient(address: address, configuration: config)
        defer { client.stop() }
        guard case .updated(let update) = try await client.catalog(etag: nil) else { return XCTFail("Missing fixture") }
        let entries = update.catalog.entries
        let old = try XCTUnwrap(cluster.database.playbackEntry("A")?.entry)
        let legacy = files.fileURL(old)
        try Data("abc".utf8).write(to: legacy)
        try files.database().saveAudioPin(old)
        library.transfer.setSavesBackgrounded(true)
        let waiting = try XCTUnwrap(cluster.database.playbackEntry("B")?.entry)
        await library.transfer.requestSave([waiting.track], scope: "waiting")
        XCTAssertEqual(library.transfer.saveRequests.first?.entries, [waiting])
        _ = try await library.transfer.confirmHost(address, information: hostInformation(address))
        XCTAssertTrue(library.hasManagedCopy(entries[0].track))
        XCTAssertFalse(library.hasManagedCopy(entries[1].track))
        let playback = try await library.transfer.playbackFile(entries[0].track, allowAcquisition: false)
        XCTAssertEqual(playback, legacy)
        library.transfer.setSavesBackgrounded(false)
        await library.transfer.saveWorker?.value
        XCTAssertEqual(library.transfer.saveRequests.first?.entries, [entries[1]])
        XCTAssertEqual(library.transfer.saveRequests.first?.state, .complete)
        XCTAssertFalse(files.hasFile(entries[1]))
        XCTAssertTrue(library.hasManagedCopy(entries[1].track))
        library.removeLocalCopies([entries[0].track])
        XCTAssertFalse(library.hasManagedCopy(entries[0].track))
        XCTAssertTrue(library.hasManagedCopy(entries[1].track))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        library.removeLocalCopies([entries[1].track])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDisconnectRetainsOnlySavedPlaybackAcrossRelaunch() async throws {
        let (reply, _, _) = try fixture()
        let files = store()
        let address = try HostAddress("https://confirmed.example.test")
        let config = configuration { request in
            XCTAssertEqual(request.url?.lastPathComponent, "catalog")
            return reply
        }
        let library = Library(localStore: files, hostConfiguration: config)
        _ = try await library.transfer.confirmHost(address, information: hostInformation(address))
        let entries = try XCTUnwrap(library.localCatalog?.entries)
        let entry = entries[0]
        try Data("abc".utf8).write(to: files.fileURL(entry))
        try files.database().saveAudioPin(entry)
        try await library.transfer.disconnectHost()
        XCTAssertNil(try files.database().hostConnection())
        let reopened = Library(localStore: files, hostConfiguration: configuration { _ in
            XCTFail("Contacted a forgotten host")
            throw URLError(.badURL)
        })
        await reopened.openSavedLocalLibrary()
        for current in [library, reopened] {
            XCTAssertEqual(current.localCatalog?.id, libraryID)
            current.transfer.peerName = "Old peer"
            XCTAssertFalse(current.transfer.canSyncPlaylists)
            current.transfer.refreshConnection()
            XCTAssertFalse(current.transfer.busy)
            let file = try await current.transfer.playbackFile(entry.track)
            XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
            do { _ = try await current.transfer.playbackFile(entries[1].track); XCTFail("Played unsaved track") }
            catch LocalMusicError.disconnected {}
        }
    }

    func testInvalidCandidatePreservesActivePlaybackAndConnection() async throws {
        let (catalog, _, _) = try fixture()
        let started = expectation(description: "A is downloading")
        let gate = HostResponseGate(started: started)
        let a = try HostAddress("https://first.example.test")
        let b = try HostAddress("https://second.example.test")
        let c = try HostAddress("https://third.example.test")
        let other = UUID().uuidString.lowercased()
        var mismatch = catalog
        mismatch.data = Data(String(decoding: catalog.data, as: UTF8.self).replacingOccurrences(of: libraryID, with: other).utf8)
        mismatch.headers["ETag"] = catalog.headers["ETag"]?.replacingOccurrences(of: libraryID, with: other)
        let files = store()
        let transfer = LocalTransfer(store: files, hostConfiguration: configuration { request in
            if request.url?.host == b.host { throw URLError(.notConnectedToInternet) }
            if request.url?.host == c.host { return mismatch }
            return request.url?.lastPathComponent == "catalog" ? catalog : HostReply(data: Data("abc".utf8), gate: gate)
        })
        _ = try await transfer.confirmHost(a, information: hostInformation(a))
        let track = try XCTUnwrap(files.load()?.entries.first?.track)
        let playback = Task { try await transfer.playbackFile(track) }
        await fulfillment(of: [started], timeout: 3)
        defer { gate.release() }
        do { _ = try await transfer.confirmHost(b, information: hostInformation(b)); XCTFail("Accepted offline host") }
        catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        let result = try await transfer.confirmHost(c, information: hostInformation(c))
        XCTAssertEqual(result, .differentLibrary(other))
        XCTAssertNil(transfer.changedHostLibrary)
        XCTAssertTrue(transfer.connected)
        XCTAssertEqual(transfer.hostConnection?.address, a)
        gate.release()
        let file = try await playback.value
        XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
    }

    func testFirstConfirmationRejectsMismatchedCatalogWithoutRememberingHost() async throws {
        let (catalog, _, _) = try fixture()
        let files = store()
        let address = try HostAddress("https://first.example.test")
        let info = hostInformation(address)
        let advertised = HostLibraryInfo(library: UUID().uuidString, name: info.name, host: info.host,
                                        hosts: info.hosts, role: info.role, marker: info.marker)
        let transfer = LocalTransfer(store: files, hostConfiguration: configuration { _ in catalog })
        let result = try await transfer.confirmHost(address, information: advertised)
        XCTAssertEqual(result, .differentLibrary(libraryID))
        XCTAssertNil(try files.database().hostConnection())
        XCTAssertNil(transfer.hostConnection)
        XCTAssertFalse(transfer.connected)
    }

    func testCancellationAfterHostCommitPublishesScreenPlaylistsAndPlayback() async throws {
        let (catalog, _, _) = try fixture()
        let files = store()
        let a = try HostAddress("https://first.example.test")
        let b = try HostAddress("https://second.example.test")
        var second = catalog
        second.data = Data(String(decoding: catalog.data, as: UTF8.self)
            .replacingOccurrences(of: "Fixture playlist", with: "Second playlist")
            .replacingOccurrences(of: "track-a", with: "second-track").utf8)
        let library = Library(localStore: files, hostConfiguration: configuration { request in
            if request.url?.host == a.host { return catalog }
            XCTAssertEqual(request.url?.host, b.host)
            return request.url?.lastPathComponent == "catalog" ? second : HostReply(data: Data("abc".utf8))
        })
        let transfer = library.transfer
        _ = try await transfer.confirmHost(a, information: hostInformation(a))
        let committed = expectation(description: "B committed before publication")
        let gate = HostResponseGate(started: committed)
        let switchHost = Task {
            try await transfer.confirmHost(b, information: hostInformation(b)) {
                await withCheckedContinuation { continuation in gate.hold { continuation.resume() } }
            }
        }
        await fulfillment(of: [committed], timeout: 3)
        XCTAssertEqual(try files.database().hostConnection()?.address, b)
        switchHost.cancel()
        transfer.cancel()
        gate.release()
        let result = try await switchHost.value
        XCTAssertEqual(result, .updated)
        XCTAssertEqual(transfer.hostConnection?.address, b)
        XCTAssertTrue(transfer.connected)
        XCTAssertEqual(library.playlists.map(\.name), ["Second playlist"])
        let track = try XCTUnwrap(library.tracks.first { $0.id == "second-track" })
        let file = try await transfer.playbackFile(track)
        XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
    }

    func testDisconnectDuringCommittedSwitchRetainsPublishedCatalog() async throws {
        let (catalog, _, _) = try fixture()
        let files = store()
        let a = try HostAddress("https://first.example.test")
        let b = try HostAddress("https://second.example.test")
        var second = catalog
        second.data = Data(String(decoding: catalog.data, as: UTF8.self)
            .replacingOccurrences(of: "track-a", with: "second-track").utf8)
        let library = Library(localStore: files, hostConfiguration: configuration { request in
            request.url?.host == a.host ? catalog : second
        })
        let transfer = library.transfer
        _ = try await transfer.confirmHost(a, information: hostInformation(a))
        let committed = expectation(description: "switch committed")
        let cancelled = expectation(description: "disconnect cancelled the switch")
        let gate = HostResponseGate(started: committed)
        let switching = Task {
            try await transfer.confirmHost(b, information: hostInformation(b)) {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in gate.hold { continuation.resume() } }
                } onCancel: { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [committed], timeout: 3)
        let disconnect = Task { try await transfer.disconnectHost() }
        await fulfillment(of: [cancelled], timeout: 3)
        gate.release()
        _ = try await switching.value
        do { try await disconnect.value } catch { XCTFail("Disconnect failed: \(error)") }
        let database = try files.database()
        XCTAssertNil(try database.hostConnection())
        XCTAssertNil(transfer.hostConnection)
        XCTAssertEqual(try database.retainedLibrary(at: b), libraryID)
        XCTAssertEqual(transfer.retainedHostLibrary, libraryID)
        let trackIDs = try XCTUnwrap(database.snapshot()).catalog.entries.map(\.track.id)
        XCTAssertTrue(trackIDs.contains("second-track"))
        XCTAssertEqual(library.tracks.map(\.id).sorted(), trackIDs.sorted())
    }

    func testCancelledSameHostRefreshPublishesCommittedVersion() async throws {
        let (catalog, _, _) = try fixture()
        let files = store()
        let address = try HostAddress("https://first.example.test")
        let nextMarker = "2.\(node).\(String(repeating: "b", count: 64))"
        var next = catalog
        next.headers["ETag"] = "W/\"\(libraryID).\(nextMarker)\""
        next.data = Data(String(decoding: catalog.data, as: UTF8.self)
            .replacingOccurrences(of: marker, with: nextMarker)
            .replacingOccurrences(of: "Fixture playlist", with: "Updated playlist").utf8)
        let library = Library(localStore: files, hostConfiguration: configuration { request in
            request.value(forHTTPHeaderField: "If-None-Match") == nil ? catalog : next
        })
        let transfer = library.transfer
        _ = try await transfer.confirmHost(address, information: hostInformation(address))
        let committed = expectation(description: "refresh committed")
        let gate = HostResponseGate(started: committed)
        let refresh = Task {
            try await transfer.confirmHost(address, information: hostInformation(address)) {
                await withCheckedContinuation { continuation in gate.hold { continuation.resume() } }
            }
        }
        await fulfillment(of: [committed], timeout: 3)
        XCTAssertEqual(try files.database().hostConnection()?.marker, nextMarker)
        transfer.cancel()
        gate.release()
        do {
            let result = try await refresh.value
            XCTAssertEqual(result, .updated)
        } catch { XCTFail("Committed refresh failed: \(error)") }
        XCTAssertEqual(transfer.hostConnection?.marker, nextMarker)
        XCTAssertTrue(transfer.connected)
        XCTAssertEqual(library.playlists.map(\.name), ["Updated playlist"])
    }

    func testConcurrentConfirmationWaitsForCommittedHostToPublish() async throws {
        let (catalog, _, _) = try fixture()
        let a = try HostAddress("https://first.example.test")
        let b = try HostAddress("https://second.example.test")
        let early = expectation(description: "second GET before first confirmation can publish")
        early.isInverted = true
        let lock = NSLock()
        var holding = true
        let transfer = LocalTransfer(store: store(), hostConfiguration: configuration { request in
            if request.url?.host == b.host, lock.withLock({ holding }) { early.fulfill() }
            return catalog
        })
        let committed = expectation(description: "first commit")
        let cancelled = expectation(description: "second confirmation supersedes first")
        let gate = HostResponseGate(started: committed)
        let first = Task {
            try await transfer.confirmHost(a, information: hostInformation(a)) {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in gate.hold { continuation.resume() } }
                } onCancel: { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [committed], timeout: 3)
        let second = Task { try await transfer.confirmHost(b, information: hostInformation(b)) }
        await fulfillment(of: [cancelled], timeout: 3)
        await fulfillment(of: [early], timeout: 0.3)
        lock.withLock { holding = false }
        gate.release()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(transfer.hostConnection?.address, b)
    }

    func testNewLinkCancelsHeldConfirmationBeforeConfirmingLatestLink() async throws {
        let (catalog, _, _) = try fixture()
        let info = try informationReply(library: libraryID)
        let started = expectation(description: "first confirmation")
        let cancelled = expectation(description: "superseded catalog GET")
        let gate = HostResponseGate(started: started, cancelled: cancelled)
        let a = try HostAddress("https://first.example.test")
        let b = try HostAddress("https://second.example.test")
        let transfer = LocalTransfer(store: store(), hostConfiguration: configuration { request in
            if request.url?.lastPathComponent == "library" { return info }
            return request.url?.host == a.host ? HostReply(gate: gate) : catalog
        })
        let flow = HostConnectionFlow()
        await flow.read(.text(a.displayName), using: transfer)
        let confirming = Task { await flow.confirm(using: transfer) }
        await fulfillment(of: [started], timeout: 3)
        let link = try XCTUnwrap(URL(string: "syncstr://open?host=https%3A%2F%2Fsecond.example.test"))
        await flow.read(.link(link), using: transfer)
        await fulfillment(of: [cancelled], timeout: 3)
        gate.release()
        await confirming.value
        guard case .confirmation(let address, _) = flow.phase else { return XCTFail("Latest link lost") }
        XCTAssertEqual(address, b)
        await flow.confirm(using: transfer)
        guard case .connected = flow.phase else { return XCTFail("Latest confirmation failed") }
        XCTAssertEqual(transfer.hostConnection?.address, b)
    }

    func testMissingArtworkDoesNotScheduleAnotherGET() async throws {
        let (catalog, id, _) = try fixture()
        let address = try HostAddress("https://first.example.test")
        let missing = expectation(description: "missing artwork requested")
        let retry = expectation(description: "repeated missing artwork GET")
        retry.isInverted = true
        var first = true
        let transfer = LocalTransfer(store: store(), hostConfiguration: configuration { request in
            if request.url?.lastPathComponent == "catalog" { return catalog }
            if first { first = false; missing.fulfill() } else { retry.fulfill() }
            return HostReply(status: 404)
        })
        _ = try await transfer.confirmHost(address, information: hostInformation(address))
        transfer.requestHostArtwork(id) { _, _ in XCTFail("Published missing artwork") }
        await fulfillment(of: [missing], timeout: 3)
        await fulfillment(of: [retry], timeout: 2.5)
    }

    func testChangingAddressForSameLibraryCancelsPlaybackGET() async throws {
        let (reply, _, _) = try fixture()
        let started = expectation(description: "playback GET at old address")
        let cancelled = expectation(description: "playback GET cancelled")
        let gate = HostResponseGate(started: started, cancelled: cancelled)
        let config = configuration { $0.url?.lastPathComponent == "catalog" ? reply : HostReply(gate: gate) }
        let files = store()
        let transfer = LocalTransfer(store: files, hostConfiguration: config)
        let a = try HostAddress("https://first.example.test")
        let b = try HostAddress("https://second.example.test")
        _ = try await transfer.confirmHost(a, information: hostInformation(a))
        let track = try XCTUnwrap(files.load()?.entries.first?.track)
        let task = Task { try await transfer.playbackFile(track) }
        await fulfillment(of: [started], timeout: 3)
        _ = try await transfer.confirmHost(b, information: hostInformation(b))
        await fulfillment(of: [cancelled], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Played old host's response") } catch {}
    }

    func testUnsaveKeepsUnpinnedLegacyFileAndReceipt() async throws {
        let (reply, _, _) = try fixture()
        let files = store()
        let legacy = LocalEntry(track: Track(id: "legacy-track", title: "Legacy", artist: "Fixture", suffix: "wav", size: 3),
                                sha256: audioSHA256)
        try files.save(LocalCatalog(id: "legacy", name: "Legacy", entries: [legacy]))
        let database = try files.database()
        try Data("abc".utf8).write(to: files.fileURL(legacy))
        try database.recordReceived(legacy)
        XCTAssertFalse(try database.hasAudioPin(legacy))
        let address = try HostAddress("https://music.example.test")
        let library = Library(localStore: files, hostConfiguration: configuration { request in
            XCTAssertEqual(request.url?.lastPathComponent, "catalog")
            return reply
        })
        _ = try await library.transfer.confirmHost(address, information: hostInformation(address))
        let track = try XCTUnwrap(library.localCatalog?.entries.first?.track)
        await library.transfer.requestSave([track], scope: "test")
        await library.transfer.saveWorker?.value
        XCTAssertTrue(library.hasManagedCopy(track))
        library.removeLocalCopies([track])
        XCTAssertFalse(library.hasManagedCopy(track))
        XCTAssertEqual(try Data(contentsOf: files.fileURL(legacy)), Data("abc".utf8))
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(files.root.appendingPathComponent("catalog.sqlite").path, &connection, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT relative_path FROM received_files", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return XCTFail("Lost legacy file receipt") }
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), files.fileURL(legacy).lastPathComponent)
    }

    func testUnsavingKeepsAudioReferencedByPendingClusterImport() async throws {
        let (reply, _, _) = try fixture()
        let cluster = try SharedAudioTests.Fixture()
        let files = cluster.store
        defer { try? FileManager.default.removeItem(at: files.root) }
        let library = Library(localStore: files, hostConfiguration: configuration { _ in reply })
        let address = try HostAddress("https://confirmed.example.test")
        _ = try await library.transfer.confirmHost(address, information: hostInformation(address))
        let entry = try XCTUnwrap(library.localCatalog?.entries.first)
        let database = try files.database()
        try Data("abc".utf8).write(to: files.fileURL(entry))
        try database.saveAudioPin(entry)
        let batch = ClusterImportBatch(id: UUID().uuidString, host: cluster.host, items: [
            ClusterImportBatch.Item(id: UUID().uuidString, name: "Fixture.wav", entry: entry,
                organization: nil, parents: [], state: .queued, createdCopy: true, localCopy: .pending)
        ])
        try database.saveClusterBatch(batch)
        library.refreshLocalFiles()
        library.removeLocalCopies([entry.track])
        XCTAssertFalse(library.hasManagedCopy(entry.track))
        XCTAssertEqual(try Data(contentsOf: files.fileURL(entry)), Data("abc".utf8))
    }

    func testLibraryHeaderTriggersRefreshAfterFailedStartupRefresh() async throws {
        var (reply, _, _) = try fixture()
        reply.headers["Syncstr-Switch"] = "1.first"
        let files = store()
        let address = try HostAddress("https://confirmed.example.test")
        let first = LocalTransfer(store: files, hostConfiguration: configuration { _ in reply })
        _ = try await first.confirmHost(address, information: hostInformation(address))
        let refreshed = expectation(description: "refresh after changed library header")
        let host = ["id": node, "address": address.origin.absoluteString]
        let info = try JSONSerialization.data(withJSONObject: ["library": libraryID, "name": "Fixture", "role": "primary",
            "marker": marker, "hosts": [host], "host": host] as [String: Any])
        var firstRequest = true
        let config = configuration { request in
            if request.url?.lastPathComponent == "library" { return HostReply(headers: ["Syncstr-Switch": "2.second"], data: info) }
            if firstRequest { firstRequest = false; throw URLError(.notConnectedToInternet) }
            refreshed.fulfill()
            return HostReply(status: 304, headers: ["Syncstr-Switch": "2.second"])
        }
        let reopened = LocalTransfer(store: files, hostConfiguration: config)
        await reopened.restorePeer()
        do { _ = try await reopened.refreshHost(); XCTFail("Startup request succeeded") } catch is URLError {}
        _ = try await reopened.libraryInformation(at: address)
        await fulfillment(of: [refreshed], timeout: 3)
    }

    func testActivationDuringCommittedConfirmationDrainsOneRefresh() async throws {
        let (reply, _, _) = try fixture()
        let refreshed = expectation(description: "one conditional request after confirmation")
        let transfer = LocalTransfer(store: store(), hostConfiguration: configuration { request in
            if request.value(forHTTPHeaderField: "If-None-Match") != nil {
                refreshed.fulfill()
                return HostReply(status: 304)
            }
            return reply
        })
        let first = try HostAddress("https://first.example.test")
        let second = try HostAddress("https://second.example.test")
        _ = try await transfer.confirmHost(first, information: hostInformation(first))
        let committed = expectation(description: "second host committed")
        let gate = HostResponseGate(started: committed)
        let confirmation = Task {
            try await transfer.confirmHost(second, information: hostInformation(second)) {
                await withCheckedContinuation { continuation in gate.hold { continuation.resume() } }
            }
        }
        await fulfillment(of: [committed], timeout: 3)
        let messages = transfer.$status.compactMap { $0 }.sink { XCTFail("Unexpected refresh error: \($0)") }
        transfer.cancel()
        transfer.refreshConnection()
        transfer.refreshConnection()
        gate.release()
        _ = try await confirmation.value
        await fulfillment(of: [refreshed], timeout: 3)
        messages.cancel()
        XCTAssertNil(transfer.status)
        XCTAssertEqual(transfer.hostConnection?.address, second)
    }

    func testBackgroundAfterDisconnectCommitPublishesRetainedLibrary() async throws {
        let (reply, _, _) = try fixture()
        let files = store()
        let library = Library(localStore: files, hostConfiguration: configuration { _ in reply })
        let transfer = library.transfer
        let address = try HostAddress("https://confirmed.example.test")
        _ = try await transfer.confirmHost(address, information: hostInformation(address))
        let committed = expectation(description: "host deleted")
        let gate = HostResponseGate(started: committed)
        let disconnect = Task {
            try await transfer.disconnectHost {
                await withCheckedContinuation { continuation in gate.hold { continuation.resume() } }
            }
        }
        await fulfillment(of: [committed], timeout: 3)
        XCTAssertNil(try files.database().hostConnection())
        transfer.cancel()
        disconnect.cancel()
        gate.release()
        do { try await disconnect.value } catch { XCTFail("Committed disconnect failed: \(error)") }
        XCTAssertNil(transfer.hostConnection)
        XCTAssertEqual(transfer.retainedHostLibrary, libraryID)
        XCTAssertEqual(library.localCatalog?.id, libraryID)
    }

    func testCancelledAutomaticRefreshKeepsConnectedStatus() async throws {
        let (reply, _, _) = try fixture()
        let address = try HostAddress("https://confirmed.example.test")
        let transfer = LocalTransfer(store: store(), hostConfiguration: configuration { request in
            if request.value(forHTTPHeaderField: "If-None-Match") != nil { throw URLError(.cancelled) }
            return reply
        })
        _ = try await transfer.confirmHost(address, information: hostInformation(address))
        let finished = expectation(description: "automatic refresh ended")
        let idle = transfer.$busy.dropFirst().filter { !$0 }.first().sink { _ in finished.fulfill() }
        let messages = transfer.$status.compactMap { $0 }.sink { XCTFail("Reported cancellation: \($0)") }
        transfer.refreshConnection()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertTrue(transfer.connected)
        XCTAssertNil(transfer.status)
        withExtendedLifetime((idle, messages)) {}
    }

    func testURLCancellationDuringConfirmationRestoresPrompt() async throws {
        let info = try informationReply(library: libraryID)
        let transfer = LocalTransfer(store: store(), hostConfiguration: configuration { request in
            if request.url?.lastPathComponent == "library" { return info }
            throw URLError(.cancelled)
        })
        let flow = HostConnectionFlow()
        await flow.read(.text("confirmed.example.test"), using: transfer)
        await flow.confirm(using: transfer)
        guard case .confirmation = flow.phase else { return XCTFail("Cancelled confirmation lost its prompt") }
    }

    func testScheduledRefreshSurvivesCopyStartingBeforeTaskRuns() async throws {
        let (reply, _, _) = try fixture()
        let refreshed = expectation(description: "queued refresh completed after copy")
        let config = configuration { request in
            if request.value(forHTTPHeaderField: "If-None-Match") != nil { refreshed.fulfill(); return HostReply(status: 304) }
            return reply
        }
        let transfer = LocalTransfer(store: store(), hostConfiguration: config)
        let address = try HostAddress("https://confirmed.example.test")
        _ = try await transfer.confirmHost(address, information: hostInformation(address))
        transfer.refreshConnection()
        transfer.copy([])
        await fulfillment(of: [refreshed], timeout: 3)
    }

    func testReconfirmationStoresAdvertisedHostsEvenWithUnchangedCatalog() async throws {
        let (reply, _, _) = try fixture()
        let files = store()
        let config = configuration { $0.value(forHTTPHeaderField: "If-None-Match") == nil ? reply : HostReply(status: 304) }
        let transfer = LocalTransfer(store: files, hostConfiguration: config)
        let address = try HostAddress("https://confirmed.example.test")
        let first = hostInformation(address)
        _ = try await transfer.confirmHost(address, information: first)
        let mirror = HostLibraryInfo.Host(id: "second", address: "https://mirror.example.test", role: "mirror")
        let next = HostLibraryInfo(library: libraryID, name: first.name, host: first.host, hosts: [first.host, mirror], role: first.role, marker: marker)
        _ = try await transfer.confirmHost(address, information: next)
        XCTAssertEqual(try files.database().hostConnection()?.hosts, next.hosts)
        XCTAssertEqual(transfer.hostConnection?.hosts, next.hosts)
    }

    func testAudioRestartsAfterTransientErrorWithoutResumeData() async throws {
        let address = try HostAddress("https://confirmed.example.test")
        var requests = 0
        let client = HostAPIClient(address: address, configuration: configuration { request in
            requests += 1
            if requests == 1 { throw URLError(.notConnectedToInternet) }
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return HostReply(data: Data("abc".utf8))
        })
        defer { client.stop() }
        let started = ContinuousClock.now
        let file = try await client.audio(sha256: audioSHA256)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
        XCTAssertEqual(requests, 2)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(2))
    }

    func testCorruptAudioAndArtworkNeverReachPlaybackOrStorage() async throws {
        let address = try HostAddress("https://confirmed.example.test")
        let (reply, _, jpeg) = try fixture()
        let id = String(repeating: "a", count: 64)
        let config = configuration { request in
            if request.url?.path == "/api/v1/catalog" { return reply }
            return HostReply(data: request.url?.path.contains("/artwork/") == true ? jpeg : Data("bad".utf8))
        }
        let files = store()
        let transfer = LocalTransfer(store: files, hostConfiguration: config)
        let host = HostLibraryInfo.Host(id: node, address: address.origin.absoluteString)
        _ = try await transfer.confirmHost(address, information: HostLibraryInfo(library: libraryID, name: "Fixture", host: host,
                                                                                hosts: [host], role: "primary", marker: marker))
        let entry = try XCTUnwrap(files.load()?.entries.first)
        do { _ = try await transfer.playbackFile(entry.track); XCTFail("Accepted corrupt audio") }
        catch LocalMusicError.invalidData {}
        XCTAssertFalse(transfer.playbackCache.store.hasFile(entry))
        XCTAssertFalse(files.hasFile(entry))
        let source = try XCTUnwrap(transfer.makeLibrarySource() as? HostLibrarySource)
        defer { source.stop() }
        do { _ = try await source.storedArtwork(id); XCTFail("Accepted corrupt image") }
        catch LocalMusicError.invalidData {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.artworkURL(asset: id).path))
    }

    #if os(macOS)
    func testReadsCatalogServedByConfiguredHeadlessBinary() async throws {
        guard let binary = ProcessInfo.processInfo.environment["SYNCSTR_HEADLESS_TEST_BINARY"] else {
            throw XCTSkip("Set SYNCSTR_HEADLESS_TEST_BINARY to run the host interoperability check")
        }
        let files = store()
        try files.prepare()
        let identity = files.root.appendingPathComponent("identity").path
        let log = files.root.appendingPathComponent("server.log")
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        func start(_ arguments: [String]) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardOutput = output
            try process.run()
            return process
        }
        let initialize = try start(["init", "--identity", identity])
        initialize.waitUntilExit()
        XCTAssertEqual(initialize.terminationStatus, 0)
        let address = try HostAddress("https://music.example.test")
        let server = try start(["serve", "--identity", identity, "--data", files.root.appendingPathComponent("data").path,
                                "--listen", "127.0.0.1:0", "--api-listen", "127.0.0.1:0", "--api-address", address.origin.absoluteString])
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let prefix = "Host API listening on "
        var origin: URL?
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while origin == nil, server.isRunning, ContinuousClock.now < deadline {
            let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            origin = lines.first { $0.hasPrefix(prefix) }.flatMap { URL(string: String($0.dropFirst(prefix.count))) }
            if origin == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let api = try XCTUnwrap(origin).appendingPathComponent("api/v1")
        func fetch(_ path: String, etag: String? = nil) async throws -> HostReply {
            var request = URLRequest(url: api.appendingPathComponent(path))
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            var reply = HostReply(status: http.statusCode, data: data)
            reply.headers["ETag"] = http.value(forHTTPHeaderField: "ETag")
            return reply
        }
        let info = try await fetch("library")
        let catalog = try await fetch("catalog")
        let tag = try XCTUnwrap(catalog.headers["ETag"])
        let unchanged = try await fetch("catalog", etag: tag)
        let client = HostAPIClient(address: address, configuration: configuration { request in
            if request.url?.lastPathComponent == "library" { return info }
            return request.value(forHTTPHeaderField: "If-None-Match") == tag ? unchanged : catalog
        })
        defer { client.stop() }
        let library = try await client.library()
        guard case .updated(let update) = try await client.catalog(etag: nil) else { return XCTFail("Missing initial catalog") }
        XCTAssertEqual(update.catalog.id, library.library)
        XCTAssertEqual(update.marker, library.marker)
        guard case .unchanged = try await client.catalog(etag: update.etag) else { return XCTFail("Missing conditional response") }
    }
    #endif

    func testRefusesRedirectAndClassifiesProxyAndSyncstrErrors() async throws {
        let address = try HostAddress("https://confirmed.example.test")
        let target = try HostAddress("https://elsewhere.example.test")
        let cases: [(HostReply, HostAPIError)] = [
            (HostReply(status: 302, headers: ["Location": target.origin.absoluteString]), .notHost),
            (HostReply(status: 502), .notRunning),
            (HostReply(status: 502, data: Data("Bad Gateway".utf8)), .notRunning),
            (HostReply(status: 429, headers: ["Retry-After": "5"], data: Data(#"{"error":"rate-limited","message":"busy"}"#.utf8)), .rateLimited(5)),
            (HostReply(status: 503, data: Data(#"{"error":"future-code","message":"unavailable"}"#.utf8)), .status(503))
        ]
        for (reply, expected) in cases {
            let client = HostAPIClient(address: address, configuration: configuration { request in
                guard request.url?.host == address.host else {
                    XCTFail("Followed a redirect away from the confirmed address")
                    throw URLError(.badURL)
                }
                return reply
            })
            defer { client.stop() }
            do { _ = try await client.library(); XCTFail("Accepted error response") }
            catch { XCTAssertEqual(error as? HostAPIError, expected) }
        }
    }
}

