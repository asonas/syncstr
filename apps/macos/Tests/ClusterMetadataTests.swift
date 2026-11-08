import Foundation
import Testing
import CryptoKit
import Combine
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct ClusterMetadataTests {
    private func visibilityFixture(conflict: Bool = false, resolved: Bool = true) throws -> SharedAudioTests.Fixture {
        let f = try SharedAudioTests.Fixture()
        var organization = AlbumOrganization(albums: [OrganizationAlbum(id: "album-A", title: "First"),
            OrganizationAlbum(id: "album-B", title: "Second")], aliases: ["alias-A": "album-A"])
        organization.set(subject: "album-A", kind: "visibility", value: "true")
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(organization))
        try f.database.receiveSharedAudio(f.changedSnapshot { catalog in
            var tracks = catalog["tracks"] as! [String: [String: Any]]
            tracks["A"]?["album_id"] = "album-A"
            tracks["B"]?["album_id"] = "album-B"
            catalog["tracks"] = tracks
            catalog["legacy_organization"] = legacy
            catalog["heads"] = ["album-visibility:album-A": [String(repeating: "1", count: 64)]]
            if resolved { catalog["album_visibility"] = ["album-A": ["hidden": false], "album-B": ["hidden": true]] }
            catalog["conflicts"] = conflict ? ["album-visibility:album-A"] : []
        }, peer: f.host)
        return f
    }

    @Test func visibilityProjectionPreservesBaselineAliasesAndIndependentSharedAudio() throws {
        let f = try visibilityFixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let catalog = try f.database.clusterCatalog()
        let organization = try #require(catalog.organization)
        #expect(!organization.isHidden("alias-A"))
        #expect(organization.isHidden("album-B"))
        #expect(organization.heads(subject: "album-A", kind: "visibility").first?.value == "true")
        #expect(catalog.entries.first { $0.track.id == "A" }?.sha256 == catalog.entries.first { $0.track.id == "B" }?.sha256)
        let reopened = try CatalogDatabase(f.store.root.appendingPathComponent("catalog.sqlite"))
        #expect(try reopened.clusterCatalog().organization == organization)
    }

    @Test func visibilityConflictAndAbsentOverlayKeepBaseline() throws {
        for (conflict, resolved) in [(true, true), (false, false)] {
            let f = try visibilityFixture(conflict: conflict, resolved: resolved)
            defer { try? FileManager.default.removeItem(at: f.store.root) }
            #expect(try f.database.clusterCatalog().organization?.isHidden("alias-A") == true)
            #expect(try f.database.clusterCatalog().organization?.isHidden("album-B") == resolved)
            if conflict {
                #expect(try f.database.albumVisibilityNotice("alias-A", operations: [.setAlbumVisibility])?.contains("競合") == true)
                #expect(throws: LocalMusicError.self) { try f.database.enqueueAlbumVisibility("alias-A", hidden: false) }
            }
        }
    }

    @Test func visibilityQueueRestoresIntentAndPinsUnknownOutcomeToOneHost() async throws {
        let f = try visibilityFixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let edit = try f.database.enqueueAlbumVisibility("alias-A", hidden: true)
        #expect(edit.mutation?.operation == .setAlbumVisibility)
        #expect(edit.albumVisibility?.album == "album-A")
        #expect(edit.albumVisibility?.hidden == true)
        #expect(edit.mutation?.expected == ["album-visibility:album-A": [String(repeating: "1", count: 64)]])
        #expect(edit.mutation?.confirmed.isEmpty == true)
        let offline = try CatalogDatabase(f.store.root.appendingPathComponent("catalog.sqlite"))
        #expect(try stored(offline, edit.id).mutationState == .queued)
        #expect(try stored(offline, edit.id).mutation == edit.mutation)
        _ = try f.database.beginMetadataMutation(edit.id, host: f.host)
        try f.database.metadataMutationInterrupted(edit.id, reason: "Lost reply")
        let reopened = try CatalogDatabase(f.store.root.appendingPathComponent("catalog.sqlite"))
        let retry = try stored(reopened, edit.id)
        #expect(retry.mutation == edit.mutation)
        #expect(retry.canRetryMutation)
        #expect(retry.mutationState == .outcomeUnknown)
        #expect(throws: LocalMusicError.self) {
            try reopened.beginMetadataMutation(edit.id, host: String(repeating: "b", count: 64))
        }
        try await ClusterMetadataDelivery.send(retry, host: f.host, database: reopened) { request in
            .accepted(request: request.request, record: String(repeating: "2", count: 64), host: f.host,
                heads: ["album-visibility:album-A": [String(repeating: "2", count: 64)]])
        }
        // A refresh failure must not erase the accepted outcome or resend it.
        try reopened.metadataMutationInterrupted(edit.id, reason: "Catalog refresh failed")
        let accepted = try stored(reopened, edit.id)
        #expect(accepted.mutationState == .accepted)
        #expect(!accepted.canRetryMutation)
        #expect(accepted.mutationReply != nil)
        #expect(try reopened.clusterCatalog().organization?.isHidden("album-A") == false)
        #expect(throws: LocalMusicError.self) { try reopened.enqueueAlbumVisibility("album-A", hidden: false) }
        let library = Library(localStore: f.store)
        defer { library.closeLibrary(); library.transfer.cancel() }
        try library.openLocal(reopened.clusterCatalog())
        // Restore database state without touching the identity keychain or connecting.
        await library.transfer.restorePeer(readIdentity: { throw LocalMusicError.clusterUnavailable })
        #expect(library.albumVisibilityStatus("alias-A")?.contains("保存先で受理済み") == true)
        #expect(library.albumVisibilityNotice("alias-A")?.contains("受理済み") == true)
        #expect(!library.isSavingAlbumVisibility("alias-A"))
        #expect(try stored(reopened, edit.id).mutationState == .accepted)
    }

    @Test func visibilityUnsupportedHostAndPartialBatchNeverUseLegacyMutation() async throws {
        let f = try visibilityFixture(conflict: true)
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        #expect(try f.database.albumVisibilityNotice("album-B", operations: []) != nil)
        let unsupported = f.database.enqueueAlbumsVisibility(["album-A", "album-B"], hidden: false, operations: [])
        #expect(unsupported.saved == 0)
        #expect(unsupported.failures.count == 2)
        #expect(try f.database.clusterMetadataEdits().isEmpty)
        let batch = f.database.enqueueAlbumsVisibility(["album-A", "album-B"], hidden: false, operations: [.setAlbumVisibility])
        #expect(batch.saved == 1)
        #expect(batch.failures.count == 1)
        let accepted = try #require(try f.database.clusterMetadataEdits().first)
        #expect(accepted.albumVisibility?.hidden == false)
        #expect(try f.database.clusterMetadataEdits().allSatisfy { $0.mutation?.operation == .setAlbumVisibility })
        try f.database.metadataMutationUnavailable(accepted.id)
        #expect(try stored(f.database, accepted.id).mutationDetail?.contains("表示変更") == true)
        #expect(try f.database.clusterCatalog().organization?.isHidden("album-B") == true)
    }

    private func prepare() throws -> SharedAudioTests.Fixture {
        let fixture = try SharedAudioTests.Fixture()
        try fixture.database.receiveSharedAudio(fixture.changedSnapshot {
            $0["heads"] = ["track:A": [String(repeating: "1", count: 64)]]
        }, peer: fixture.host)
        return fixture
    }

    private func queued(_ fixture: SharedAudioTests.Fixture, track: String = "A", title: String = "My title") throws -> ClusterMetadataEdit {
        let draft = try fixture.database.trackMetadataDraft(track)
        return try fixture.database.enqueueTrackMetadata(draft, title: title, artist: "My artist")
    }

    private func stored(_ database: CatalogDatabase, _ id: String) throws -> ClusterMetadataEdit {
        try #require(try database.clusterMetadataEdits().first(where: { $0.id == id }))
    }

    private func refusal(_ f: SharedAudioTests.Fixture) throws -> ClusterHelloRefusalV5 {
        var registration = try #require(try f.database.clusterRegistration())
        let member = try registration.membership.verify(registration.localGrant).member
        let root = try registration.membership.authorize(registration.membership.root, host: true)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let payload = try ClusterCrypto.payload("syncstr-membership-revocation-v1",
            [1, f.cluster, root.member, member, root.id, [String](), [String]()])
        registration.membership.revocations.append(ClusterRevocation(version: 1,
            id: LocalMusicStore.digest(payload), cluster: f.cluster, issuer: root.member, member: member,
            authority: root.id, observed: [], changeHeads: [],
            signature: try key.signature(for: payload).map { String(format: "%02x", $0) }.joined()))
        return ClusterHelloRefusalV5(version: 5, status: "rejected", reason: "revoked", member: member,
            evidence: registration.membership)
    }

    @Test
    func helloRefusalRejectsUnsentAndPreventsReconnectWithoutChangingSentOutcome() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let unsent = try queued(f)
        let sent = try queued(f, track: "B")
        _ = try f.database.beginMetadataMutation(sent.id, host: f.host)
        try f.database.metadataMutationInterrupted(sent.id, reason: "Lost reply")
        let data = try JSONEncoder().encode(refusal(f))
        try f.database.receiveClusterHelloRefusal(data, peer: f.host)
        // Replayed evidence is idempotent and cannot revive queued work.
        try f.database.receiveClusterHelloRefusal(data, peer: f.host)
        let registration = try #require(try f.database.clusterRegistration())
        #expect(registration.membership.revocations.count == 1)
        #expect(throws: LocalMusicError.self) {
            _ = try registration.membership.verify(registration.localGrant)
        }
        #expect(try stored(f.database, unsent.id).mutationReply == .rejected(request: unsent.id, reason: .revoked))
        #expect(try stored(f.database, unsent.id).mutation == unsent.mutation)
        #expect(try stored(f.database, unsent.id).canRetryMutation == false)
        #expect(try stored(f.database, unsent.id).mutationDetail?.contains("登録が無効") == true)
        #expect(try stored(f.database, sent.id).mutationState == .outcomeUnknown)
        #expect(try stored(f.database, sent.id).mutationHost == f.host)
        try f.database.metadataMutationInterrupted(unsent.id, reason: "Connection failed")
        #expect(try stored(f.database, unsent.id).mutationState == .rejected)
        try f.database.discardMetadataMutation(unsent.id)
        #expect(try f.database.clusterMetadataEdits().map(\.id) == [sent.id])
    }

    @Test
    func retainedRevocationKeepsLocalPlaylistsPlaybackAndCopyRemovalAvailable() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let registration = try #require(try f.database.clusterRegistration())
        let root = try registration.membership.authorize(registration.membership.root, host: true)
        let document = PlaylistDocument(id: "source:mix", sourceLibrary: "source", sourcePlaylist: "mix",
            sourceFingerprint: String(repeating: "a", count: 64), name: "Saved playlist", kind: "manual",
            parent: nil, definition: [:], items: [PlaylistItem(id: "item", sourceTrack: "A", title: "A",
                artist: nil, album: nil, trackId: "A", sha256: f.hash)])
        let body = PlaylistRecord.Body(version: 1, cluster: f.cluster, author: root.member, grant: root.id,
            document: document)
        var payload = Data("syncstr-playlist-v1\n".utf8)
        payload.append(try JSONEncoder().encode(body))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let record = PlaylistRecord(id: LocalMusicStore.digest(payload), payload: String(decoding: payload, as: UTF8.self),
            signature: try key.signature(for: payload).map { String(format: "%02x", $0) }.joined())
        var snapshot = try #require(JSONSerialization.jsonObject(with: f.snapshot()) as? [String: Any])
        snapshot["playlist_history"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(record))]
        try f.database.receiveSharedAudio(JSONSerialization.data(withJSONObject: snapshot), peer: f.host)
        let entry = try #require(try f.database.playbackEntry("A")?.entry)
        try Data("abc".utf8).write(to: f.store.fileURL(entry))
        try f.database.saveAudioPin(entry)
        try f.database.receiveClusterHelloRefusal(JSONEncoder().encode(refusal(f)), peer: f.host)

        // Exercise the persisted state as on relaunch, not a pre-refusal in-memory playlist.
        let reopened = try CatalogDatabase(f.store.root.appendingPathComponent("catalog.sqlite"))
        #expect(try reopened.playlistDocuments().documents == [document])
        #expect(try reopened.clusterCatalog().entries.contains { $0.track.id == "A" })
        #expect(throws: LocalMusicError.self) {
            _ = try reopened.receiveSharedAudio(f.snapshot(), peer: f.host)
        }
        let library = Library(localStore: f.store)
        defer { library.transfer.cancel(); library.transfer.stopSaveWorker() }
        try library.openLocal(reopened.clusterCatalog())
        await library.transfer.restorePeer(readIdentity: { throw LocalMusicError.unauthorized })
        await library.loadPlaylists()
        #expect(library.playlists == [document])
        #expect(!library.transfer.canDeleteSharedTrack)
        #expect(library.canRemoveLocalCopy(entry.track))
        #expect(try await library.transfer.playbackFile(entry.track) == f.store.fileURL(entry))
        try library.transfer.removeClusterCopy(entry)
        #expect(try !reopened.hasAudioPin(entry))
        #expect(!f.store.hasFile(entry))
        #expect(!library.canRemoveLocalCopy(entry.track))
        #expect(try reopened.playlistDocuments().documents == [document])
    }

    @Test(arguments: ["tampered", "member", "host", "unknown-host", "revoked-host", "root", "cluster", "reason", "status", "version", "no-revocation", "oversized", "malformed"])
    func unverifiableHelloRefusalDoesNotChangeMembershipOrEdits(_ failure: String) throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let edit = try queued(f)
        let before = try #require(try f.database.clusterRegistration())
        var wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(refusal(f))) as? [String: Any])
        var evidence = try #require(wire["evidence"] as? [String: Any])
        var revocations = try #require(evidence["revocations"] as? [[String: Any]])
        var peer = f.host
        switch failure {
        case "tampered": revocations[0]["signature"] = String(repeating: "0", count: 128)
        case "member": wire["member"] = f.host
        case "host": peer = try before.membership.chain(before.localGrant)[0].member
        case "unknown-host": peer = String(repeating: "0", count: 64)
        case "revoked-host":
            let root = try before.membership.authorize(before.membership.root, host: true)
            let payload = try ClusterCrypto.payload("syncstr-membership-revocation-v1",
                [1, f.cluster, root.member, f.host, root.id, [String](), [String]()])
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
            let revoked = ClusterRevocation(version: 1, id: LocalMusicStore.digest(payload), cluster: f.cluster,
                issuer: root.member, member: f.host, authority: root.id, observed: [], changeHeads: [],
                signature: try key.signature(for: payload).map { String(format: "%02x", $0) }.joined())
            revocations.append(try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(revoked)) as? [String: Any]))
        case "root": evidence["root"] = String(repeating: "0", count: 64)
        case "cluster": revocations[0]["cluster"] = UUID().uuidString
        case "reason": wire["reason"] = "unauthorized"
        case "status": wire["status"] = "unknown"
        case "version": wire["version"] = 4
        case "no-revocation": revocations = []
        case "oversized": wire["padding"] = String(repeating: "x", count: 4 * 1024 * 1024)
        case "malformed": wire["member"] = 42
        default: Issue.record("Unknown failure case")
        }
        evidence["revocations"] = revocations
        wire["evidence"] = evidence
        let data = try JSONSerialization.data(withJSONObject: wire)
        #expect(throws: (any Error).self) { try f.database.receiveClusterHelloRefusal(data, peer: peer) }
        #expect(try f.database.clusterRegistration()?.membership == before.membership)
        #expect(try stored(f.database, edit.id).mutationState == .queued)
        #expect(try stored(f.database, edit.id).mutation == edit.mutation)
    }

    @Test
    func staleReviewKeepsTextAndRequiresExplicitNewRequest() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let edit = try queued(f)
        let request = try #require(edit.mutation)
        #expect(request.expected == ["track:A": [String(repeating: "1", count: 64)]])
        let current = ["track:A": [String(repeating: "2", count: 64)]]
        var displayedStates: [ClusterMetadataEdit.MutationState?] = []
        try await ClusterMetadataDelivery.send(edit, host: f.host, database: f.database, stateChanged: {
            displayedStates.append(try? stored(f.database, edit.id).mutationState)
        }) {
            #expect($0 == request)
            let sending = try stored(f.database, edit.id)
            #expect(sending.mutationState == .sending)
            return .needsReview(request: $0.request, current: current)
        }
        let review = try stored(f.database, edit.id)
        #expect(displayedStates == [.sending, .needsReview])
        #expect(review.mutationState == .needsReview)
        #expect(!review.canRetryMutation)
        #expect(review.mutation == request)
        #expect(review.metadataValues == ["title": "My title", "artist": "My artist"])
        #expect(try f.database.playbackEntry("A")?.entry.track.title == "A")
        try f.database.receiveSharedAudio(f.changedSnapshot {
            $0["heads"] = current
        }, peer: f.host)
        let draft = try f.database.trackMetadataDraft("A", replacing: review)
        #expect(draft.title == "My title")
        #expect(draft.expected == current)
        // Opening the review does not mutate or automatically resend the old request.
        #expect(try stored(f.database, edit.id).mutation == request)
        let replacement = try f.database.enqueueTrackMetadata(draft, title: draft.title, artist: draft.artist)
        #expect(replacement.id != edit.id)
        #expect(replacement.mutation?.expected == current)
        #expect(replacement.mutationHost == nil)
        #expect(try f.database.clusterMetadataEdits().map(\.id) == [replacement.id])
    }

    @Test
    func revokedReplyRetainsPayloadUntilDiscardAndLeavesAcceptedHistory() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let accepted = try queued(f, track: "B", title: "Already accepted")
        try await ClusterMetadataDelivery.send(accepted, host: f.host, database: f.database) {
            .accepted(request: $0.request, record: String(repeating: "3", count: 64), host: f.host, heads: [:])
        }
        let edit = try queued(f)
        try await ClusterMetadataDelivery.send(edit, host: f.host, database: f.database) {
            .rejected(request: $0.request, reason: .revoked)
        }
        let rejected = try stored(f.database, edit.id)
        #expect(rejected.mutationState == .rejected)
        #expect(rejected.mutation == edit.mutation)
        #expect(rejected.mutationDetail?.contains("登録が無効") == true)
        #expect(!rejected.canRetryMutation)
        #expect(try stored(f.database, accepted.id).mutationState == .accepted)
        try f.database.discardMetadataMutation(edit.id)
        #expect(try f.database.clusterMetadataEdits().map(\.id) == [accepted.id])
    }

    @Test
    func verifiedRevocationRejectsOnlyUnsentIntentsAndRestoresThemWithoutKeychain() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let unsent = try queued(f)
        let unknown = try queued(f, track: "B")
        _ = try f.database.beginMetadataMutation(unknown.id, host: f.host)
        try f.database.metadataMutationInterrupted(unknown.id, reason: "Lost reply")
        var registration = try #require(try f.database.clusterRegistration())
        let member = try registration.membership.verify(registration.localGrant).member
        let root = try registration.membership.authorize(registration.membership.root, host: true)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let payload = try ClusterCrypto.payload("syncstr-membership-revocation-v1",
            [1, f.cluster, root.member, member, root.id, [String](), [String]()])
        registration.membership.revocations.append(ClusterRevocation(version: 1,
            id: LocalMusicStore.digest(payload), cluster: f.cluster, issuer: root.member, member: member,
            authority: root.id, observed: [], changeHeads: [],
            signature: try key.signature(for: payload).map { String(format: "%02x", $0) }.joined()))
        // The verified proof is persisted even when it makes our grant unusable.
        #expect(throws: LocalMusicError.self) {
            try f.database.authenticateClusterPeer(f.host, membership: registration.membership)
        }
        try f.database.rejectUnsentMetadataForRevokedMember()
        #expect(try stored(f.database, unsent.id).mutationReply == .rejected(request: unsent.id, reason: .revoked))
        #expect(try stored(f.database, unsent.id).mutation == unsent.mutation)
        // A previously sent request may already be accepted; revocation is not its outcome.
        #expect(try stored(f.database, unknown.id).mutationState == .outcomeUnknown)
        let transfer = LocalTransfer(store: f.store)
        await transfer.restorePeer(readIdentity: { throw LocalMusicError.unauthorized })
        #expect(transfer.clusterMutationsUnavailable)
        #expect(transfer.trackMetadataNotice != nil)
        #expect(transfer.trackMetadataEdits.count == 2)
        #expect(transfer.trackMetadataEdits.contains { $0.id == unsent.id && $0.mutationState == .rejected })
        #expect(!transfer.busy)
        transfer.connectCluster()
        #expect(!transfer.busy)
        #expect(try f.database.clusterMetadataEdits().count == 2)
    }

    @Test
    func connectionFailureKeepsQueuedAndUnknownWithoutInventingRevocation() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let unsent = try queued(f)
        let sent = try queued(f, track: "B")
        _ = try f.database.beginMetadataMutation(sent.id, host: f.host)
        try f.database.recoverClusterJobs()
        let transfer = LocalTransfer(store: f.store, clusterAddresses: [])
        defer { transfer.cancel() }
        // No endpoint: refresh fails before any Hello or mutation reply is received.
        transfer.connectCluster()
        for await busy in transfer.$busy.values {
            if !busy { break }
        }
        let restored = transfer.trackMetadataEdits
        #expect(restored.first(where: { $0.id == unsent.id })?.mutationState == .queued)
        #expect(restored.first(where: { $0.id == sent.id })?.mutationState == .outcomeUnknown)
        #expect(restored.allSatisfy { $0.mutationReply == nil && $0.mutationState != .rejected })
        #expect(restored.allSatisfy { $0.mutationDetail?.contains("登録が無効") != true })
        #expect(try stored(f.database, unsent.id).mutation == unsent.mutation)
        #expect(try stored(f.database, sent.id).mutation == sent.mutation)
        #expect(try stored(f.database, sent.id).mutationHost == f.host)
    }

    @Test
    func restartRecoversQueuedAndSendingWithOriginalRequestsAndHost() throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let first = try queued(f)
        let second = try queued(f, track: "B")
        _ = try f.database.beginMetadataMutation(first.id, host: f.host)
        let database = try CatalogDatabase(f.store.root.appendingPathComponent("catalog.sqlite"))
        try database.recoverClusterJobs()
        let recovered = try stored(database, first.id)
        #expect(recovered.mutationState == .queued)
        #expect(recovered.mutation == first.mutation)
        #expect(recovered.mutationHost == f.host)
        #expect(try stored(database, second.id).mutation == second.mutation)
        #expect(try stored(database, second.id).mutationHost == nil)
        #expect(throws: (any Error).self) { try database.discardMetadataMutation(first.id) }
        let unsafeReplacement = try database.trackMetadataDraft("A", replacing: recovered)
        #expect(throws: (any Error).self) {
            try database.enqueueTrackMetadata(unsafeReplacement, title: "Do not replace an unknown result", artist: "Artist")
        }
        #expect(try database.clusterMetadataEdits().count == 2)
        #expect(try stored(database, first.id).mutation == first.mutation)
    }

    @Test
    func deliveryCannotLeaveSendingOrLoseAnAcknowledgmentOnCancellation() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        for acknowledged in [false, true] {
            let edit = try queued(f)
            let task = Task {
                try await ClusterMetadataDelivery.send(edit, host: f.host, database: f.database) {
                    withUnsafeCurrentTask { $0?.cancel() }
                    if !acknowledged { throw CancellationError() }
                    return .accepted(request: $0.request, record: String(repeating: "6", count: 64), host: f.host, heads: [:])
                }
            }
            if acknowledged { try await task.value }
            else {
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            let saved = try stored(f.database, edit.id)
            #expect(saved.mutationState == (acknowledged ? .accepted : .outcomeUnknown))
            #expect(saved.mutation == edit.mutation)
            #expect(saved.mutationHost == f.host)
        }
    }

    @Test
    func lostAcknowledgmentReplaysOnlyAtThePinnedHost() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let edit = try queued(f)
        let request = try #require(edit.mutation)
        let reply = ClusterMutationReply.accepted(request: edit.id, record: String(repeating: "4", count: 64),
            host: f.host, heads: ["track:A": [String(repeating: "4", count: 64)]])
        var acceptedRequests: Set<String> = []
        do {
            try await ClusterMetadataDelivery.send(edit, host: f.host, database: f.database) {
                acceptedRequests.insert($0.request)
                throw LocalMusicError.disconnected
            }
            Issue.record("The lost acknowledgment must be reported as unknown")
        } catch LocalMusicError.disconnected {}
        #expect(try stored(f.database, edit.id).mutationState == .outcomeUnknown)
        let database = try CatalogDatabase(f.store.root.appendingPathComponent("catalog.sqlite"))
        try database.recoverClusterJobs()
        let retry = try stored(database, edit.id)
        var otherHostReceivedRequest = false
        do {
            try await ClusterMetadataDelivery.send(retry, host: String(repeating: "b", count: 64), database: database) { _ in
                otherHostReceivedRequest = true
                return reply
            }
            Issue.record("A pinned request must not be delivered to a different host")
        } catch LocalMusicError.invalidData {}
        #expect(!otherHostReceivedRequest)
        try await ClusterMetadataDelivery.send(retry, host: f.host, database: database) {
            #expect($0 == request)
            acceptedRequests.insert($0.request)
            return reply
        }
        let saved = try stored(database, edit.id)
        #expect(acceptedRequests == [edit.id])
        #expect(saved.mutationState == .accepted)
        #expect(saved.mutationReply == reply)
        // A later connection failure cannot overwrite a durable acknowledgment.
        try database.metadataMutationInterrupted(edit.id, reason: "Refresh interrupted")
        #expect(try stored(database, edit.id).mutationState == .accepted)
        #expect(!saved.canRetryMutation)
    }

    @Test
    func sharedAudioTracksHaveIndependentQueueKeysAndCatalogValues() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let a = try queued(f, title: "Changed A")
        let b = try queued(f, track: "B", title: "Changed B")
        #expect(a.entry.sha256 == b.entry.sha256)
        #expect(a.queueKey != b.queueKey)
        #expect(try f.database.clusterMetadataEdits().count == 2)
        #expect(try f.database.playbackEntry("A")?.entry.track.title == "A")
        #expect(try f.database.playbackEntry("B")?.entry.track.title == "B")
        try await ClusterMetadataDelivery.send(a, host: f.host, database: f.database) {
            .accepted(request: $0.request, record: String(repeating: "5", count: 64), host: f.host, heads: [:])
        }
        // Even an acknowledgment does not optimistically edit the shared snapshot.
        #expect(try f.database.playbackEntry("A")?.entry.track.title == "A")
        let updated = try f.changedSnapshot {
            var tracks = $0["tracks"] as! [String: [String: Any]]
            var track = tracks["A"]!
            var metadata = track["metadata"] as! [String: Any]
            metadata["title"] = "Changed A"
            track["metadata"] = metadata
            tracks["A"] = track
            $0["tracks"] = tracks
        }
        try f.database.receiveSharedAudio(updated, peer: f.host)
        #expect(try f.database.playbackEntry("A")?.entry.track.title == "Changed A")
        #expect(try f.database.playbackEntry("B")?.entry.track.title == "B")
        #expect(try stored(f.database, b.id).mutationState == .queued)
    }

    @Test
    func mismatchedAcknowledgmentsCannotBecomeAccepted() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        for wrongRequest in [false, true] {
            let edit = try queued(f)
            do {
                try await ClusterMetadataDelivery.send(edit, host: f.host, database: f.database) {
                    .accepted(request: wrongRequest ? UUID().uuidString.lowercased() : $0.request,
                        record: String(repeating: "7", count: 64),
                        host: wrongRequest ? f.host : String(repeating: "b", count: 64), heads: [:])
                }
                Issue.record("An unrelated acknowledgment cannot complete this intent")
            } catch LocalMusicError.invalidData {}
            let saved = try stored(f.database, edit.id)
            #expect(saved.mutationState == .outcomeUnknown)
            #expect(saved.mutation == edit.mutation)
            #expect(saved.mutationReply == nil)
            #expect(saved.mutationHost == f.host)
        }
    }

    @Test
    func deferredAndUnsupportedRepliesNeverShowSuccessOrDropPayload() async throws {
        let f = try prepare()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let edit = try queued(f)
        try await ClusterMetadataDelivery.send(edit, host: f.host, database: f.database) {
            .deferred(request: $0.request, reason: "incomplete history")
        }
        let deferred = try stored(f.database, edit.id)
        #expect(deferred.mutationState == .queued)
        #expect(deferred.mutationHost == f.host)
        #expect(deferred.mutation == edit.mutation)
        #expect(throws: (any Error).self) { try f.database.metadataMutationUnavailable(edit.id) }
        let unsent = try queued(f, track: "B")
        try f.database.metadataMutationUnavailable(unsent.id)
        let unsupported = try stored(f.database, unsent.id)
        #expect(unsupported.mutationState == .rejected)
        #expect(unsupported.mutation == unsent.mutation)
        #expect(!unsupported.canRetryMutation)
        #expect(unsupported.mutationDetail?.contains("対応していません") == true)
    }

    @Test
    func legacyQueuePayloadStillDecodesAndSurvivesAlongsideTrackRequests() throws {
        let f = try SharedAudioTests.Fixture()
        defer { try? FileManager.default.removeItem(at: f.store.root) }
        let catalog = try f.legacyCatalog()
        let entry = try #require(catalog.entries.first)
        let legacy = ClusterMetadataEdit(id: UUID().uuidString.lowercased(), entry: entry,
            organization: catalog.organization ?? AlbumOrganization(), parents: [])
        // These are the original persisted fields, before mutation state existed.
        var oldPayload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        for key in ["mutation", "mutationHost", "mutationState", "mutationReply", "mutationError"] { oldPayload.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(ClusterMetadataEdit.self, from: JSONSerialization.data(withJSONObject: oldPayload))
        #expect(decoded.mutation == nil)
        #expect(decoded.queueKey == entry.sha256)
        try f.database.saveClusterMetadataEdit(decoded)
        try f.database.receiveSharedAudio(f.snapshot(), peer: f.host)
        let typed = try queued(f)
        try f.database.recoverClusterJobs()
        #expect(try f.database.clusterMetadataEdits().count == 2)
        #expect(try stored(f.database, legacy.id).entry.sha256 == entry.sha256)
        try f.database.discardMetadataMutation(typed.id)
        #expect(try f.database.clusterMetadataEdits().map(\.id) == [legacy.id])
    }
}
