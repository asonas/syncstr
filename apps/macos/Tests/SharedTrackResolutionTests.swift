import Foundation
import Testing
#if os(iOS)
@testable import Syncstr
#endif

@MainActor
struct SharedTrackResolutionTests {
    private let live = String(repeating: "b", count: 64)
    private let retired = String(repeating: "a", count: 64)

    private func fixture(candidates: Bool = true) throws -> SharedAudioSnapshot.Catalog {
        let track: [String: Any] = ["id": "T-A", "metadata": ["title": "Example Song", "artist": "Example Artist"],
            "retired": false, "audio": []]
        var deleted = track
        deleted["retired"] = true
        var catalog: [String: Any] = ["version": 1, "cluster": "cluster-example", "library": "library-example",
            "baseline": String(repeating: "c", count: 64), "tracks": ["T-A": track], "addresses": [:],
            "objects": [:], "pins": [:], "conflicts": ["track:T-A"], "incomplete": [],
            "heads": ["track:T-A": [live, retired]]]
        if candidates { catalog["candidates"] = ["T-A": [live: track, retired: deleted]] }
        return try JSONDecoder().decode(SharedAudioSnapshot.Catalog.self,
            from: JSONSerialization.data(withJSONObject: catalog))
    }

    @Test func candidatesUseEveryHostHeadWithoutMergingTracksOrSelectingDeletion() throws {
        let catalog = try fixture()
        let conflict = try #require(SharedTrackConflict.project(catalog).first)
        #expect(conflict.id == "T-A")
        #expect(conflict.heads == [live, retired])
        #expect(conflict.choices.map(\.id) == [live, retired])
        #expect(conflict.isComplete)
        #expect(conflict.choices[0].title == "Example Song")
        #expect(conflict.choices[0].isAvailable(isHost: false))
        #expect(!conflict.choices[1].isAvailable(isHost: false))
        #expect(conflict.choices[1].isAvailable(isHost: true))
    }

    @Test func requestUsesResolveTrackAndEveryCompetingHead() throws {
        let catalog = try fixture()
        let conflict = try #require(SharedTrackConflict.project(catalog).first)
        let request = try conflict.request(catalog: catalog, selected: live)
        #expect(request.operation == .resolveTrack)
        #expect(request.expected == ["track:T-A": [live, retired]])
        #expect(request.cluster == catalog.cluster)
        #expect(request.baseline == catalog.baseline)
        #expect(UUID(uuidString: request.request) != nil)
        #expect(request.request == request.request.lowercased())
        let wire = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(wire["operation"] as? String == "resolve-track")
        #expect(wire["payload"] as? [String: String] == ["track": "T-A", "select": live])
        #expect((wire["confirmed"] as? [String])?.isEmpty == true)
    }

    @Test func olderCatalogWithoutCandidatesNeverOffersAnUnknownHead() throws {
        let catalog = try fixture(candidates: false)
        let conflict = try #require(SharedTrackConflict.project(catalog).first)
        #expect(conflict.choices.isEmpty)
        #expect(!conflict.isComplete)
        #expect(throws: LocalMusicError.self) { try conflict.request(catalog: catalog, selected: live) }
    }

    @Test(arguments: [
        ClusterMutationReply.accepted(request: "example", record: "record", host: "host", heads: ["track:T-A": ["record"]]),
        .needsReview(request: "example", current: ["track:T-A": ["current"]]),
        .rejected(request: "example", reason: .unauthorized),
        .unsupported(request: "example", operation: "resolve-track"),
        .deferred(request: "example", reason: "incomplete-history"),
    ])
    func repliesOnlyReportResolutionAfterAcceptance(_ reply: ClusterMutationReply) async throws {
        let catalog = try fixture()
        let conflict = try #require(SharedTrackConflict.project(catalog).first)
        let request = try conflict.request(catalog: catalog, selected: live)
        var sends = 0
        var refreshes = 0
        let result = try await SharedTrackResolution.perform(request, supported: true, send: { sent in
            sends += 1
            #expect(sent == request)
            return reply
        }, refresh: {
            refreshes += 1
            return LocalCatalog(id: "refreshed", name: "Refreshed", entries: [], logicalAudio: true)
        })
        #expect(sends == 1)
        #expect(result.reply == reply)
        switch reply {
        case .objectStored: Issue.record("An upload receipt cannot resolve a track")
        case .accepted:
            #expect(refreshes == 1)
            #expect(result.catalog?.id == "refreshed")
            #expect(result.notice == "選んだ内容を保存先に反映しました。")
        case .needsReview:
            #expect(refreshes == 1)
            #expect(result.catalog?.id == "refreshed")
            #expect(result.notice.contains("最新の内容"))
        case .rejected:
            #expect(refreshes == 0)
            #expect(result.notice.contains("権限がありません"))
            #expect(result.notice.contains("削除しない内容は選べます"))
            #expect(conflict.choices[0].isAvailable(isHost: false))
        case .unsupported:
            #expect(refreshes == 0)
            #expect(result.notice.contains("対応していません"))
        case .deferred:
            #expect(refreshes == 0)
            #expect(result.notice.contains("再試行"))
        }
    }

    @Test func v5HostWithoutResolveTrackNeverReceivesTheMutation() async throws {
        let catalog = try fixture()
        let conflict = try #require(SharedTrackConflict.project(catalog).first)
        let request = try conflict.request(catalog: catalog, selected: live)
        let result = try await SharedTrackResolution.perform(request, supported: false, send: { _ in
            Issue.record("An unsupported host must never receive a mutation")
            throw LocalMusicError.invalidData
        }, refresh: {
            Issue.record("An unsupported reply must not be reported as resolved or refreshed")
            throw LocalMusicError.invalidData
        })
        #expect(result.reply == .unsupported(request: request.request, operation: "resolve-track"))
    }

    @Test func acceptanceAndStaleReviewKeepTheirMeaningWhenRefreshFails() async throws {
        let catalog = try fixture()
        let conflict = try #require(SharedTrackConflict.project(catalog).first)
        let request = try conflict.request(catalog: catalog, selected: live)
        for reply in [
            ClusterMutationReply.accepted(request: request.request, record: "record", host: "host", heads: [:]),
            .needsReview(request: request.request, current: [:]),
        ] {
            let result = try await SharedTrackResolution.perform(request, supported: true,
                send: { _ in reply }, refresh: { throw LocalMusicError.disconnected })
            #expect(result.reply == reply)
            #expect(result.refreshFailed)
            #expect(result.notice.contains("ライブラリを更新"))
            #expect(result.notice != "選んだ内容を保存先に反映しました。")
        }
    }
}
