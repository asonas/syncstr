import Foundation
import Testing
private final class SharedAudioTestBundle: NSObject {}
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct SharedAudioTests {
    struct Fixture {
        let store: LocalMusicStore
        let database: CatalogDatabase
        let host: String
        let cluster: String
        let hash = LocalMusicStore.digest(Data("abc".utf8))

        init() throws {
            store = LocalMusicStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            database = try store.database()
            let url = try #require(Bundle(for: SharedAudioTestBundle.self).url(forResource: "cluster-signed", withExtension: "json"))
            struct Proof: Decodable { let membership: ClusterMembership; let client: String; let host: String }
            let proof = try JSONDecoder().decode(Proof.self, from: Data(contentsOf: url))
            let grant = try proof.membership.authorize(proof.client)
            host = proof.host
            cluster = grant.cluster
            try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
                secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
                membership: proof.membership, ownID: proof.client, name: "Fixture")
        }

        func snapshot(baseline: String = String(repeating: "a", count: 64), preferred: String? = nil,
                      conflict: Bool = false) throws -> Data {
            let other = LocalMusicStore.digest(Data("def".utf8))
            func track(_ id: String) -> [String: Any] {
                ["id": id, "metadata": ["title": id, "artist": "Fixture", "suffix": "wav"],
                 "retired": false, "audio": [hash, other], "preferred": preferred ?? hash]
            }
            return try JSONSerialization.data(withJSONObject: ["catalog": [
                "version": 1, "cluster": cluster, "library": "fixture", "baseline": baseline,
                "tracks": ["A": track("A"), "B": track("B"), "missing": ["id": "missing", "metadata": [:], "retired": false, "audio": []]],
                "addresses": ["old-A": "A"],
                "objects": [hash: ["sha256": hash, "bytes": 3, "locators": ["tone.wav"]],
                            other: ["sha256": other, "bytes": 3, "locators": ["other.wav"]]],
                "pins": ["A": [hash, other], "B": [hash, other]], "conflicts": conflict ? ["track:A"] : [], "incomplete": []
            ], "playlists": [], "playlist_history": []])
        }

        func changedSnapshot(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var root = try #require(JSONSerialization.jsonObject(with: snapshot()) as? [String: Any])
            var catalog = try #require(root["catalog"] as? [String: Any])
            change(&catalog)
            root["catalog"] = catalog
            return try JSONSerialization.data(withJSONObject: root)
        }
    }

    @Test func truncatedRefreshCannotForgetKnownLogicalIDs() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let truncated = try f.changedSnapshot { catalog in
            var tracks = catalog["tracks"] as! [String: Any]
            tracks.removeValue(forKey: "A")
            catalog["tracks"] = tracks
        }
        #expect(throws: (any Error).self) { try f.database.receiveSharedAudio(truncated, peer: f.host) }
        #expect(try f.database.clusterCatalog().entries.map(\.track.id) == ["A", "B", "missing"])
    }

    @Test func knownAudioDoesNotRequireInventingMetadata() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let data = try f.changedSnapshot { catalog in
            var tracks = catalog["tracks"] as! [String: Any]
            var track = tracks["A"] as! [String: Any]
            track["metadata"] = [:] as [String: String]
            tracks["A"] = track
            catalog["tracks"] = tracks
        }
        try f.database.receiveSharedAudio(data, peer: f.host)
        let entry = try #require(f.database.playbackEntry("A", hash: f.hash)?.entry)
        #expect(entry.track.title == "")
        #expect(entry.track.suffix == nil)
        #expect(entry.sha256 == f.hash)
    }

    @Test func logicalRowsAndExactBindingsSurviveRefreshAndRestart() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let before = try #require(try f.store.load())
        #expect(before.entries.map(\.track.id) == ["A", "B", "missing"])
        #expect(before.entries[2].track.title == "")
        #expect(before.entries[2].track.unavailable == true)
        let old = try #require(try f.database.playbackEntry("old-A", hash: f.hash)?.entry)
        #expect(old.track.id == "old-A")
        try f.database.receiveSharedAudio(f.snapshot(preferred: LocalMusicStore.digest(Data("def".utf8))), peer: f.host)
        let reopened = try f.store.database()
        #expect(try reopened.playbackEntry("A", hash: old.sha256)?.entry.sha256 == f.hash)
        #expect(try reopened.playbackEntry("A")?.entry.sha256 != f.hash)
        #expect(throws: (any Error).self) { try reopened.receiveSharedAudio(f.snapshot(baseline: String(repeating: "b", count: 64)), peer: f.host) }
        #expect(throws: (any Error).self) { try reopened.save(LocalCatalog(id: "fixture", name: "Legacy", entries: [])) }
        #expect(try reopened.snapshot()?.catalog.entries.count == 3)
        try reopened.receiveSharedAudio(f.snapshot(conflict: true), peer: f.host)
        #expect(throws: (any Error).self) { try reopened.playbackEntry("A", hash: f.hash) }
        #expect(try reopened.playbackEntry("B", hash: f.hash) != nil)
    }

    @Test func independentSavesKeepSharedBytesAfterRemovalAndRestart() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let a = try #require(try f.database.playbackEntry("A")?.entry)
        let b = try #require(try f.database.playbackEntry("B")?.entry)
        var alternateSuffix = b
        alternateSuffix.track.suffix = "aiff"
        #expect(f.store.fileURL(a) == f.store.fileURL(alternateSuffix))
        try Data("abc".utf8).write(to: f.store.fileURL(a))
        try f.database.saveAudioPin(a)
        try f.database.saveAudioPin(b)
        let alias = try #require(try f.database.playbackEntry("old-A", hash: f.hash)?.entry)
        #expect(try f.database.hasAudioPin(alias))
        let transfer = LocalTransfer(store: f.store)
        defer { transfer.stopSaveWorker() }
        try transfer.removeClusterCopy(a)
        #expect(!f.store.hasSavedFile(a))
        #expect(f.store.hasSavedFile(b))
        #expect(try await transfer.playbackFile(b.track) == f.store.fileURL(b))
        let restarted = LocalMusicStore(root: f.store.root)
        #expect(!restarted.hasSavedFile(a))
        #expect(restarted.hasSavedFile(b))
        transfer.playbackCache.protectedURL = f.store.fileURL(b)
        try transfer.removeClusterCopy(b)
        #expect(!restarted.hasSavedFile(b))
        #expect(restarted.hasFile(b))
    }

    @Test func pendingLogicalSavesResumeIndependentlyFromSharedBytes() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let a = try #require(try f.database.playbackEntry("A")?.entry)
        let b = try #require(try f.database.playbackEntry("B")?.entry)
        let first = LocalTransfer(store: f.store)
        first.setSavesBackgrounded(true)
        await first.requestSave([a.track, b.track, a.track], scope: "album")
        #expect(first.saveRequests.first?.entries.count == 2)
        first.stopSaveWorker()
        let restarted = LocalTransfer(store: f.store)
        defer { restarted.stopSaveWorker() }
        try Data("abc".utf8).write(to: f.store.fileURL(a))
        restarted.resumeSaves()
        for _ in 0..<200 {
            if restarted.saveRequests.first?.state == .complete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restarted.saveRequests.first?.state == .complete)
        #expect(restarted.saveRequests.first?.completed == ["A:" + f.hash, "B:" + f.hash])
        #expect(f.store.hasSavedFile(a) && f.store.hasSavedFile(b))
        try restarted.cancelSaves(containing: [a.track])
        try restarted.removeClusterCopy(a)
        #expect(!f.store.hasSavedFile(a) && f.store.hasSavedFile(b))
    }

    @Test func savingCachedAudioSharesStorageAndSurvivesCacheEviction() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let entries = try ["A", "B"].map { try #require(f.database.playbackEntry($0)?.entry) }
        let transfer = LocalTransfer(store: f.store)
        defer { transfer.stopSaveWorker() }
        try transfer.playbackCache.store.prepare()
        let cached = transfer.playbackCache.store.fileURL(entries[0])
        try Data("abc".utf8).write(to: cached)
        await transfer.requestSave(entries.map(\.track), scope: "album")
        for _ in 0..<200 {
            if transfer.saveRequests.first?.state == .complete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transfer.saveRequests.first?.state == .complete)
        let cachedAttributes = try FileManager.default.attributesOfItem(atPath: cached.path)
        let savedAttributes = try FileManager.default.attributesOfItem(atPath: f.store.fileURL(entries[0]).path)
        #expect(cachedAttributes[.systemFileNumber] as? NSNumber == savedAttributes[.systemFileNumber] as? NSNumber)
        try transfer.playbackCache.setLimit(1)
        var incoming = entries[0]
        incoming.track.size = 1_000_000_000
        try transfer.playbackCache.makeRoom(for: incoming)
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(f.store.hasSavedFile(entries[0]) && f.store.hasSavedFile(entries[1]))
        #expect(try await transfer.playbackFile(entries[1].track) == f.store.fileURL(entries[1]))
    }

    @Test func savingAnAliasKeepsOneLogicalIntentAndCancelsByCanonicalID() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let a = try #require(f.database.playbackEntry("A")?.entry.track)
        let alias = try #require(f.database.playbackEntry("old-A")?.entry.track)
        let b = try #require(f.database.playbackEntry("B")?.entry.track)
        let transfer = LocalTransfer(store: f.store)
        transfer.setSavesBackgrounded(true)
        defer { transfer.stopSaveWorker() }
        await transfer.requestSave([alias, a, b], scope: "playlist")
        #expect(transfer.saveRequests.first?.entries.map(\.track.id) == ["A", "B"])
        try transfer.cancelSaves(containing: [alias])
        #expect(transfer.saveRequests.first?.entries.map(\.track.id) == ["B"])
        #expect(transfer.saveRequests.first?.state == .waiting)
    }

    @Test func refreshingCatalogKeepsAliasQueue() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let service = UUID().uuidString
        let library = Library(localStore: f.store, pairingSecrets: CredentialStore(service: service + ".pair"),
            peerSecrets: CredentialStore(service: service + ".id"), peerPairing: CredentialStore(service: service + ".peer"))
        try library.openLocal(f.database.clusterCatalog())
        let alias = try #require(f.database.playbackEntry("old-A", hash: f.hash)?.entry.track)
        library.current = alias
        library.queue = [alias, alias]
        library.pause()
        try f.database.receiveSharedAudio(f.snapshot(preferred: LocalMusicStore.digest(Data("def".utf8))), peer: f.host)
        try library.openLocal(f.database.clusterCatalog())
        #expect(library.current?.audioHash == f.hash)
        #expect(library.queue.map(\.audioHash) == [f.hash, f.hash])
        #expect(library.playbackFailure == nil)
    }

    @Test func selectingAnotherEncodingDoesNotReuseOldAcquisition() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let library = Library(localStore: f.store)
        defer { library.closeLibrary() }
        try library.openLocal(f.database.clusterCatalog())
        let old = try #require(f.database.playbackEntry("A", hash: f.hash)?.entry.track)
        let updated = try #require(f.database.playbackEntry("A", hash: LocalMusicStore.digest(Data("def".utf8)))?.entry.track)
        library.play(old)
        #expect(library.loading)
        library.play(updated, in: [updated])
        #expect(library.current?.audioHash == updated.audioHash)
    }

#if os(macOS)
    nonisolated private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    nonisolated private static var binaries: URL {
        ProcessInfo.processInfo.environment["SYNCSTR_V5_TEST_BIN_DIR"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent("headless/target/debug")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: binaries.appendingPathComponent("examples/shared_audio_fixture").path)
        && FileManager.default.isExecutableFile(atPath: binaries.appendingPathComponent("syncstr-headless").path),
        "Requires the p2p headless binary and shared_audio_fixture example"))
    func realV5ServerAuthenticatesAndDownloadsExactPlaylistBindings() async throws {
        let binary = Self.binaries.appendingPathComponent("syncstr-headless")
        let generator = Self.binaries.appendingPathComponent("examples/shared_audio_fixture")
        guard FileManager.default.isExecutableFile(atPath: binary.path), FileManager.default.isExecutableFile(atPath: generator.path) else {
            Issue.record("Build the p2p headless binary and shared_audio_fixture example before this integration test")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let create = Process()
        create.executableURL = generator
        create.arguments = [root.path]
        create.standardOutput = FileHandle.nullDevice
        try create.run()
        create.waitUntilExit()
        #expect(create.terminationStatus == 0)
        let addressURL = root.appendingPathComponent("address.json")
        let server = Process()
        server.executableURL = binary
        server.arguments = ["shared-audio-serve", "--data", root.appendingPathComponent("host-data").path,
            "--identity", root.appendingPathComponent("host-tls").path, "--peer-state", root.appendingPathComponent("host").path,
            "--listen", "127.0.0.1:0", "--peer-listen", "127.0.0.1:0", "--peer-address-out", addressURL.path]
        server.standardOutput = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: addressURL.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        struct Endpoint: Decodable { let id: String; let addrs: [[String: String]] }
        let endpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: addressURL))
        let address = PeerAddress(version: 1, id: endpoint.id, addresses: endpoint.addrs.compactMap { $0["Ip"] }, relay: nil)
        struct Enrollment: Decodable { let grant: String; let proof: ClusterMembership; let member: String }
        let enrollment = try JSONDecoder().decode(Enrollment.self, from: Data(contentsOf: root.appendingPathComponent("reader-enrollment.json")))
        let secrets = CredentialStore(service: "syncstr-v5-test-" + UUID().uuidString)
        let key = try Data(contentsOf: root.appendingPathComponent("reader/device.key"))
        try await secrets.save(PairingCredentials(libraryID: "fixture", name: "Reader", key: key.base64EncodedString()))
        defer { Task { try? await secrets.remove() } }
        let store = LocalMusicStore(root: root.appendingPathComponent("apple"))
        let database = try store.database()
        let grant = try enrollment.proof.verify(enrollment.grant)
        try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: enrollment.proof, ownID: enrollment.member, name: "Fixture")
        let session = try await ClusterSession.connect(address: address.endpoint(expected: address.id), secrets: secrets, database: database)
        defer { session.close() }
        #expect(await session.sharedAudio)
        try await session.reconcile(database: database)
        let snapshot = try #require(try database.sharedAudioSnapshot())
        #expect(snapshot.catalog.tracks.count == 3)
        let playlist = try #require(try database.playlistDocuments().documents.first)
        #expect(playlist.items.count == 3)
        let item = try #require(playlist.items.first)
        let trackID = try #require(item.trackId)
        let hash = try #require(item.sha256)
        let entry = try #require(try database.playbackEntry(trackID, hash: hash)?.entry)
        try await session.downloadSharedAudio(entry, store: store) { _ in }
        #expect(try LocalMusicStore.digest(file: store.fileURL(entry)) == item.sha256)
        let data = try Data(contentsOf: root.appendingPathComponent("snapshot.json"))
        #expect(try JSONDecoder().decode(SharedAudioSnapshot.self, from: data).playlist_history.map(\.payload) == snapshot.playlist_history.map(\.payload))
        session.close()
        server.terminate()
        server.waitUntilExit()
        #expect(try LocalMusicStore(root: store.root).load()?.entries.count == 3)

        let updater = Self.binaries.appendingPathComponent("examples/shared_audio_fixture_update")
        try #require(FileManager.default.isExecutableFile(atPath: updater.path), "Build shared_audio_fixture_update")
        let update = Process()
        update.executableURL = updater
        update.arguments = [root.path, "update"]
        try update.run()
        update.waitUntilExit()
        try #require(update.terminationStatus == 0)
        try FileManager.default.removeItem(at: addressURL)
        let restarted = Process()
        restarted.executableURL = binary
        restarted.arguments = server.arguments
        restarted.standardOutput = FileHandle.nullDevice
        try restarted.run()
        defer { if restarted.isRunning { restarted.terminate(); restarted.waitUntilExit() } }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: addressURL.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let nextEndpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: addressURL))
        let nextAddress = PeerAddress(version: 1, id: nextEndpoint.id, addresses: nextEndpoint.addrs.compactMap { $0["Ip"] }, relay: nil)
        let reconnected = try await ClusterSession.connect(address: nextAddress.endpoint(expected: nextAddress.id), secrets: secrets, database: database)
        defer { reconnected.close() }
        try await reconnected.reconcile(database: database)
        #expect(try database.playlistDocuments().documents.first == playlist)
        let latest = try #require(database.playbackEntry(trackID)?.entry)
        #expect(latest.sha256 != hash)
        #expect(latest.track.title == "Updated fixture tone")
        #expect(latest.track.album == "Changed Album")
        #expect(try database.clusterCatalog().entries.filter { ["TRACK-A", "TRACK-B"].contains($0.track.title) }.count == 2)
        try await reconnected.downloadSharedAudio(entry, store: store) { _ in }
        #expect(try LocalMusicStore.digest(file: store.fileURL(entry)) == hash)
        reconnected.close()
        restarted.terminate()
        restarted.waitUntilExit()
        let revoke = Process()
        revoke.executableURL = updater
        revoke.arguments = [root.path, "revoke"]
        try revoke.run()
        revoke.waitUntilExit()
        try #require(revoke.terminationStatus == 0)
        try FileManager.default.removeItem(at: addressURL)
        let revokedServer = Process()
        revokedServer.executableURL = binary
        revokedServer.arguments = server.arguments
        revokedServer.standardOutput = FileHandle.nullDevice
        try revokedServer.run()
        defer { revokedServer.terminate(); revokedServer.waitUntilExit() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: addressURL.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let revokedEndpoint = try JSONDecoder().decode(Endpoint.self, from: Data(contentsOf: addressURL))
        let revokedAddress = PeerAddress(version: 1, id: revokedEndpoint.id, addresses: revokedEndpoint.addrs.compactMap { $0["Ip"] }, relay: nil)
        await #expect(throws: (any Error).self) {
            let rejected = try await ClusterSession.connect(address: revokedAddress.endpoint(expected: revokedAddress.id), secrets: secrets, database: database)
            rejected.close()
        }
        #expect(try database.playlistDocuments().documents.first == playlist)
    }
#endif
}
