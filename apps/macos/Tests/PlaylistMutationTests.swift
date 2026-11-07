import Foundation
import Testing
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct PlaylistMutationTests {
    private func document(_ id: String = "mix", track: String? = "old") -> PlaylistDocument {
        PlaylistDocument(id: "source:" + id, sourceLibrary: "source", sourcePlaylist: id,
            sourceFingerprint: String(repeating: "a", count: 64), name: "Mix", kind: "manual",
            parent: nil, definition: [:], items: [PlaylistItem(id: "occurrence", sourceTrack: "17",
                title: "Song", artist: "Artist", album: "Album", trackId: track,
                sha256: track.map { _ in String(repeating: "b", count: 64) })])
    }

    private func preview() throws -> PlaylistReconciliation {
        try PlaylistReconciliation(documents: [document(track: "new"), document("other", track: "new")],
            snapshots: [PlaylistSnapshot(document: document(), revisions: ["revision-a"]),
                PlaylistSnapshot(document: document("other", track: nil), revisions: ["revision-b"])])
    }

    @Test func requestMatchesStrictHostPlaylistJSON() throws {
        let preview = try preview()
        let mutation = try preview.mutation(cluster: "cluster", baseline: "baseline", request: "request")
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation)) as? [String: Any])
        #expect(Set(wire.keys) == ["request", "cluster", "baseline", "operation", "expected", "payload", "confirmed"])
        #expect(wire["request"] as? String == "request")
        #expect(wire["cluster"] as? String == "cluster")
        #expect(wire["baseline"] as? String == "baseline")
        #expect(wire["operation"] as? String == "update-playlists")
        #expect(wire["expected"] as? [String: [String]] == ["playlist:source:mix": ["revision-a"], "playlist:source:other": ["revision-b"]])
        #expect(wire["confirmed"] as? [String] == ["playlist:source:mix"])
        let payload = try #require(wire["payload"] as? [String: Any])
        #expect(Set(payload.keys) == ["documents"])
        let documents = try #require(payload["documents"] as? [[String: Any]])
        #expect(documents.count == 2)
        #expect(documents[0]["sourceLibrary"] as? String == "source")
        #expect(documents[0]["sourcePlaylist"] as? String == "mix")
        #expect(documents[0]["sourceFingerprint"] as? String == String(repeating: "a", count: 64))
        let items = try #require(documents[0]["items"] as? [[String: Any]])
        #expect(items[0]["id"] as? String == "occurrence")
        #expect(items[0]["sourceTrack"] as? String == "17")
        #expect(items[0]["trackId"] as? String == "new")
        #expect(items[0]["sha256"] as? String == String(repeating: "b", count: 64))
        #expect(preview.replacementPlaylists == ["source:mix"])
    }

    @Test func legacyReconcileEncodingHasNoMutationFields() throws {
        let preview = try preview()
        let request = PlaylistRequest(operation: "reconcile", cluster: "cluster", documents: preview.documents, expected: preview.expected)
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(Set(wire.keys) == ["operation", "cluster", "documents", "expected"])
        #expect(wire["expected"] as? [String: [String]] == preview.expected)
    }

    @Test func retryKeepsIntentAndHostAcrossTimeoutDeferredAndAcceptedRefreshFailure() async throws {
        let attempt = PlaylistUpdateAttempt(preview: try preview(), cluster: "cluster", baseline: "baseline")
        var requests: [ClusterMutationRequest] = []
        do {
            _ = try await attempt.submit(peer: "host", operations: [.updatePlaylists]) {
                requests.append($0)
                throw URLError(.timedOut)
            }
            Issue.record("A timeout must not finish the preview")
        } catch is URLError {}
        #expect(attempt.host == "host")
        do {
            _ = try await attempt.submit(peer: "host", operations: [.updatePlaylists]) {
                requests.append($0)
                return .deferred(request: $0.request, reason: "incomplete-history")
            }
            Issue.record("Deferred must not finish the preview")
        } catch PlaylistImportError.updateDeferred {}
        var sentToAnotherHost = false
        do {
            _ = try await attempt.submit(peer: "another-host", operations: [.updatePlaylists]) {
                sentToAnotherHost = true
                return .accepted(request: $0.request, record: "record", host: "another-host", heads: [:])
            }
            Issue.record("An uncertain request must stay with its accepting host")
        } catch LocalMusicError.clusterUnavailable {}
        #expect(!sentToAnotherHost)
        for _ in 0..<2 {
            // Repeat after acceptance as when the subsequent Catalog refresh failed.
            let count = try await attempt.submit(peer: "host", operations: [.updatePlaylists]) {
                requests.append($0)
                return .accepted(request: $0.request, record: "record", host: "host",
                    heads: ["playlist:source:mix": ["record"], "playlist:source:other": ["other-record"]])
            }
            #expect(count == 2)
        }
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0 == requests[0] })
        #expect(UUID(uuidString: attempt.requestID) != nil)
        #expect(attempt.requestID == attempt.requestID.lowercased())
    }

    @Test(arguments: ["needs-review", "rejected", "deferred", "unsupported", "wrong-request"])
    func onlyAcceptedRepliesFinishThePreview(_ outcome: String) async throws {
        let attempt = PlaylistUpdateAttempt(preview: try preview(), cluster: "cluster", baseline: "baseline")
        do {
            _ = try await attempt.submit(peer: "host", operations: [.updatePlaylists]) { request in
                switch outcome {
                case "needs-review": .needsReview(request: request.request, current: ["playlist:source:mix": ["new-head"]])
                case "rejected": .rejected(request: request.request, reason: .unauthorized)
                case "deferred": .deferred(request: request.request, reason: "incomplete-history")
                case "unsupported": .unsupported(request: request.request, operation: "update-playlists")
                default: .accepted(request: "unrelated-request", record: "record", host: "host", heads: [:])
                }
            }
            Issue.record("Only a matching accepted reply may finish the preview")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
            if outcome == "needs-review" {
                #expect(error.localizedDescription == PlaylistImportError.rejected("playlist preview is stale; refresh the preview").localizedDescription)
            }
        }
        #expect(attempt.request?.expected == ["playlist:source:mix": ["revision-a"], "playlist:source:other": ["revision-b"]])
        #expect(attempt.preview.documents == (try preview()).documents)
    }

    @Test func unsupportedHostNeverReceivesTheMutation() async throws {
        let attempt = PlaylistUpdateAttempt(preview: try preview(), cluster: "cluster", baseline: "baseline")
        var sent = false
        for operations: Set<ClusterOperation> in [[], [.editTrack]] {
            do {
                _ = try await attempt.submit(peer: "host", operations: operations) {
                    sent = true
                    return .accepted(request: $0.request, record: "record", host: "host", heads: [:])
                }
                Issue.record("A missing update-playlists capability must disable submission")
            } catch PlaylistImportError.updateUnavailable {}
        }
        #expect(!sent)
        #expect(attempt.host == nil)
        #expect(attempt.request == nil)
    }

    @Test func previewRetainsBaselineAndRejectsConflictedDocuments() throws {
        let response = try JSONDecoder().decode(PlaylistResponse.self,
            from: Data(#"{"status":"preview","cluster":"cluster","entries":[],"playlists":[],"baseline":"baseline"}"#.utf8))
        let xml = try PropertyListSerialization.data(fromPropertyList: [
            "Library Persistent ID": "source", "Tracks": [String: String](),
            "Playlists": [["Playlist Persistent ID": "mix", "Name": "Mix"]]
        ], format: .xml, options: 0)
        let draft = try PlaylistDraft.parse(xml, catalog: PlaylistMatchingCatalog(cluster: "cluster", entries: [], baseline: response.baseline))
        #expect(draft.baseline == "baseline")
        var conflicted = PlaylistSnapshot(document: document(), revisions: ["a", "b"])
        conflicted.conflicted = true
        #expect(throws: (any Error).self) { try PlaylistReconciliation(documents: [document()], snapshots: [conflicted]) }
        let legacy = try JSONDecoder().decode(PlaylistResponse.self,
            from: Data(#"{"status":"preview","cluster":"cluster","entries":[],"playlists":[]}"#.utf8))
        #expect(legacy.baseline == nil)
    }

    @Test func changedOrReloadedPreviewCreatesANewIntent() throws {
        let preview = try preview()
        let attempt = PlaylistUpdateAttempt(preview: preview, cluster: "cluster", baseline: "baseline")
        #expect(attempt.matches(preview, cluster: "cluster", baseline: "baseline"))
        #expect(!attempt.matches(preview, cluster: "other-cluster", baseline: "baseline"))
        #expect(!attempt.matches(preview, cluster: "cluster", baseline: "new-baseline"))
        let changed = try PlaylistReconciliation(documents: [document()], snapshots: [])
        #expect(!attempt.matches(changed, cluster: "cluster", baseline: "baseline"))
        let reloaded = PlaylistUpdateAttempt(preview: preview, cluster: "cluster", baseline: "baseline")
        #expect(attempt.requestID != reloaded.requestID)
    }
}
