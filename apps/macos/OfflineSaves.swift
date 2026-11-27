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
    /// Tracks whose stored rows were unreadable when the save was asked for. Their content is unknown
    /// until the catalog is read again. An older version decodes the queue without this field and writes it
    /// back, so these tracks are lost after a downgrade; keeping them through one is not a requirement.
    var unresolved: [Track] = []
    /// A save the person asked for, which may use cellular data. It stays manual across retries.
    var manual = false
    /// Track IDs that cannot be saved, such as a track the host removed. They are not tried again in this request.
    var failedTracks: Set<String> = []

    var isPending: Bool { [.waiting, .wifi, .saving].contains(state) }
    var trackCount: Int {
        entries.count + unresolved.count + failedTracks.filter { id in !entries.contains { $0.track.id == id } }.count
    }

    init(id: String, library: String, entries: [LocalEntry], completed: Set<String> = [], state: State = .waiting,
         error: String? = nil, unresolved: [Track] = [], manual: Bool = false) {
        self.id = id
        self.library = library
        self.entries = entries
        self.completed = completed
        self.state = state
        self.error = error
        self.unresolved = unresolved
        self.manual = manual
    }

    private enum CodingKeys: String, CodingKey { case id, library, entries, completed, state, error, unresolved, manual, failedTracks }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        library = try container.decode(String.self, forKey: .library)
        entries = try container.decode([LocalEntry].self, forKey: .entries)
        completed = try container.decode(Set<String>.self, forKey: .completed)
        state = try container.decode(State.self, forKey: .state)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        unresolved = try container.decodeIfPresent([Track].self, forKey: .unresolved) ?? []
        manual = try container.decodeIfPresent(Bool.self, forKey: .manual) ?? false
        failedTracks = try container.decodeIfPresent(Set<String>.self, forKey: .failedTracks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(library, forKey: .library)
        try container.encode(entries, forKey: .entries)
        try container.encode(completed, forKey: .completed)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(unresolved, forKey: .unresolved)
        try container.encode(manual, forKey: .manual)
        try container.encode(failedTracks, forKey: .failedTracks)
    }
}

extension Library {
    var showsOfflineSaveControls: Bool { localCatalog != nil }

    func saveRequest(for tracks: [Track], scope: String) -> OfflineSaveRequest? {
        guard let catalog = localCatalog else { return nil }
        if let own = transfer.saveRequests.first(where: { $0.library == catalog.id && $0.id == scope }) { return own }
        guard tracks.count == 1, let track = tracks.first, !hasManagedCopy(track),
              var request = transfer.saveRequests.last(where: { request in
                  request.library == catalog.id
                      && (request.entries.contains { $0.track.id == track.id } || request.unresolved.contains { $0.id == track.id }
                          || request.failedTracks.contains(track.id))
                      && request.state != .complete && request.state != .cancelled
              }) else { return nil }
        // A request of another scope, such as the album, describes this track only by the track's own state.
        if request.failedTracks.contains(track.id) {
            request.state = .failed
        } else if request.state == .failed {
            return nil
        }
        return request
    }

    /// A pending or failed save of this scope comes first: it can hold tracks that the displayed catalog lacks,
    /// so the shown tracks alone would look saved.
    func saveProgress(for tracks: [Track], scope: String) -> SaveProgress {
        let request = saveRequest(for: tracks, scope: scope)
        let pending = request?.isPending ?? false
        let failed = request?.state == .failed
        var total = tracks.count
        if pending || failed, let request, request.id == scope { total = max(total, request.trackCount) }
        return SaveProgress(saved: tracks.filter(hasManagedCopy).count, total: total, pending: pending, failed: failed)
    }
}

struct SaveProgress: Equatable {
    var saved: Int
    var total: Int
    var pending: Bool
    var failed = false
    var allSaved: Bool { !pending && !failed && total > 0 && saved == total }
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
            guard let snapshot else { throw LocalMusicError.invalidData }
            let catalog = snapshot.catalog
            try Task.checkCancellation()
            guard preparingSaves[scope]?.token == token else { return }
            let byID = Dictionary(catalog.entries.map { ($0.track.id, $0) }, uniquingKeysWith: { first, _ in first })
            // Asking again gives a track the host sent unusable another repair.
            unrepairableIDs.subtract(ids)
            if tracks.contains(where: { snapshot.unreadableIDs.contains($0.id) }) { resetCatalogRepairInterval() }
            // A retry carries the tracks of the earlier request, including ones the displayed list no longer shows.
            let previous = saveRequests.first { $0.library == catalog.id && $0.id == scope && $0.state != .cancelled && $0.state != .complete }
            var wanted = tracks
            var failedTracks = Set<String>()
            if let previous {
                wanted += previous.entries.map(\.track) + previous.unresolved
                let known = Set(wanted.map(\.id))
                for id in previous.failedTracks where !known.contains(id) {
                    if let entry = byID[id] { wanted.append(entry.track) } else { failedTracks.insert(id) }
                }
            }
            var entries: [LocalEntry] = []
            var unresolved: [Track] = []
            var seen = Set<String>()
            for track in wanted where seen.insert(track.id).inserted {
                if let entry = byID[track.id] { entries.append(entry) }
                // A missing track may be an unreadable row, so it waits for the catalog to be read again.
                else if snapshot.mayHold(track.id) { unresolved.append(track) }
                else if previous != nil { failedTracks.insert(track.id) }
                else { throw LocalMusicError.invalidData }
            }
            guard !entries.isEmpty || !unresolved.isEmpty else { throw LocalMusicError.invalidData }
            // A save asked for while everything is being removed is queued after the removal.
            if let removal = removingAllSaves {
                _ = await removal.result
                try Task.checkCancellation()
                guard preparingSaves[scope]?.token == token else { return }
            }
            stopSaveWorker()
            var updated = saveRequests.filter { $0.library != catalog.id || $0.id != scope }
            var request = OfflineSaveRequest(id: scope, library: catalog.id, entries: entries, unresolved: unresolved, manual: true)
            request.failedTracks = failedTracks
            if !failedTracks.isEmpty { request.error = LocalMusicError.invalidData.localizedDescription }
            updated.append(request)
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
        for index in updated.indices where updated[index].entries.contains(where: { ids.contains($0.track.id) })
            || updated[index].unresolved.contains(where: { ids.contains($0.id) }) {
            if let library = hostConnection?.library ?? retainedHostLibrary, updated[index].library != library { continue }
            let remaining = updated[index].entries.filter { !ids.contains($0.track.id) }
            updated[index].unresolved.removeAll { ids.contains($0.id) }
            if remaining.isEmpty && updated[index].unresolved.isEmpty {
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
            // Written only by an earlier build of this change; the queue now holds everything.
            try? FileManager.default.removeItem(at: store.root.appendingPathComponent("offline-saves-unresolved.json"))
            let url = store.root.appendingPathComponent("offline-saves.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            // A queue that cannot be decoded throws before anything is written, so the file is kept as it is.
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
            restored.removeAll { $0.entries.isEmpty && $0.unresolved.isEmpty && $0.failedTracks.isEmpty }
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
        guard !retainsHostCatalog, !savesBackgrounded, removingAllSaves == nil, saveWorker == nil,
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
                guard let snapshot = try await store.snapshotInBackground(),
                      hostConnection?.library == snapshot.catalog.id else { return }
                let catalog = snapshot.catalog
                try Task.checkCancellation()
                guard saveGeneration == token else { return }
                processableLibrary = catalog.id
                // A track the catalog lacks waits only while it may be one of the unreadable rows. A row the whole
                // catalog left unreadable is the host's, so its save fails instead of waiting for a repair.
                let unrepairable = unrepairableIDs
                func waitsForRepair(_ id: String) -> Bool { snapshot.mayHold(id) && !unrepairable.contains(id) }
                let repairable = snapshot.unreadableIDs.subtracting(unrepairable).count + snapshot.unreadableWithoutID
                if repairable > 0 { requestCatalogRepair(repairable, for: catalog.id) }
                let unusable = "ホストのライブラリにあるこの曲の情報を読み込めないため、保存できません。"
                let byID = Dictionary(catalog.entries.map { ($0.track.id, $0) }, uniquingKeysWith: { first, _ in first })
                for index in saveRequests.indices {
                    guard saveRequests[index].library == catalog.id, saveRequests[index].isPending else { continue }
                    try Task.checkCancellation()
                    let automatic = !saveRequests[index].manual && saveRequests[index].id != explicit
                    var failure: String?
                    // `waiting` keeps the request pending; `holdDownloads` stops fetching for the rest of it.
                    // A track that waits for the catalog only sets `waiting`, so healthy tracks after it still download.
                    var waiting = false
                    var holdDownloads = false
                    var stillUnresolved: [Track] = []
                    for track in saveRequests[index].unresolved {
                        if let entry = byID[track.id] {
                            if !saveRequests[index].entries.contains(where: { $0.track.id == track.id }) { saveRequests[index].entries.append(entry) }
                        } else if waitsForRepair(track.id) {
                            stillUnresolved.append(track)
                            waiting = true
                        } else {
                            saveRequests[index].failedTracks.insert(track.id)
                            failure = unrepairable.contains(track.id) ? unusable : LocalMusicError.invalidData.localizedDescription
                        }
                    }
                    saveRequests[index].unresolved = stillUnresolved
                    let request = saveRequests[index]
                    for (position, requested) in request.entries.enumerated() {
                        var entry = requested
                        try Task.checkCancellation()
                        guard saveGeneration == token else { return }
                        if request.failedTracks.contains(requested.track.id) {
                            failure = failure ?? request.error ?? LocalMusicError.invalidData.localizedDescription
                            continue
                        }
                        saveRequests[index].completed.remove(entry.trackSaveIdentity)
                        do {
                            guard let current = byID[requested.track.id], current.sha256 == requested.sha256 else {
                                if byID[requested.track.id] == nil && waitsForRepair(requested.track.id) { waiting = true; continue }
                                saveRequests[index].failedTracks.insert(requested.track.id)
                                if unrepairable.contains(requested.track.id) {
                                    failure = unusable
                                    continue
                                }
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
                            // Released on every exit from this entry, including cancellation just below.
                            defer { if let cached { playbackCache.release(cached) } }
                            try Task.checkCancellation()
                            guard saveGeneration == token else { return }
                            var savedFromCache = false
                            if let cached { savedFromCache = try await protectCachedFile(cached, entry: entry) }
                            if !savedFromCache {
                                try Task.checkCancellation()
                                guard saveGeneration == token else { return }
                                if holdDownloads { continue }
                                if let host = hostConnection, let deadline = hostAudioGate.deadline(for: host.address.origin),
                                   hostAudioGate.now() < deadline {
                                    waiting = true
                                    holdDownloads = true
                                    continue
                                }
                                if automatic && !permitsAutomaticSaveAudio {
                                    saveRequests[index].state = savePathIsCellular ? .wifi : .waiting
                                    waiting = true
                                    holdDownloads = true
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
                                    holdDownloads = true
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
                            if hostConnection != nil, error is URLError { waiting = true; holdDownloads = true }
                            else if case HostAPIError.rateLimited = error { waiting = true; holdDownloads = true }
                            else if case LocalMusicError.disconnected = error { waiting = true; holdDownloads = true }
                            else {
                                // A track that cannot be saved is not tried again in this request, so a request
                                // still waiting for other tracks does not repeat a download that fails.
                                saveRequests[index].failedTracks.insert(requested.track.id)
                                failure = (error as? CocoaError)?.code == .fileWriteOutOfSpace
                                    ? "この端末の空き容量が不足しているため保存できません。空き容量を増やして再試行してください。"
                                    : error.localizedDescription
                            }
                            saveRequests[index].error = error.localizedDescription
                        }
                    }
                    guard saveGeneration == token else { return }
                    // A track that failed, including one still missing from a whole catalog, keeps the request from completing.
                    let finished = saveRequests[index].unresolved.isEmpty && saveRequests[index].failedTracks.isEmpty
                        && saveRequests[index].entries.allSatisfy { self.saveRequests[index].completed.contains($0.trackSaveIdentity) }
                    // A request fails only when no track can still progress.
                    saveRequests[index].state = finished ? .complete : waiting ? (saveRequests[index].state == .wifi ? .wifi : .waiting) : .failed
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
    /// Audio in the saved folder that no pin names, such as a file whose removal failed.
    var unpinnedFiles = 0
}

extension LocalMusicStore {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "audio"]

    /// A stored audio file is named by its content hash and an audio extension.
    static func isAudioFileName(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension) && SHA256Hex.isValid(url.deletingPathExtension().lastPathComponent)
    }

    /// Every audio file in the folder by hash, or only those of `hashes`. A missing folder holds no files;
    /// any other listing failure throws, so a caller never mistakes an unreadable folder for an empty one.
    func audioFiles(for hashes: Set<String>? = nil) throws -> [String: [URL]] {
        if hashes?.isEmpty == true { return [:] }
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) }
        catch CocoaError.fileReadNoSuchFile { return [:] }
        catch CocoaError.fileNoSuchFile { return [:] }
        var files: [String: [URL]] = [:]
        for url in urls where Self.isAudioFileName(url) {
            let hash = url.deletingPathExtension().lastPathComponent
            guard hashes?.contains(hash) ?? true,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files[hash, default: []].append(url)
        }
        return files
    }

    func savedAudioSummary() throws -> SavedAudioSummary {
        let pins = try database().savedAudioPinList()
        let pinned = Set(pins.map(\.hash))
        let all = try audioFiles()
        let bytes = all.values.joined().reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return SavedAudioSummary(pins: pins, bytes: bytes, unpinnedFiles: all.keys.filter { !pinned.contains($0) }.count)
    }
}

extension LocalTransfer {
    /// Removes the files before the pins. A pin whose file could not be removed stays, so the saved music
    /// keeps showing as saved and a later removal can try again. Returns those pins.
    nonisolated static func discard(_ pins: Set<SavedAudioPin>, keeping requested: Set<String>, store: LocalMusicStore,
                                    cache: LocalMusicStore, protected: Set<String>, database: CatalogDatabase) throws -> Set<SavedAudioPin> {
        let held = Set(try database.savedAudioPinList().subtracting(pins).map(\.hash)).union(requested)
        let unused = Set(pins.map(\.hash)).subtracting(held)
        var failed = Set<String>()
        for (hash, urls) in try store.audioFiles(for: unused).merging(try cache.audioFiles(for: unused), uniquingKeysWith: +) {
            for url in urls where !protected.contains(url.resolvingSymlinksInPath().path) {
                do { try FileManager.default.removeItem(at: url) }
                catch CocoaError.fileNoSuchFile {}
                catch { failed.insert(hash) }
            }
        }
        let kept = pins.filter { failed.contains($0.hash) }
        _ = try database.removeAudioPins(pins.subtracting(kept))
        for hash in unused.subtracting(failed) { try database.forgetAudio(hash: hash) }
        return kept
    }

    /// Removes every saved audio file in the saved folder, then the pins of the files that are gone.
    /// Returns the hashes whose files stayed. The playback cache and artwork are not touched.
    nonisolated static func discardAll(store: LocalMusicStore, protected: Set<String>, database: CatalogDatabase) throws -> Set<String> {
        let files = try store.audioFiles()
        var failed = Set<String>()
        for (hash, urls) in files {
            for url in urls {
                if protected.contains(url.resolvingSymlinksInPath().path) { failed.insert(hash); continue }
                do { try store.removeFile(url) }
                catch CocoaError.fileNoSuchFile {}
                catch { failed.insert(hash) }
            }
        }
        _ = try database.removeAudioPins(try database.savedAudioPinList().filter { !failed.contains($0.hash) })
        for hash in Set(files.keys).subtracting(failed) { try database.forgetAudio(hash: hash) }
        return failed
    }

    /// Hashes that a save still in the queue can reuse.
    var requestedAudio: Set<String> {
        Set(saveRequests.filter { $0.state != .cancelled }.flatMap { $0.entries.map(\.sha256) })
    }

    func refreshSavedAudio() async {
        let files = store
        if let summary = try? await CatalogStorage.shared.perform({ try files.savedAudioSummary() }) { savedAudio = summary }
    }

    /// Removes every save on this device: the queue, the pins and the saved files.
    /// A second call while one runs waits for it, so no save can start between them.
    /// `beforeRemoving` runs once no save is running and before any file is removed.
    func removeAllSavedAudio(beforeRemoving: @escaping @MainActor () -> Void = {}) async throws {
        if let running = removingAllSaves { return try await running.value }
        let task = Task { @MainActor in try await self.discardAllSaves(beforeRemoving: beforeRemoving) }
        removingAllSaves = task
        let result = await task.result
        removingAllSaves = nil
        onSaved?()
        await refreshSavedAudio()
        resumeSaves()
        try result.get()
    }

    private func discardAllSaves(beforeRemoving: @MainActor () -> Void) async throws {
        cancelSavePreparations()
        let worker = saveWorker
        stopSaveWorker()
        // Waiting for the worker itself, not a flag: a download finishing now pins its file before the removal.
        await worker?.value
        beforeRemoving()
        let files = store
        let protected = playbackCache.protectedPaths
        let failed = try await CatalogStorage.shared.commit {
            try Self.discardAll(store: files, protected: protected, database: files.database())
        }
        // A request stays only for files that could not be removed, so they can be removed again later.
        let kept = saveRequests.compactMap { request -> OfflineSaveRequest? in
            var request = request
            request.entries = request.entries.filter { failed.contains($0.sha256) }
            request.unresolved = []
            guard !request.entries.isEmpty else { return nil }
            request.completed.formIntersection(request.entries.map(\.trackSaveIdentity))
            request.failedTracks.formIntersection(request.entries.map(\.track.id))
            // Kept only so the leftover files can be removed again; it must not start saving them.
            if request.isPending { request.state = request.failedTracks.isEmpty ? .complete : .failed }
            return request
        }
        // The queue file sits in the same folder; when nothing could be removed, writing it would fail the same way.
        let stateOf = { (requests: [OfflineSaveRequest]) in requests.map { [$0.state.rawValue] + $0.failedTracks.sorted() } }
        if kept.map(\.entries) != saveRequests.map(\.entries) || saveRequests.contains(where: { !$0.unresolved.isEmpty })
            || stateOf(kept) != stateOf(saveRequests) {
            // Kept in memory even when the write fails, so the leftovers are not saved again in this session.
            do { try persistSaves(kept) } catch { saveRequests = kept; throw error }
        }
        if !failed.isEmpty { throw LocalMusicError.removalIncomplete }
    }
}

struct OfflineSaveControls: View {
    @ObservedObject var library: Library
    var tracks: [Track]
    var scope: String
    var compact = false
    var iconOnly = false

    private var request: OfflineSaveRequest? { library.saveRequest(for: tracks, scope: scope) }
    private var progress: SaveProgress { library.saveProgress(for: tracks, scope: scope) }
    private var saved: Int { progress.saved }
    private var pending: Bool { progress.pending }
    private var total: Int { progress.total }
    private var allSaved: Bool { progress.allSaved }
    private var removalPending: Bool { tracks.contains(where: library.isLocalCopyRemovalPending) }

    var body: some View {
        if compact || iconOnly {
            Menu {
                Text(saveStatus)
                if !removalPending {
                    if let request, let error = request.error { Text(error) }
                    if pending, let request {
                        Button(request.trackCount > tracks.count ? "アルバム全体の保存を中止" : "保存を中止") {
                            library.transfer.cancelSave(request)
                        }
                    } else if saved < total {
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
                    if removalPending || (pending && saved < total) {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(allSaved ? "regen-circle-check" : request?.state == .failed ? "regen-circle-alert" : compact ? "regen-dots" : "regen-cloud-download")
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
                if !compact { Text("\(saved)/\(total)曲を保存済み").font(.caption).monospacedDigit() }
                Button(compact && request.trackCount > 1 ? "アルバム保存を中止" : "保存を中止") { library.transfer.cancelSave(request) }
                if !compact, let error = request.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            } else if allSaved {
                Text(compact ? "保存済み" : "\(saved)曲を保存済み").font(.caption).foregroundStyle(.secondary)
            } else {
                if saved > 0 { Text("\(saved)/\(total)曲を保存済み").font(.caption) }
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
        if allSaved { return "保存済み" }
        switch request?.state {
        case .wifi: return "Wi-Fi接続待ち"
        case .waiting: return "接続待ち"
        case .saving: return "保存中・\(saved)/\(total)曲を保存済み"
        case .failed: return "保存できませんでした"
        default: return saved > 0 ? "\(saved)/\(total)曲を保存済み" : "未保存"
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
