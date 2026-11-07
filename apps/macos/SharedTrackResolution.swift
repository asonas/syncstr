import Foundation

struct SharedTrackConflict: Identifiable {
    struct Choice: Identifiable {
        let id: String
        let track: SharedAudioSnapshot.Catalog.LogicalTrack
        var title: String { track.metadata.title ?? track.metadata.legacyEntry?.title ?? track.id }
        func isAvailable(isHost: Bool) -> Bool { !track.retired || isHost }
    }
    let id: String
    let heads: [String]
    let choices: [Choice]
    var isComplete: Bool { heads.count > 1 && choices.count == heads.count }

    static func project(_ catalog: SharedAudioSnapshot.Catalog) throws -> [Self] {
        try catalog.conflicts.sorted().compactMap { subject in
            guard subject.hasPrefix("track:") else { return nil }
            let track = String(subject.dropFirst("track:".count))
            let heads = catalog.heads?[subject] ?? []
            guard let candidates = catalog.candidates?[track] else {
                return Self(id: track, heads: heads, choices: [])
            }
            guard heads.count > 1, heads.count <= 64, Set(heads).count == heads.count,
                  Set(candidates.keys) == Set(heads), candidates.values.allSatisfy({ $0.id == track }) else {
                throw LocalMusicError.invalidData
            }
            return Self(id: track, heads: heads, choices: heads.map { Choice(id: $0, track: candidates[$0]!) })
        }
    }

    func request(catalog: SharedAudioSnapshot.Catalog, selected: String) throws -> ClusterMutationRequest {
        guard isComplete, choices.contains(where: { $0.id == selected }) else { throw LocalMusicError.invalidData }
        struct Payload: Encodable { let track: String; let select: String }
        return try ClusterMutationRequest(cluster: catalog.cluster, baseline: catalog.baseline,
            operation: .resolveTrack, expected: ["track:" + id: heads],
            payload: Payload(track: id, select: selected), confirmed: [String]())
    }
}

@MainActor
enum SharedTrackResolution {
    struct Result {
        let reply: ClusterMutationReply
        var catalog: LocalCatalog?
        var refreshFailed = false

        var notice: String {
            switch reply {
            case .accepted:
                return refreshFailed ? "競合の解消は受け付けられました。ライブラリを更新して結果を確認してください。"
                    : "選んだ内容を保存先に反映しました。"
            case .needsReview:
                return refreshFailed ? "別の変更が届いています。ライブラリを更新して、もう一度内容を確認してください。"
                    : "別の変更が届いています。最新の内容を確認して、もう一度選んでください。"
            case .rejected(_, let reason):
                switch reason {
                case .unauthorized: return "この内容を優先する権限がありません。削除を優先する場合は保存先の端末で解消してください。削除しない内容は選べます。"
                case .revoked: return "この端末の登録が取り消されています。ライブラリの管理者に確認してください。"
                default: return "選んだ内容を反映できませんでした。ライブラリを更新して内容を確認してください。"
                }
            case .deferred: return "保存先でまだ変更を確認できません。競合の解消を再試行してください。"
            case .unsupported: return "この接続先は競合の解消に対応していません。接続先のSyncstrを更新してください。"
            }
        }
    }

    static func perform(_ request: ClusterMutationRequest, supported: Bool,
                        send: (ClusterMutationRequest) async throws -> ClusterMutationReply,
                        refresh: () async throws -> LocalCatalog) async throws -> Result {
        guard supported else {
            return Result(reply: .unsupported(request: request.request, operation: request.operation.rawValue))
        }
        let reply = try await send(request)
        var result = Result(reply: reply)
        switch reply {
        case .accepted, .needsReview:
            do { result.catalog = try await refresh() }
            catch { try Task.checkCancellation(); result.refreshFailed = true }
        default: break
        }
        return result
    }
}
