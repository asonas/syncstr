import Foundation

@MainActor
final class HostAudioFiles {
    private var active = Set<String>()
    private var waiters: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var verified: [String: URL] = [:]

    /// With `save`, the file goes into the saved folder together with its pin; otherwise it goes into `store`
    /// (the playback cache) with no records.
    func download(_ entry: LocalEntry, into store: LocalMusicStore, save: Bool, client: HostAPIClient,
                  diagnostic: PlaybackDiagnosticContext?) async throws {
        try Task.checkCancellation()
        let hash = entry.sha256
        while !active.insert(hash).inserted {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waiters[hash, default: [:]][id] = continuation }
                }
            } onCancel: {
                Task { @MainActor in
                    self.waiters[hash]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
            try Task.checkCancellation()
        }
        defer {
            active.remove(hash)
            if let waiting = waiters.removeValue(forKey: hash) {
                for continuation in waiting.values { continuation.resume() }
            }
        }
        let previous = verified[hash]
        let destination = store.fileURL(entry)
        let reuse: @Sendable () throws -> URL? = {
            if let url = try store.verifiedFile(entry, host: save) {
                if save { try store.database().saveAudioPin(entry) }
                return url
            }
            guard let previous, FileManager.default.fileExists(atPath: previous.path) else { return nil as URL? }
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: copy) }
            try FileManager.default.copyItem(at: previous, to: copy)
            do { try store.importFile(copy, entry: entry, recordReceipt: save, host: true, pin: save, diagnostic: diagnostic) }
            catch LocalMusicError.invalidData { return nil }
            return destination
        }
        if let existing = try await save ? CatalogStorage.shared.commitSavedFile(reuse) : CatalogStorage.shared.perform(reuse) {
            verified[hash] = existing
            return
        }
        for attempt in 0...1 {
            diagnostic?.record("request", "host_audio", fields: ["sha256": hash, "attempt": String(attempt + 1)])
            let temporary = try await client.audio(sha256: hash)
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let place: @Sendable () throws -> Void = {
                    try store.importFile(temporary, entry: entry, recordReceipt: save, host: true, pin: save, diagnostic: diagnostic)
                }
                if save { try await CatalogStorage.shared.commitSavedFile(place) }
                else { try await CatalogStorage.shared.perform(place) }
                verified[hash] = destination
                return
            } catch LocalMusicError.invalidData where attempt == 0 { continue }
        }
        throw LocalMusicError.invalidData
    }
}

@MainActor
final class HostLibrarySource: LibrarySource {
    private let client: HostAPIClient
    private let store: LocalMusicStore
    private let files: HostAudioFiles
    private let etag: String?
    private var stopped = false
    private var downloads: [UUID: Task<Void, Error>] = [:]
    private var pending: ArraySlice<(String, @MainActor (String, URL) -> Void)> = []
    private var queued = Set<String>()
    private var retryAfter: [String: ContinuousClock.Instant] = [:]
    private var fetching: [String: Task<Void, Never>] = [:]
    private var failed = Set<String>()

    init(host: HostConnection, configuration: URLSessionConfiguration, store: LocalMusicStore, files: HostAudioFiles,
         audioGate: HostAudioGate,
         switchObserved: @escaping @Sendable (String) -> Void) {
        client = HostAPIClient(address: host.address, configuration: configuration, audioGate: audioGate, switchObserved: switchObserved)
        self.store = store
        self.files = files
        etag = host.etag
    }

    func refreshCatalog() async throws -> CatalogRefresh {
        try await client.catalog(etag: etag)
    }

    func download(_ entry: LocalEntry, cache: LocalMusicStore?, diagnostic: PlaybackDiagnosticContext?,
                  progress: @escaping @MainActor (Double) -> Void) async throws {
        guard !stopped else { throw CancellationError() }
        progress(0)
        let id = UUID()
        let task = Task { [store] in
            try await files.download(entry, into: cache ?? store, save: cache == nil, client: client, diagnostic: diagnostic)
        }
        downloads[id] = task
        defer { downloads[id] = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        progress(1)
    }

    func retryArtwork() { failed.removeAll(); retryAfter.removeAll() }

    func requestArtwork(_ id: String, received: @escaping @MainActor (String, URL) -> Void) {
        guard !stopped, fetching[id] == nil, !failed.contains(id), SHA256Hex.isValid(id) else { return }
        guard retryAfter[id].map({ $0 <= .now }) ?? true, queued.insert(id).inserted else { return }
        pending.append((id, received))
        fillArtworkRequests()
    }

    private func fillArtworkRequests() {
        while !stopped, fetching.count < 4, !pending.isEmpty {
            let (id, received) = pending.removeFirst()
            queued.remove(id)
            fetching[id] = Task {
                defer {
                    fetching[id] = nil
                    fillArtworkRequests()
                }
                do {
                    let url: URL
                    do { url = try await storedArtwork(id) }
                    catch where Self.canRetryArtwork(error) {
                        try await Task.sleep(for: .seconds(2))
                        url = try await storedArtwork(id)
                    }
                    try Task.checkCancellation()
                    if !stopped { received(id, url) }
                } catch where Self.canRetryArtwork(error) {
                    retryAfter[id] = .now.advanced(by: .seconds(2))
                } catch {
                    failed.insert(id)
                }
            }
        }
    }

    private static func canRetryArtwork(_ error: Error) -> Bool {
        if case HostAPIError.status(let code) = error { return (500..<600).contains(code) }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(error.code)
    }

    func storedArtwork(_ id: String) async throws -> URL {
        guard SHA256Hex.isValid(id) else { throw LocalMusicError.invalidData }
        let url = store.artworkURL(asset: id)
        let existing = try await CatalogStorage.shared.perform { (try? LocalMusicStore.digest(file: url)) == id }
        if !existing {
            let data = try await client.artwork(id: id)
            try await CatalogStorage.shared.perform { try data.write(to: url, options: .atomic) }
        }
        return url
    }

    func stop() {
        stopped = true
        pending.removeAll()
        for task in downloads.values { task.cancel() }
        for task in fetching.values { task.cancel() }
        client.stop()
    }

    func waitForArtwork() async {
        for task in fetching.values { await task.value }
    }
}

