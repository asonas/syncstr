import Foundation
import Testing
import AVFoundation
import Security
private final class SharedAudioTestBundle: NSObject {}
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct SharedAudioTests {
    @Test(arguments: ["mp3", "m4a", "flac"])
    func hashPathsPlayUsingTheByteFormatRatherThanMetadata(_ suffix: String) async throws {
        let source = try #require(Bundle(for: SharedAudioTestBundle.self).url(forResource: "untagged", withExtension: suffix))
        let bytes = try Data(contentsOf: source)
        let hash = LocalMusicStore.digest(bytes)
        let store = LocalMusicStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try store.prepare()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var a = Track(id: "A", title: "A", artist: nil, suffix: "incorrect")
        a.audioHash = hash
        var b = a
        b.id = "B"
        let first = LocalEntry(track: a, sha256: hash, artwork: nil)
        let second = LocalEntry(track: b, sha256: hash, artwork: nil)
        #expect(store.fileURL(first) == store.fileURL(second))
        #expect(store.fileURL(first).pathExtension == "audio")
        try bytes.write(to: store.fileURL(first))
        let player = SharedAudioPlayback.player(store.fileURL(first))
        let asset = try #require(player.currentItem?.asset)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 0)
    }

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

        func legacyCatalog() throws -> LocalCatalog {
            let url = try #require(Bundle(for: SharedAudioTestBundle.self).url(forResource: "cluster-signed", withExtension: "json"))
            struct Signed: Decodable {
                struct Signature: Decodable { let id: String; let signature: String }
                let change: Signature
                let signingPayload: String
            }
            let signed = try JSONDecoder().decode(Signed.self, from: Data(contentsOf: url))
            try database.receiveClusterPage(peer: host, sequence: 1, signed: ClusterSignedChange(
                id: signed.change.id, signature: signed.change.signature, payload: signed.signingPayload))
            let catalog = try database.clusterCatalog()
            try store.save(catalog)
            return catalog
        }
    }

    private func expectMutationUnavailable(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            Issue.record("A v5 session must reject legacy mutations before sending")
        } catch LocalMusicError.legacyMutationsUnavailable {
        } catch { Issue.record("Expected an unavailable operation, received: \(error)") }
    }

    @Test(arguments: [false, true])
    func snapshotBlocksMutationsAndPreservesQueues(withPendingMetadata: Bool) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        var catalog = try f.legacyCatalog()
        let entry = try #require(catalog.entries.first)
        let album = try #require(catalog.organization?.albumID(for: entry.track.id))
        if withPendingMetadata {
            catalog.organization?.set(subject: album, kind: "classification", value: "true")
            try f.store.save(catalog, clusterEdits: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let edits = try encoder.encode(f.database.clusterMetadataEdits())
        #expect(try f.database.clusterMetadataEdits().count == (withPendingMetadata ? 1 : 0))
        let batch = ClusterImportBatch(id: UUID().uuidString, host: f.host,
            items: [ClusterImportBatch.Item.State.queued, .failed, .awaitingRestore].map { state in
                ClusterImportBatch.Item(id: UUID().uuidString, name: "Fixture.wav", entry: entry,
                    organization: catalog.organization, parents: [], state: state, createdCopy: true, localCopy: .pending)
            })
        try f.database.saveClusterBatch(batch)
        try Data("abc".utf8).write(to: f.store.fileURL(entry))
        let batches = try encoder.encode(f.database.clusterBatches())
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)

        // A v5 visibility change must not add or replace a legacy metadata edit.
        let projected = try f.database.clusterCatalog()
        let projectedAlbum = try #require(projected.organization?.albumID(for: "A"))
        await expectMutationUnavailable {
            _ = try f.database.setAlbumsHidden([projectedAlbum], hidden: true, libraryID: projected.id)
        }
        await expectMutationUnavailable {
            _ = try await f.store.setAlbumsHidden([projectedAlbum], hidden: false, libraryID: projected.id)
        }
        #expect(try encoder.encode(f.database.clusterMetadataEdits()) == edits)

        let secrets = CredentialStore(service: "syncstr-mutation-test-" + UUID().uuidString)
        let pairing = CredentialStore(service: "syncstr-mutation-pair-test-" + UUID().uuidString)
        defer { Task { try? await secrets.remove(); try? await pairing.remove() } }
        let network = ClusterNetwork(store: f.store, secrets: secrets)
        defer { network.stop() }
        let organization = try #require(catalog.organization)
        await expectMutationUnavailable {
            _ = try await network.upload(entry: entry, organization: organization, parents: [],
                host: f.host, file: f.store.fileURL(entry)) { _ in Issue.record("No upload progress expected") }
        }
        await expectMutationUnavailable { try await network.syncMetadata() }
        await expectMutationUnavailable { _ = try await network.resolve(object: entry.sha256, selected: "unused", parents: []) }
        await expectMutationUnavailable {
            _ = try await network.resolveAlbum(ClusterAlbumConflict(id: album, titles: ["Fixture"], objects: [entry.sha256]), title: "Fixture")
        }
        let library = Library(localStore: f.store, pairingSecrets: pairing, peerSecrets: secrets, peerPairing: pairing)
        let transfer = library.transfer
        defer { library.closeLibrary(); transfer.cancel() }
        try library.openLocal(projected)
        await transfer.restorePeer()
        #expect(library.legacyMutationNotice == LocalMusicError.legacyMutationsUnavailable.localizedDescription)
        #expect(transfer.clusterMutationsUnavailable)
        #expect(transfer.clusterMutationNotice == LocalMusicError.legacyMutationsUnavailable.localizedDescription)
        #expect(transfer.clusterMutationQueueNotice != nil)
        transfer.importCluster([f.store.root.appendingPathComponent("missing.wav")])
        transfer.retryClusterBatch(batch.id)
        transfer.confirmClusterRestore(batchID: batch.id, itemID: batch.items[2].id)
        transfer.resolveCluster(ClusterObjectState(object: entry.sha256, heads: []), selected: "unused")
        transfer.resolveClusterAlbum(ClusterAlbumConflict(id: album, titles: ["Fixture"], objects: [entry.sha256]), title: "Fixture")
        transfer.syncOrganization()
        #expect(!transfer.busy)
        #expect(transfer.status == transfer.clusterMutationNotice)
        await expectMutationUnavailable { try library.saveOrganization(organization) }
        await library.addMusic([f.store.root.appendingPathComponent("missing.wav")])
        #expect(library.message == LocalMusicError.legacyMutationsUnavailable.localizedDescription)
        let visible = library.albums.map(\.id)
        await library.setAlbumsHidden([projectedAlbum], hidden: true).value
        await library.setAlbumHidden(projectedAlbum, hidden: false).value
        #expect(library.albums.map(\.id) == visible)
        #expect(!library.isSavingAlbumVisibility(projectedAlbum))
        #expect(library.message == library.legacyMutationNotice)
        #expect(try f.database.clusterCatalog().organization?.isHidden(projectedAlbum) == false)
        let reopened = try f.store.database()
        #expect(try encoder.encode(reopened.clusterBatches()) == batches)
        #expect(try encoder.encode(reopened.clusterMetadataEdits()) == edits)
        #expect(try Data(contentsOf: f.store.fileURL(entry)) == Data("abc".utf8))
    }

    @Test func failedIdentityRestoreKeepsV5StateAndBlocksAutomaticConnection() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        var catalog = try f.legacyCatalog()
        let entry = try #require(catalog.entries.first)
        let album = try #require(catalog.organization?.albumID(for: entry.track.id))
        catalog.organization?.set(subject: album, kind: "classification", value: "true")
        try f.store.save(catalog, clusterEdits: true)
        let batch = ClusterImportBatch(id: UUID().uuidString, host: f.host, items: [
            ClusterImportBatch.Item(id: UUID().uuidString, name: "Fixture.wav", entry: entry,
                organization: catalog.organization, parents: [], state: .queued, createdCopy: true, localCopy: .pending)
        ])
        try f.database.saveClusterBatch(batch)
        try f.database.setClusterAutomaticCellular(true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let edits = try encoder.encode(f.database.clusterMetadataEdits())
        let batches = try encoder.encode(f.database.clusterBatches())
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let transfer = LocalTransfer(store: f.store,
            peerPairing: CredentialStore(service: "syncstr-restore-failure-test-" + UUID().uuidString))
        defer { transfer.cancel() }
        await transfer.restorePeer(readIdentity: {
            // Persisted UI state must be available before the first Keychain operation.
            #expect(transfer.clusterMutationsUnavailable)
            #expect(transfer.clusterBatches.map(\.id) == [batch.id])
            #expect(transfer.automaticCellular)
            #expect(transfer.clusterMutationQueueNotice != nil)
            throw KeychainError(status: errSecInteractionNotAllowed)
        })
        #expect(transfer.peerID.isEmpty)
        #expect(transfer.clusterRegistration != nil)
        #expect(transfer.clusterMutationsUnavailable)
        #expect(transfer.clusterMutationNotice == LocalMusicError.legacyMutationsUnavailable.localizedDescription)
        #expect(transfer.clusterMutationQueueNotice != nil)
        transfer.connectCluster()
        #expect(!transfer.busy)
        #expect(!transfer.connected)
        #expect(transfer.status?.contains("識別情報") == true)
        #expect(transfer.status?.contains("接続できません") == true)

        // Check the synchronous start gate, then cancel before transport work executes.
        transfer.connectCluster(invitation: "invalid-invitation")
        #expect(transfer.busy)
        transfer.cancel()
        let registration = try #require(try f.database.clusterRegistration())
        let identity = try registration.membership.verify(registration.localGrant).member
        await transfer.restorePeer(readIdentity: { identity })
        #expect(transfer.peerID == identity)
        transfer.connectCluster()
        #expect(transfer.busy)
        transfer.cancel()
        #expect(transfer.clusterMutationsUnavailable)
        #expect(transfer.clusterMutationQueueNotice != nil)
        let reopened = try f.store.database()
        #expect(try encoder.encode(reopened.clusterBatches()) == batches)
        #expect(try encoder.encode(reopened.clusterMetadataEdits()) == edits)
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

    @Test(arguments: [false, true])
    func projectionPreservesEditionsCreditsArtworkAndVisibility(emptyArtwork: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let resource = try #require(Bundle(for: SharedAudioTestBundle.self).url(forResource: "album-artwork", withExtension: "json"))
        struct Art: Decodable { var organization: AlbumOrganization; var blue: String }
        let art = try JSONDecoder().decode(Art.self, from: Data(contentsOf: resource))
        let image = try #require(art.organization.artwork?.assets[art.blue])
        var organization = AlbumOrganization(albums: [
            OrganizationAlbum(id: "edition-a", title: "Same Album"), OrganizationAlbum(id: "edition-b", title: "Same Album")],
            tracks: ["A", "B"].map { id in OrganizationTrack(id: id, sha256: f.hash,
                imported: ImportedAlbumMetadata(title: "Same Album", artist: "Performer " + id,
                    albumArtist: "Ensemble " + id, compilationValues: [id == "A" ? "1" : "0"]),
                importedAlbumID: id == "A" ? "edition-a" : "edition-b") })
        try organization.captureArtwork(image, track: "A", source: "music", context: "fictional-source")
        organization.set(subject: "edition-a", kind: "classification", value: "true")
        organization.set(subject: "edition-b", kind: "visibility", value: "true")
        if emptyArtwork { organization.artwork?.assets[art.blue] = Data() }
        let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(organization))
        let data = try f.changedSnapshot { catalog in
            catalog["legacy_organization"] = raw
            var tracks = catalog["tracks"] as! [String: Any]
            for id in ["A", "B"] {
                var track = tracks[id] as! [String: Any]
                track["album_id"] = id == "A" ? "edition-a" : "edition-b"
                tracks[id] = track
            }
            catalog["tracks"] = tracks
        }
        try f.database.receiveSharedAudio(data, peer: f.host)
        let catalog = try #require(try f.store.load())
        try f.store.save(catalog)
        let projected = try #require(catalog.organization)
        #expect(projected.choices == organization.choices)
        #expect(projected.canonicalTrack("A") != projected.canonicalTrack("B"))
        #expect(projected.tracks.first { $0.id == "A" }?.imported.compilation == true)
        #expect(projected.isHidden("edition-b"))
        #expect(catalog.displayTracks().contains { $0.id == "A" })
        let a = try #require(catalog.entries.first { $0.track.id == "A" })
        let b = try #require(catalog.entries.first { $0.track.id == "B" })
        #expect(a.track.albumId == "edition-a" && b.track.albumId == "edition-b")
        #expect(projected.artistCredit(for: [a.track]) == "Ensemble A")
        #expect(a.artwork == (emptyArtwork ? nil : image))
        #expect(a.track.coverArt == (emptyArtwork ? nil : art.blue))
        if !emptyArtwork { #expect(try Data(contentsOf: f.store.artworkURL(asset: art.blue)) == image) }
        #expect(try LocalMusicStore(root: f.store.root).load()?.organization == projected)
    }

    @Test func incompleteRefreshRetainsVerifiedCatalogAndUnrelatedLocalPlayback() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let b = try #require(f.database.playbackEntry("B")?.entry)
        try Data("abc".utf8).write(to: f.store.fileURL(b))
        try f.database.saveAudioPin(b)
        let incomplete = try f.changedSnapshot { catalog in
            catalog["incomplete"] = [String(repeating: "f", count: 64)]
            var tracks = catalog["tracks"] as! [String: Any]
            tracks.removeValue(forKey: "A")
            var unconfirmed = tracks["B"] as! [String: Any]
            unconfirmed["metadata"] = ["title": "Unconfirmed B"]
            tracks["B"] = unconfirmed
            catalog["tracks"] = tracks
        }
        try f.database.receiveSharedAudio(incomplete, peer: f.host)
        #expect(try f.database.sharedAudioRefreshNotice() != nil)
        #expect(try f.database.sharedAudioSnapshot()?.catalog.incomplete.isEmpty == true)
        #expect(try f.database.playbackEntry("B")?.entry.track.title == "B")
        #expect(try f.database.playbackEntry("A") != nil)
        let transfer = LocalTransfer(store: f.store)
        defer { transfer.stopSaveWorker() }
        #expect(try await transfer.playbackFile(b.track) == f.store.fileURL(b))
        let restarted = try LocalMusicStore(root: f.store.root).database()
        #expect(try restarted.sharedAudioRefreshNotice() != nil)
        #expect(try restarted.playbackEntry("B")?.entry.track.unavailable == false)
        let library = Library(localStore: f.store)
        try library.openLocal(restarted.clusterCatalog())
        #expect(library.catalogNotice?.contains("未完了") == true)
        library.message = nil
        #expect(library.catalogNotice != nil)
        library.search = "B"
        #expect(library.visibleTracks.map(\.id) == ["B"])
        try restarted.receiveSharedAudio(f.snapshot(conflict: true), peer: f.host)
        #expect(try restarted.sharedAudioRefreshNotice() == nil)
        #expect(throws: (any Error).self) { try restarted.playbackEntry("A") }
        #expect(try restarted.playbackEntry("B")?.entry.track.unavailable == false)
        try library.openLocal(restarted.clusterCatalog())
        #expect(library.catalogNotice?.contains("競合") == true)
        #expect(library.visibleTracks.map(\.id) == ["B"])
        library.closeLibrary()
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

    @Test
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
        // Negotiation alone must block writes, before a catalog snapshot exists.
        #expect(try database.sharedAudioSnapshot() == nil)
        let mutationEntry = LocalEntry(track: Track(id: "blocked", title: "Blocked", artist: nil, suffix: "wav", size: 3),
            sha256: LocalMusicStore.digest(Data("abc".utf8)), artwork: nil)
        let mutationOrganization = AlbumOrganization()
        await expectMutationUnavailable {
            try await session.upload(entry: mutationEntry, organization: mutationOrganization, parents: [],
                file: root.appendingPathComponent("missing.wav")) { _ in Issue.record("No upload progress expected") }
        }
        await expectMutationUnavailable { try await session.resolve(object: mutationEntry.sha256, selected: "unused", parents: []) }
        await expectMutationUnavailable { try await session.resolveAlbum(album: "unused", title: "Unused", heads: [:]) }
        await expectMutationUnavailable {
            _ = try await session.editMetadata(ClusterMetadataEdit(id: UUID().uuidString, entry: mutationEntry,
                organization: mutationOrganization, parents: []))
        }
        #expect(try database.sharedAudioSnapshot() == nil)
        // A request sent to v5 would close this connection; reconciliation must still work.
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
        let player = SharedAudioPlayback.player(store.fileURL(entry))
        let asset = try #require(player.currentItem?.asset)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 0)
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
