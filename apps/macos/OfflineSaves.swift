import Foundation
import SwiftUI

struct OfflineSaveRequest: Codable, Identifiable {
    enum State: String, Codable { case waiting, wifi, saving, failed, cancelled, complete }
    var id: String
    var library: String
    var entries: [LocalEntry]
    var completed: Set<String> = []
    var state: State = .waiting
    var error: String?
}

extension Library {
    func saveRequest(for tracks: [Track], scope: String) -> OfflineSaveRequest? {
        guard let catalog = localCatalog else { return nil }
        return transfer.saveRequests.first { $0.library == catalog.id && $0.id == scope }
            ?? (tracks.count == 1 ? transfer.saveRequests.last { request in
                request.library == catalog.id && request.entries.contains { $0.track.id == tracks[0].id }
                    && request.state != .complete && request.state != .cancelled
            } : nil)
    }
}

extension LocalTransfer {
    func requestSave(_ tracks: [Track], scope: String) async {
        guard !Task.isCancelled else { return }
        let ids = Set(tracks.map(\.id))
        if let pending = preparingSaves[scope] {
            if pending.tracks == ids, !pending.task.isCancelled { return }
            pending.task.cancel()
        }
        let token = UUID()
        let store = store
        let preparation = Task { try await store.snapshotInBackground() }
        preparingSaves[scope] = (token, ids, preparation)
        defer { if preparingSaves[scope]?.token == token { preparingSaves.removeValue(forKey: scope) } }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            guard let catalog = snapshot?.catalog else { throw LocalMusicError.invalidData }
            try Task.checkCancellation()
            guard preparingSaves[scope]?.token == token else { return }
            let entries = catalog.entries.filter { ids.contains($0.track.id) }
            guard entries.count == ids.count, !entries.isEmpty else { throw LocalMusicError.invalidData }
            stopSaveWorker()
            var updated = saveRequests.filter { $0.library != catalog.id || $0.id != scope }
            updated.append(OfflineSaveRequest(id: scope, library: catalog.id, entries: entries))
            try persistSaves(updated)
            resumeSaves(explicit: scope)
        } catch is CancellationError {
            return
        } catch {
            if preparingSaves[scope]?.token == token { status = error.localizedDescription }
        }
    }

    func cancelSavePreparations() {
        for preparation in preparingSaves.values { preparation.task.cancel() }
        preparingSaves.removeAll()
    }

    func cancelSave(_ request: OfflineSaveRequest) {
        var updated = saveRequests
        guard let index = updated.firstIndex(where: { $0.id == request.id && $0.library == request.library }) else { return }
        updated[index].state = .cancelled
        do {
            try persistSaves(updated)
            preparingSaves.removeValue(forKey: request.id)?.task.cancel()
            stopSaveWorker()
            resumeSaves()
        } catch { status = error.localizedDescription }
    }

    func cancelSaves(containing tracks: [Track]) throws {
        let ids = Set(tracks.map(\.id))
        var updated = saveRequests
        for index in updated.indices where updated[index].entries.contains(where: { ids.contains($0.track.id) }) {
            updated[index].state = .cancelled
        }
        try persistSaves(updated)
        for (scope, preparation) in preparingSaves where !preparation.tracks.isDisjoint(with: ids) {
            preparation.task.cancel()
            preparingSaves.removeValue(forKey: scope)
        }
        stopSaveWorker()
    }

    func restoreSaves() {
        do {
            let url = store.root.appendingPathComponent("offline-saves.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var restored = try JSONDecoder().decode([OfflineSaveRequest].self, from: Data(contentsOf: url))
            guard restored.allSatisfy({ !$0.entries.isEmpty && $0.entries.allSatisfy(LocalMusicStore.valid) }) else {
                throw LocalMusicError.invalidData
            }
            for index in restored.indices where restored[index].state == .saving { restored[index].state = .waiting }
            try persistSaves(restored)
        } catch { status = "保存待ちを読み込めませんでした。\(error.localizedDescription)" }
    }

    private func persistSaves(_ requests: [OfflineSaveRequest]) throws {
        try store.prepare()
        try JSONEncoder().encode(requests).write(to: store.root.appendingPathComponent("offline-saves.json"), options: .atomic)
        saveRequests = requests
    }

    func stopSaveWorker() {
        saveGeneration = UUID()
        saveWorker?.cancel()
        saveWorker = nil
        saveRetry?.cancel()
        saveRetry = nil
        saveNetwork?.stop()
        saveNetwork = nil
    }

    func setSavesBackgrounded(_ backgrounded: Bool) {
        savesBackgrounded = backgrounded
        if backgrounded { stopSaveWorker() }
        else { resumeSaves() }
    }

    func resumeSaves(explicit: String? = nil) {
        guard !savesBackgrounded, saveWorker == nil,
              saveRequests.contains(where: { [.waiting, .wifi, .saving].contains($0.state) }) else { return }
        saveRetry?.cancel()
        let token = saveGeneration
        saveWorker = Task { [weak self] in
            guard let self else { return }
            defer {
                if saveGeneration == token {
                    saveWorker = nil
                    if saveRequests.contains(where: { [.waiting, .wifi, .saving].contains($0.state) }) {
                        saveRetry = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(15)) } catch { return }
                            self?.resumeSaves()
                        }
                    }
                }
            }
            do {
                try Task.checkCancellation()
                guard saveGeneration == token else { return }
                guard let catalog = try await store.snapshotInBackground()?.catalog else { return }
                try Task.checkCancellation()
                guard saveGeneration == token else { return }
                for index in saveRequests.indices {
                    guard saveRequests[index].library == catalog.id,
                          [.waiting, .wifi, .saving].contains(saveRequests[index].state) else { continue }
                    try Task.checkCancellation()
                    let request = saveRequests[index]
                    let automatic = request.id != explicit
                    var failure: String?
                    var waiting = false
                    for entry in request.entries {
                        try Task.checkCancellation()
                        guard saveGeneration == token else { return }
                        saveRequests[index].completed.remove(entry.sha256)
                        do {
                            guard catalog.entries.contains(where: { $0.track.id == entry.track.id && $0.sha256 == entry.sha256 }) else {
                                throw LocalMusicError.invalidData
                            }
                            if store.hasFile(entry), try LocalMusicStore.digest(file: store.fileURL(entry)) == entry.sha256 {
                                if clusterRegistration != nil {
                                    try await ClusterNetwork(store: store, secrets: peerSecrets).recoverDownloadedFile(entry)
                                }
                                saveRequests[index].completed.insert(entry.sha256)
                                try persistSaves(saveRequests)
                                continue
                            }
                            if let cached = try playbackCache.file(entry) {
                                try await protectCachedFile(cached, entry: entry)
                            } else {
                                if waiting { continue }
                                if automatic && !permitsAutomaticSaveAudio {
                                    saveRequests[index].state = savePathIsCellular ? .wifi : .waiting
                                    waiting = true
                                    continue
                                }
                                saveRequests[index].state = .saving
                                saveRequests[index].error = nil
                                try persistSaves(saveRequests)
                                if clusterRegistration != nil {
                                    let network = ClusterNetwork(store: store, secrets: peerSecrets)
                                    saveNetwork = network
                                    defer { network.stop(); if saveGeneration == token { saveNetwork = nil } }
                                    try await network.download(object: entry.sha256) { _ in }
                                } else if connected && !busy {
                                    let cached = try await playbackFile(entry.track)
                                    try Task.checkCancellation()
                                    try await protectCachedFile(cached, entry: entry)
                                } else {
                                    waiting = true
                                    continue
                                }
                            }
                            try Task.checkCancellation()
                            guard saveGeneration == token else { return }
                            saveRequests[index].completed.insert(entry.sha256)
                            try persistSaves(saveRequests)
                            onSaved?()
                        } catch {
                            try Task.checkCancellation()
                            guard saveGeneration == token else { return }
                            if case LocalMusicError.clusterUnavailable = error { waiting = true }
                            else if case LocalMusicError.disconnected = error { waiting = true }
                            else if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
                                failure = "この端末の空き容量が不足しているため保存できません。空き容量を増やして再試行してください。"
                            } else { failure = error.localizedDescription }
                            saveRequests[index].error = error.localizedDescription
                        }
                    }
                    guard saveGeneration == token else { return }
                    let finished = request.entries.allSatisfy { self.saveRequests[index].completed.contains($0.sha256) }
                    saveRequests[index].state = finished ? .complete : failure != nil ? .failed : waiting ? (saveRequests[index].state == .wifi ? .wifi : .waiting) : .failed
                    if let failure { saveRequests[index].error = failure }
                    try persistSaves(saveRequests)
                }
            } catch is CancellationError {
                // Verified files already committed to storage remain protected.
            } catch {
                if saveGeneration == token { status = "保存待ちを更新できませんでした。\(error.localizedDescription)" }
            }
        }
    }

    private func protectCachedFile(_ url: URL, entry: LocalEntry) async throws {
        let temporary = store.root.appendingPathComponent(".offline-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: url, to: temporary)
        try store.importFile(temporary, entry: entry)
        if clusterRegistration != nil {
            try await ClusterNetwork(store: store, secrets: peerSecrets).recoverDownloadedFile(entry)
        }
    }
}

struct OfflineSaveControls: View {
    @ObservedObject var library: Library
    var tracks: [Track]
    var scope: String
    var compact = false
    var iconOnly = false

    private var request: OfflineSaveRequest? { library.saveRequest(for: tracks, scope: scope) }
    private var saved: Int { tracks.filter { library.localFiles[$0.id] != nil }.count }
    private var pending: Bool { request.map { [.waiting, .wifi, .saving].contains($0.state) } ?? false }

    var body: some View {
        if compact || iconOnly {
            Menu {
                Text(saveStatus)
                if let request, let error = request.error { Text(error) }
                if pending, let request {
                    Button(request.entries.count > tracks.count ? "アルバム全体の保存を中止" : "保存を中止") {
                        library.transfer.cancelSave(request)
                    }
                } else if saved < tracks.count {
                    Button(request?.state == .failed ? "保存を再試行" : "この端末に保存") {
                        Task { await library.transfer.requestSave(tracks, scope: scope) }
                    }
                }
                if !pending && tracks.contains(where: library.canRemoveLocalCopy) {
                    Button("この端末の保存を解除", role: .destructive) { library.localCopiesToRemove = tracks }
                }
            } label: {
                Group {
                    if pending && saved < tracks.count {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(saved == tracks.count && !tracks.isEmpty ? "regen-circle-check" : request?.state == .failed ? "regen-circle-alert" : compact ? "regen-dots" : "regen-cloud-download")
                            .resizable().renderingMode(.template).scaledToFit().frame(width: 20, height: 20)
                    }
                }
#if os(iOS)
                .frame(width: 44, height: 44)
#else
                .frame(width: 36, height: 36)
#endif
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(compact ? "\(tracks.first?.title ?? "")の保存操作" : "アルバムの保存操作")
            .accessibilityValue(saveStatus)
            .help(saveStatus)
        } else {
        VStack(alignment: .leading, spacing: 4) {
            if pending, let request {
                Text(request.state == .wifi ? "Wi-Fi接続待ち" : request.state == .saving ? "保存中" : "接続待ち")
                    .font(.caption).foregroundStyle(.secondary)
                if !compact { Text("\(saved)/\(tracks.count)曲を保存済み").font(.caption).monospacedDigit() }
                Button(compact && request.entries.count > 1 ? "アルバム保存を中止" : "保存を中止") { library.transfer.cancelSave(request) }
                if !compact, let error = request.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            } else if saved == tracks.count && !tracks.isEmpty {
                Text(compact ? "保存済み" : "\(saved)曲を保存済み").font(.caption).foregroundStyle(.secondary)
            } else {
                if saved > 0 { Text("\(saved)/\(tracks.count)曲を保存済み").font(.caption) }
                if let request, request.state == .failed {
                    Text(compact ? "保存できませんでした" : request.error ?? "保存できませんでした").font(.caption).foregroundStyle(.secondary)
                        .help(request.error ?? "保存できませんでした")
                }
                Button {
                    Task { await library.transfer.requestSave(tracks, scope: scope) }
                } label: {
                    if iconOnly {
                        Image("regen-cloud-download").resizable().renderingMode(.template)
                            .scaledToFit().frame(width: 20, height: 20)
#if os(iOS)
                            .frame(minWidth: 44, minHeight: 44)
#else
                            .frame(width: 32, height: 32)
#endif
                    } else {
                        Text(request?.state == .failed ? "保存を再試行" : compact ? "保存" : "この端末に保存")
                    }
                }
                .accessibilityLabel(request?.state == .failed ? "保存を再試行" : "この端末に保存")
                .help(request?.state == .failed ? "保存を再試行" : "この端末に保存")
            }
            if !compact && tracks.contains(where: library.canRemoveLocalCopy) && !pending {
                Button("この端末の保存を解除", role: .destructive) { library.localCopiesToRemove = tracks }
            }
        }
        .frame(maxWidth: compact ? 120 : nil, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(compact ? "\(tracks.first?.title ?? "")の保存" : "オフライン保存")
        }
    }

    private var saveStatus: String {
        if saved == tracks.count && !tracks.isEmpty { return "保存済み" }
        switch request?.state {
        case .wifi: return "Wi-Fi接続待ち"
        case .waiting: return "接続待ち"
        case .saving: return "保存中・\(saved)/\(tracks.count)曲を保存済み"
        case .failed: return "保存できませんでした"
        default: return saved > 0 ? "\(saved)/\(tracks.count)曲を保存済み" : "未保存"
        }
    }
}

struct OfflineSaveRemoval: ViewModifier {
    @ObservedObject var library: Library
    var enabled = true

    func body(content: Content) -> some View {
        content.alert("この端末の保存を解除しますか？", isPresented: Binding(
            get: { enabled && !library.localCopiesToRemove.isEmpty },
            set: { if !$0 { library.localCopiesToRemove = [] } }
        )) {
            Button("キャンセル", role: .cancel) {}
            Button("保存を解除", role: .destructive) { library.removeLocalCopies() }
        } message: {
            Text("\(library.localCopiesToRemove.count)曲の管理されたコピーを削除します。対象の曲は再生を停止します。共有ライブラリ、他の端末の音源、元のファイルは残ります。")
        }
    }
}
