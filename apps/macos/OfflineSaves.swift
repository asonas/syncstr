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

    var isPending: Bool { [.waiting, .wifi, .saving].contains(state) }
}

extension LocalCatalog {
    var supportsOfflineSaves: Bool { source == .host }
}

extension Library {
    var showsOfflineSaveControls: Bool { localCatalog?.supportsOfflineSaves == true }

    func saveRequest(for tracks: [Track], scope: String) -> OfflineSaveRequest? {
        guard let catalog = localCatalog else { return nil }
        return transfer.saveRequests.first { $0.library == catalog.id && $0.id == scope }
            ?? (tracks.count == 1 ? transfer.saveRequests.last { request in
                request.library == catalog.id && request.entries.contains { $0.track.id == tracks[0].id }
                    && request.state != .complete && request.state != .cancelled
            } : nil)
    }
}

extension LocalEntry {
    var trackSaveIdentity: String { track.id + ":" + sha256 }
    var saveIdentity: String { sha256 }
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
            guard catalog.supportsOfflineSaves else { return }
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
            if let library = hostConnection?.library ?? retainedHostLibrary, updated[index].library != library { continue }
            let remaining = updated[index].entries.filter { !ids.contains($0.track.id) }
            if remaining.isEmpty {
                updated[index].state = .cancelled
            } else {
                updated[index].entries = remaining
                updated[index].completed.formIntersection(remaining.map { usesHostCatalog ? $0.trackSaveIdentity : $0.saveIdentity })
            }
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
            for index in restored.indices {
                let entries = restored[index].entries.filter(LocalMusicStore.valid)
                if entries.count != restored[index].entries.count {
                    restored[index].entries = entries
                    restored[index].completed.formIntersection(entries.flatMap { [$0.saveIdentity, $0.trackSaveIdentity] })
                    // The failure may have come from a dropped entry; let the worker check the rest again.
                    if restored[index].state == .failed {
                        restored[index].state = .waiting
                        restored[index].error = nil
                    }
                }
                if restored[index].state == .saving { restored[index].state = .waiting }
            }
            restored.removeAll { $0.entries.isEmpty }
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
        saveSource?.stop()
        saveSource = nil
    }

    func setSavesBackgrounded(_ backgrounded: Bool) {
        savesBackgrounded = backgrounded
        if backgrounded {
            stopSaveWorker()
        } else { resumeSaves() }
    }

    func resumeSaves(explicit: String? = nil) {
        guard !retainsHostCatalog, !savesBackgrounded, saveWorker == nil,
              saveRequests.contains(where: { (hostConnection == nil || $0.library == hostConnection?.library) && $0.isPending }) else { return }
        saveRetry?.cancel()
        saveRetry = nil
        let token = saveGeneration
        saveWorker = Task { [weak self] in
            guard let self else { return }
            var snapshotReadFailed = false
            var processableLibrary: String?
            defer {
                if saveGeneration == token {
                    saveWorker = nil
                    if saveRequests.contains(where: { (snapshotReadFailed || $0.library == processableLibrary) && $0.isPending }) {
                        let deadline = hostConnection.flatMap { self.hostAudioGate.deadline(for: $0.address.origin) }
                        let interval = saveRetryInterval
                        let gate = hostAudioGate
                        saveRetry = Task { [weak self] in
                            let now = gate.now()
                            let retryAt = max(now + interval, deadline ?? now)
                            do { try await gate.sleepUntil(retryAt); try Task.checkCancellation() } catch { return }
                            self?.resumeSaves()
                        }
                    }
                }
            }
            do {
                try Task.checkCancellation()
                guard saveGeneration == token else { return }
                guard let catalog = try await store.snapshotInBackground()?.catalog,
                      catalog.source != .host || hostConnection?.library == catalog.id else { return }
                try Task.checkCancellation()
                guard saveGeneration == token else { return }
                processableLibrary = catalog.id
                guard catalog.supportsOfflineSaves else {
                    let kept = saveRequests.filter { $0.library != catalog.id || !$0.isPending }
                    if kept.count != saveRequests.count { try persistSaves(kept) }
                    return
                }
                for index in saveRequests.indices {
                    guard saveRequests[index].library == catalog.id, saveRequests[index].isPending else { continue }
                    try Task.checkCancellation()
                    let request = saveRequests[index]
                    let automatic = request.id != explicit
                    var failure: String?
                    var waiting = false
                    for (position, requested) in request.entries.enumerated() {
                        var entry = requested
                        try Task.checkCancellation()
                        guard saveGeneration == token else { return }
                        saveRequests[index].completed.remove(entry.trackSaveIdentity)
                        do {
                            guard let current = catalog.entries.first(where: { $0.track.id == requested.track.id && $0.sha256 == requested.sha256 }) else {
                                throw LocalMusicError.invalidData
                            }
                            if hostConnection != nil {
                                entry = current
                                saveRequests[index].entries[position] = current
                            }
                            let saved = try await CatalogStorage.shared.perform { [files = store, entry, host = hostConnection != nil] in
                                try files.verifiedFile(entry, host: host, inventory: host ? files.database() : nil, requireHash: true) != nil
                            }
                            guard saveGeneration == token else { return }
                            if saved {
                                if hostConnection != nil { try store.database().saveAudioPin(entry) }
                                saveRequests[index].completed.insert(entry.trackSaveIdentity)
                                try persistSaves(saveRequests)
                                if hostConnection != nil { onSaved?() }
                                continue
                            }
                            let cached = try await playbackCache.fileInBackground(entry)
                            try Task.checkCancellation()
                            guard saveGeneration == token else { return }
                            var savedFromCache = false
                            if let cached { savedFromCache = try await protectCachedFile(cached, entry: entry) }
                            if !savedFromCache {
                                try Task.checkCancellation()
                                guard saveGeneration == token else { return }
                                if waiting { continue }
                                if let host = hostConnection, let deadline = hostAudioGate.deadline(for: host.address.origin),
                                   hostAudioGate.now() < deadline {
                                    waiting = true
                                    continue
                                }
                                if automatic && !permitsAutomaticSaveAudio {
                                    saveRequests[index].state = savePathIsCellular ? .wifi : .waiting
                                    waiting = true
                                    continue
                                }
                                saveRequests[index].state = .saving
                                saveRequests[index].error = nil
                                try persistSaves(saveRequests)
                                if let source = makeLibrarySource() {
                                    saveSource = source
                                    defer { source.stop(); if saveGeneration == token { saveSource = nil } }
                                    try await source.download(entry, cache: nil, diagnostic: nil) { _ in }
                                } else {
                                    waiting = true
                                    continue
                                }
                            }
                            try Task.checkCancellation()
                            guard saveGeneration == token else { return }
                            if hostConnection != nil { try store.database().saveAudioPin(entry) }
                            saveRequests[index].completed.insert(entry.trackSaveIdentity)
                            try persistSaves(saveRequests)
                            onSaved?()
                        } catch {
                            try Task.checkCancellation()
                            guard saveGeneration == token else { return }
                            if hostConnection != nil, error is URLError { waiting = true }
                            else if case HostAPIError.rateLimited = error { waiting = true }
                            else if case LocalMusicError.disconnected = error { waiting = true }
                            else if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
                                failure = "この端末の空き容量が不足しているため保存できません。空き容量を増やして再試行してください。"
                            } else { failure = error.localizedDescription }
                            saveRequests[index].error = error.localizedDescription
                        }
                    }
                    guard saveGeneration == token else { return }
                    let finished = saveRequests[index].entries.allSatisfy { self.saveRequests[index].completed.contains($0.trackSaveIdentity) }
                    saveRequests[index].state = finished ? .complete : failure != nil ? .failed : waiting ? (saveRequests[index].state == .wifi ? .wifi : .waiting) : .failed
                    if let failure { saveRequests[index].error = failure }
                    try persistSaves(saveRequests)
                }
            } catch is CancellationError {
                // Verified files already committed to storage remain protected.
            } catch {
                snapshotReadFailed = processableLibrary == nil
                if saveGeneration == token { status = "保存待ちを更新できませんでした。\(error.localizedDescription)" }
            }
        }
    }

    private func protectCachedFile(_ url: URL, entry: LocalEntry) async throws -> Bool {
        try await CatalogStorage.shared.perform { [store, host = hostConnection != nil] in
            try store.importCachedFile(url, entry: entry, host: host)
        }
    }
}

struct SavedAudioSummary: Equatable, Sendable {
    var pins: Set<SavedAudioPin> = []
    var bytes: Int64 = 0
}

extension LocalMusicStore {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "audio"]

    func audioFiles(for hashes: Set<String>) -> [String: [URL]] {
        guard !hashes.isEmpty else { return [:] }
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var files: [String: [URL]] = [:]
        for url in urls where Self.audioExtensions.contains(url.pathExtension) {
            let hash = url.deletingPathExtension().lastPathComponent
            if hashes.contains(hash) { files[hash, default: []].append(url) }
        }
        return files
    }

    func savedAudioSummary() throws -> SavedAudioSummary {
        let pins = try database().savedAudioPinList()
        let files = audioFiles(for: Set(pins.map(\.hash)))
        let bytes = files.values.reduce(Int64(0)) { total, urls in
            total + (urls.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.max().map(Int64.init) ?? 0)
        }
        return SavedAudioSummary(pins: pins, bytes: bytes)
    }
}

extension LocalTransfer {
    nonisolated static func discardAudio(_ hashes: Set<String>, store: LocalMusicStore, cache: LocalMusicStore,
                                         protectedURL: URL?, database: CatalogDatabase) throws {
        let protected = protectedURL?.resolvingSymlinksInPath().path
        for urls in Array(store.audioFiles(for: hashes).values) + Array(cache.audioFiles(for: hashes).values) {
            for url in urls where url.resolvingSymlinksInPath().path != protected {
                do { try FileManager.default.removeItem(at: url) }
                catch CocoaError.fileNoSuchFile {}
            }
        }
        for hash in hashes { try database.forgetAudio(hash: hash) }
    }

    func refreshSavedAudio() async {
        let files = store
        if let summary = try? await CatalogStorage.shared.perform({ try files.savedAudioSummary() }) { savedAudio = summary }
    }

    /// Removes the pins captured when the person confirmed. Pins saved later, for example by a library
    /// opened in another window, are not part of the target and stay.
    func removeSavedAudio(_ pins: Set<SavedAudioPin>) async throws {
        guard !pins.isEmpty else { return }
        try cancelSaves(covering: Set(pins.map(\.identity)))
        try await waitForIdle(until: .now.advanced(by: .seconds(15)))
        let requested = Set(saveRequests.filter { $0.state != .cancelled }.flatMap { $0.entries.map(\.sha256) })
        let files = store
        let cache = playbackCache.store
        let protectedURL = playbackCache.protectedURL
        try await CatalogStorage.shared.commit {
            let database = try files.database()
            let pinned = try database.removeAudioPins(pins)
            let unused = Set(pins.map(\.hash)).subtracting(pinned).subtracting(requested)
            try Self.discardAudio(unused, store: files, cache: cache, protectedURL: protectedURL, database: database)
        }
        onSaved?()
        await refreshSavedAudio()
        resumeSaves()
    }

    /// Cancels save work for the given track and hash pairs in every library.
    func cancelSaves(covering identities: Set<String>) throws {
        var updated = saveRequests
        var tracks = Set<String>()
        for index in updated.indices where updated[index].entries.contains(where: { identities.contains($0.trackSaveIdentity) }) {
            tracks.formUnion(updated[index].entries.filter { identities.contains($0.trackSaveIdentity) }.map(\.track.id))
            let remaining = updated[index].entries.filter { !identities.contains($0.trackSaveIdentity) }
            if remaining.isEmpty {
                updated[index].state = .cancelled
            } else {
                updated[index].entries = remaining
                updated[index].completed.formIntersection(remaining.map(\.trackSaveIdentity))
            }
        }
        try persistSaves(updated)
        for (scope, preparation) in preparingSaves where !preparation.tracks.isDisjoint(with: tracks) {
            preparation.task.cancel()
            preparingSaves.removeValue(forKey: scope)
        }
        stopSaveWorker()
    }
}

struct OfflineSaveControls: View {
    @ObservedObject var library: Library
    var tracks: [Track]
    var scope: String
    var compact = false
    var iconOnly = false

    private var request: OfflineSaveRequest? { library.saveRequest(for: tracks, scope: scope) }
    private var saved: Int { tracks.filter { library.hasManagedCopy($0) }.count }
    private var pending: Bool { request.map { [.waiting, .wifi, .saving].contains($0.state) } ?? false }
    private var removalPending: Bool { tracks.contains(where: library.isLocalCopyRemovalPending) }

    var body: some View {
        if compact || iconOnly {
            Menu {
                Text(saveStatus)
                if !removalPending {
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
                }
            } label: {
                Group {
                    if removalPending || (pending && saved < tracks.count) {
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
            if removalPending {
                Text("保存の解除待ち").font(.caption).foregroundStyle(.secondary)
            } else if pending, let request {
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
            if !compact && tracks.contains(where: library.canRemoveLocalCopy) && !pending && !removalPending {
                Button("この端末の保存を解除", role: .destructive) { library.localCopiesToRemove = tracks }
            }
        }
        .frame(maxWidth: compact ? 120 : nil, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(compact ? "\(tracks.first?.title ?? "")の保存" : "オフライン保存")
        }
    }

    private var saveStatus: String {
        if removalPending { return "保存の解除待ち" }
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
        ), presenting: library.localCopiesToRemove) { tracks in
            Button("キャンセル", role: .cancel) {}
            Button("保存を解除", role: .destructive) {
                let libraryID = library.localCatalog?.id
                Task { @MainActor in
                    guard library.localCatalog?.id == libraryID else { return }
                    library.removeLocalCopies(tracks)
                }
            }
        } message: { tracks in
            Text("\(tracks.count)曲の管理されたコピーを削除します。対象の曲は再生を停止します。共有ライブラリ、他の端末の音源、元のファイルは残ります。")
        }
    }
}
