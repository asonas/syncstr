import Foundation
import Network
import SwiftUI

enum TransferPolicy {
    static func permitsAutomaticAudio(online: Bool, cellular: Bool, optedIn: Bool) -> Bool {
        online && (!cellular || optedIn)
    }
}

enum PlaybackPreparation: Equatable {
    case checking, connecting, receiving(UInt64, UInt64), preparing

    var label: String {
        switch self {
        case .checking: "音源を確認中"
        case .connecting: "接続中"
        case .receiving: "音源を取得中"
        case .preparing: "再生を準備中"
        }
    }
}

@MainActor
final class LocalTransfer: ObservableObject {
    @Published var status: String?
    @Published var busy = false {
        didSet {
            updateLocalCopyRemovalReadiness()
            if !busy {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters.values { waiter.resume() }
            }
            if !busy { drainHostRefresh() }
        }
    }
    private var idleWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    @Published var connected = false {
        didSet {
            if oldValue && !connected {
                connectionEvent("connection_flag_cleared", fields: ["reason": "connection_state_transition"])
            }
        }
    }
    var onCatalog: ((PreparedLocalCatalog) throws -> Void)?
    var onSaved: (() -> Void)?
    private let diagnostics: PlaybackDiagnostics?
    var diagnosticLibraryID: String?

    func connectionEvent(_ event: String, outcome: String = "observed", fields: [String: String] = [:], error: Error? = nil, operationID: UUID? = nil) {
#if os(macOS)
        var values = fields
        values["connection_mode"] = fields["connection_mode"] ?? connectionMode
        values["operation_id"] = (operationID ?? generation).uuidString
        values["connected"] = String(connected)
        values["busy"] = String(busy)
        values["current_library_id"] = diagnosticLibraryID ?? "unknown"
        diagnostics?.connection(event, outcome: outcome, fields: values, error: error)
#endif
    }

    @Published private(set) var automaticCellular = false
    @Published var saveRequests: [OfflineSaveRequest] = []
    var preparingSaves: [String: (token: UUID, tracks: Set<String>, task: Task<CatalogSnapshot?, Error>)] = [:]
    @Published private(set) var readyForLocalCopyRemoval = true
    var saveWorker: Task<Void, Never>? {
        didSet { updateLocalCopyRemovalReadiness() }
    }
    private func updateLocalCopyRemovalReadiness() {
        let ready = !busy && saveWorker == nil
        if readyForLocalCopyRemoval != ready { readyForLocalCopyRemoval = ready }
    }
    var saveRetry: Task<Void, Never>?
    var saveRetryInterval: Duration = .seconds(15)
    var hostAudioGate = HostAudioGate()
    var saveSource: (any LibrarySource)?
    var saveGeneration = UUID()
    var savesBackgrounded = false
    var removingAllSaves: Task<Void, Error>?
    /// Tests pause here to hold a restore before its first storage read.
    var beforeRestoringHost: (@MainActor () async -> Void)?
    var savePathIsCellular: Bool { savePath?.currentPath.usesInterfaceType(.cellular) == true }
    var permitsAutomaticSaveAudio: Bool { permitsAutomaticAudio }
    private let savePath: NWPathMonitor?
    @Published private(set) var hostConnection: HostConnection? {
        didSet {
            if oldValue?.address != hostConnection?.address || oldValue?.library != hostConnection?.library {
                onHostChange?(hostConnection)
            }
        }
    }
    @Published private(set) var changedHostLibrary: String?
    @Published private(set) var retainedHostLibrary: String?
    @Published private(set) var hostRefreshedAt: Date?
    /// The stored catalog had unreadable entries, so the next refresh asks for the whole catalog.
    private var hostCatalogIncomplete = false
    @Published var savedAudio = SavedAudioSummary()
    var retainsHostCatalog: Bool { retainedHostLibrary != nil }
    var usesHostCatalog: Bool { hostConnection != nil || retainsHostCatalog }
    private var hostPlaybackSources: [UUID: any LibrarySource] = [:]
    private var artworkSource: HostLibrarySource?
    private var hostAudio = HostAudioFiles()
    private let hostConfiguration: URLSessionConfiguration
    private var observedSwitch: String?
    @Published private var hostOperation: (id: UUID, task: Task<HostRefreshResult, Error>, automatic: Bool)?
    var hasHostActivity: Bool { hostConnection != nil || hostOperation != nil }
    private var pendingHostRefresh = false
    func makeLibrarySource() -> HostLibrarySource? { hostConnection.map(hostSource) }

    var hasLibrarySource: Bool { hostConnection != nil }
    var connectionMode: String { hostConnection != nil ? "host" : retainsHostCatalog ? "offline" : "none" }
    var onHostPlaylists: (([PlaylistDocument], Set<String>) -> Void)?
    var onHostDisconnected: (() async -> Void)?
    var onHostChange: ((HostConnection?) -> Void)?

    enum HostRefreshResult: Equatable {
        case updated, unchanged, differentLibrary(String)
    }

    func libraryInformation(at address: HostAddress) async throws -> HostLibraryInfo {
        let client = HostAPIClient(address: address, configuration: hostConfiguration, audioGate: hostAudioGate,
                                   switchObserved: hostSwitchObserver(address: address, library: hostConnection?.library))
        defer { client.stop() }
        return try await client.library()
    }

    func confirmHost(_ address: HostAddress, information: HostLibraryInfo, replacingLibrary: Bool = false,
                     didCommit: (@Sendable () async -> Void)? = nil) async throws -> HostRefreshResult {
        try await runHostOperation {
            try await self.applyHostConfirmation(address, information: information, replacingLibrary: replacingLibrary, didCommit: didCommit)
        }
    }

    private func runHostOperation(_ action: @escaping @MainActor () async throws -> HostRefreshResult) async throws -> HostRefreshResult {
        try Task.checkCancellation()
        let task = startHostOperation(action: action)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func startHostOperation(automatic: Bool = false, action: @escaping @MainActor () async throws -> HostRefreshResult) -> Task<HostRefreshResult, Error> {
        let previous = hostOperation
        if previous?.automatic == true { pendingHostRefresh = true }
        previous?.task.cancel()
        let id = UUID()
        let task = Task {
            defer {
                if hostOperation?.id == id {
                    hostOperation = nil
                    drainHostRefresh()
                }
            }
            _ = await previous?.task.result
            try Task.checkCancellation()
            do { return try await action() }
            catch {
                try Task.checkCancellation()
                throw error
            }
        }
        hostOperation = (id, task, automatic)
        return task
    }

    private func applyHostConfirmation(_ address: HostAddress, information: HostLibraryInfo, replacingLibrary: Bool,
                                       didCommit: (@Sendable () async -> Void)?) async throws -> HostRefreshResult {
        let files = store
        let startingGeneration = generation
        let (saved, retained) = try await CatalogStorage.shared.perform {
            let database = try files.database()
            return try (database.hostConnection(), database.retainedLibrary(at: address))
        }
        try Task.checkCancellation()
        guard generation == startingGeneration else { throw CancellationError() }
        let knownLibrary = saved?.address == address ? saved?.library : retained
        if let knownLibrary, knownLibrary != information.library, !replacingLibrary {
            return .differentLibrary(information.library)
        }
        if let saved, saved.address == address, saved.library == information.library {
            try await adoptStoredHost(saved, attempt: startingGeneration)
            if saved.hosts != information.hosts {
                try await CatalogStorage.shared.commit { try files.database().updateHosts(information.hosts, for: saved) }
                hostConnection?.hosts = information.hosts
            }
            guard generation == startingGeneration else { throw CancellationError() }
            return try await refreshStoredHost(confirming: true, didCommit: didCommit)
        } else {
            let host = HostConnection(address: address, library: information.library, name: information.name, hosts: information.hosts)
            let source = hostSource(host)
            defer { source.stop() }
            guard case .updated(let update) = try await source.refreshCatalog() else { throw HostAPIError.notHost }
            try Task.checkCancellation()
            guard startingGeneration == generation else { throw CancellationError() }
            guard update.catalog.id == information.library else { return .differentLibrary(update.catalog.id) }
            let refreshed = Date.now
            let prepared = try await CatalogStorage.shared.commitHostCatalog(update, host: host, replacing: saved,
                refreshedAt: refreshed, store: files, didCommit: didCommit)
            cancelActiveConnection(reason: "changing_library_host")
            try publishHost(update, prepared: prepared, host: host, refreshedAt: refreshed, changingHost: true)
            resumeSaves()
            return .updated
        }
    }

    private func activateHost(_ host: HostConnection) {
        stopSaveWorker()
        artworkSource?.stop()
        artworkSource = nil
        hostAudio = HostAudioFiles()
        stopHostPlayback()
        retainedHostLibrary = nil
        observedSwitch = host.hostSwitch
        hostConnection = host
        changedHostLibrary = nil
        hostCatalogIncomplete = false
    }

    func disconnectHost(didCommit: (@Sendable () async -> Void)? = nil) async throws {
        _ = try await runHostOperation {
            guard self.hostConnection != nil else { return .unchanged }
            let files = self.store
            let retained = try await CatalogStorage.shared.commit { try files.database().forgetHost() }
            await didCommit?()
            // The caller can cancel during the delete. Restore the screen in an uncancelled task.
            await Task { await self.finishHostDisconnect(retained: retained) }.value
            return .updated
        }
    }

    private func finishHostDisconnect(retained: String?) async {
        cancelActiveConnection(reason: "disconnect_host")
        stopSaveWorker()
        stopHostPlayback()
        hostConnection = nil
        hostRefreshedAt = nil
        hostCatalogIncomplete = false
        hostAudio = HostAudioFiles()
        observedSwitch = nil
        catalog = nil
        changedHostLibrary = nil
        retainedHostLibrary = retained
        status = nil
        onHostPlaylists?([], [])
        await onHostDisconnected?()
        resumeSaves()
    }

    private func hostSource(_ host: HostConnection) -> HostLibrarySource {
        HostLibrarySource(host: host, configuration: hostConfiguration, store: store, files: hostAudio, audioGate: hostAudioGate,
                          switchObserved: hostSwitchObserver(address: host.address, library: host.library))
    }

    private func hostSwitchObserver(address: HostAddress, library: String?) -> @Sendable (String) -> Void {
        { [weak self] value in
            Task { @MainActor in
                guard let self, self.hostConnection?.address == address,
                      self.hostConnection?.library == library else { return }
                let previous = self.observedSwitch
                self.observedSwitch = value
                if let previous, previous != value {
                    self.refreshConnection()
                }
            }
        }
    }

    func requestHostArtwork(_ id: String, received: @escaping @MainActor (String, URL) -> Void) {
        guard let hostConnection else { return }
        if artworkSource == nil { artworkSource = hostSource(hostConnection) }
        artworkSource?.requestArtwork(id, received: received)
    }

    func refreshConnection() {
        guard hasHostActivity else { return }
        pendingHostRefresh = true
        drainHostRefresh()
    }

    private func drainHostRefresh() {
        guard pendingHostRefresh, hostOperation == nil else { return }
        guard hostConnection != nil else { pendingHostRefresh = false; return }
        guard !busy, !savesBackgrounded else { return }
        _ = startHostOperation(automatic: true) {
            guard !self.busy else { return .unchanged }
            self.pendingHostRefresh = false
            do { return try await self.refreshStoredHost(confirming: false) }
            catch {
                if !Task.isCancelled && !isHostCancellation(error) { self.status = error.localizedDescription }
                throw error
            }
        }
    }

    func refreshHost() async throws -> HostRefreshResult {
        let attempt = generation
        while let previous = hostOperation {
            _ = await previous.task.result
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
        }
        guard hostConnection != nil else { throw CancellationError() }
        return try await runHostOperation {
            try await self.refreshStoredHost(confirming: false)
        }
    }

    private func refreshStoredHost(confirming: Bool, didCommit: (@Sendable () async -> Void)? = nil) async throws -> HostRefreshResult {
        try await waitForIdle(until: .now.advanced(by: .seconds(15)))
        try Task.checkCancellation()
        busy = true
        let attempt = generation
        let files = store
        defer { if generation == attempt { busy = false; resumeSaves() } }
        let (stored, retained) = try await CatalogStorage.shared.perform {
            let database = try files.database()
            let host = try database.hostConnection()
            return (host, host == nil ? try database.retainedHostLibrary() : nil)
        }
        guard generation == attempt else { throw CancellationError() }
        guard let host = stored else {
            await Task { await self.finishHostDisconnect(retained: retained) }.value
            return .updated
        }
        try await adoptStoredHost(host, attempt: attempt)
        var request = host
        // Without the ETag the host cannot answer 304, so the missing entries come back.
        if hostCatalogIncomplete { request.etag = nil }
        let source = hostSource(request)
        artworkSource?.retryArtwork()
        defer { source.stop() }
        connectionEvent("refresh_host", outcome: "started", fields: ["connection_mode": "host"])
        do {
            let result = try await source.refreshCatalog()
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
            switch result {
            case .unchanged:
                status = nil
                connected = true
                changedHostLibrary = nil
                let refreshed = Date.now
                if (try? await CatalogStorage.shared.commit({ try files.database().markHostRefreshed(host, at: refreshed) })) != nil,
                   generation == attempt { hostRefreshedAt = refreshed }
                connectionEvent("refresh_host", outcome: "succeeded", fields: ["result": "unchanged", "remote_catalog_id": host.library])
                return .unchanged
            case .updated(let update):
                guard update.catalog.id == host.library else {
                    if !confirming {
                        connected = false
                        changedHostLibrary = update.catalog.id
                    }
                    connectionEvent("refresh_host", outcome: "different_library", fields: ["connection_mode": "host", "remote_catalog_id": update.catalog.id])
                    return .differentLibrary(update.catalog.id)
                }
                let refreshed = Date.now
                let prepared = try await CatalogStorage.shared.commitHostCatalog(update, host: host, replacing: host,
                    refreshedAt: refreshed, store: files, didCommit: didCommit)
                try publishHost(update, prepared: prepared, host: host, refreshedAt: refreshed, changingHost: false)
                hostCatalogIncomplete = false
                connectionEvent("refresh_host", outcome: "succeeded", fields: ["result": "updated", "remote_catalog_id": host.library])
                return .updated
            }
        } catch {
            if generation == attempt && !Task.isCancelled && !isHostCancellation(error) {
                connected = false
                connectionEvent("refresh_host", outcome: "failed", fields: ["connection_mode": "host"], error: error)
            }
            throw error
        }
    }

    private func publishHost(_ update: CatalogUpdate, prepared: PreparedLocalCatalog, host: HostConnection,
                             refreshedAt: Date, changingHost: Bool) throws {
        var host = host
        host.etag = update.etag
        host.hostSwitch = update.hostSwitch
        host.marker = update.marker
        host.name = update.catalog.name
        try onCatalog?(prepared)
        if changingHost {
            activateHost(host)
        } else { hostConnection = host }
        changedHostLibrary = nil
        hostRefreshedAt = refreshedAt
        status = nil
        catalog = update.catalog
        onHostPlaylists?(update.playlists, update.conflicts)
        connected = true
    }

    private func adoptStoredHost(_ host: HostConnection, attempt: UUID) async throws {
        guard hostConnection != host || (host.etag != nil && catalog?.id != host.library) else { return }
        let files = store
        var unreadable = 0
        if host.etag != nil {
            let (prepared, lists, skipped) = try await CatalogStorage.shared.perform {
                let database = try files.database()
                guard try database.hostConnection() == host, let snapshot = try database.snapshot() else { throw CancellationError() }
                return try (PreparedLocalCatalog(snapshot.catalog, store: files), database.playlistDocuments(), snapshot.unreadableEntries)
            }
            guard generation == attempt else { throw CancellationError() }
            try onCatalog?(prepared)
            catalog = prepared.catalog
            onHostPlaylists?(lists.documents, lists.conflicts)
            unreadable = skipped
        }
        if hostConnection?.address != host.address || hostConnection?.library != host.library { activateHost(host) }
        else { hostConnection = host }
        if unreadable > 0 {
            hostCatalogIncomplete = true
            connectionEvent("host_catalog_incomplete", outcome: "observed", fields: ["unreadable_entries": String(unreadable)])
        }
    }

    private func stopHostPlayback() {
        for source in hostPlaybackSources.values { source.stop() }
        hostPlaybackSources.removeAll()
    }

    lazy var playbackCache = PlaybackCache(root: store.root.appendingPathComponent("playback-cache"))
    private var catalog: LocalCatalog?
    private var generation = UUID()
    var store: LocalMusicStore
    init(store: LocalMusicStore = LocalMusicStore(), diagnostics: PlaybackDiagnostics? = nil,
         hostConfiguration: URLSessionConfiguration = .ephemeral, pathMonitor: NWPathMonitor? = NWPathMonitor()) {
        self.diagnostics = diagnostics
        self.store = store
        self.hostConfiguration = hostConfiguration
        savePath = pathMonitor
        restoreSaves()
        guard let savePath else { return }
        savePath.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.stopSaveWorker()
                self.resumeSaves()
            }
        }
        savePath.start(queue: .global(qos: .utility))
    }

    deinit { savePath?.cancel() }

    func setAutomaticCellular(_ enabled: Bool) {
        do {
            try store.database().setAutomaticCellular(enabled)
            automaticCellular = enabled
            stopSaveWorker()
            resumeSaves()
        } catch { status = error.localizedDescription }
    }

    private var permitsAutomaticAudio: Bool {
        guard let path = savePath?.currentPath else { return true }
        return TransferPolicy.permitsAutomaticAudio(online: path.status == .satisfied,
            cellular: path.usesInterfaceType(.cellular), optedIn: automaticCellular)
    }

    @discardableResult
    func restoreHost() async -> Bool {
        let attempt = generation
        await beforeRestoringHost?()
        let files = store
        do {
            automaticCellular = try await CatalogStorage.shared.perform { try files.database().automaticCellular() }
            if let host = try await CatalogStorage.shared.perform({ try files.database().hostConnection() }) {
                let refreshed = try await CatalogStorage.shared.perform { try files.database().hostRefreshedAt() }
                guard generation == attempt else { return false }
                try await adoptStoredHost(host, attempt: attempt)
                hostRefreshedAt = refreshed
            } else {
                let retained = try await CatalogStorage.shared.perform { try files.database().retainedHostLibrary() }
                guard generation == attempt else { return false }
                if hostConnection != nil {
                    stopHostPlayback()
                    artworkSource?.stop()
                    artworkSource = nil
                    hostConnection = nil
                    connected = false
                }
                retainedHostLibrary = retained
            }
            return true
        } catch {
            guard generation == attempt, !(error is CancellationError) else { return false }
            connectionEvent("restore_host_failed", outcome: "failed", fields: ["reason": "catalog_database"], error: error)
            status = error.localizedDescription
            return false
        }
    }

    func removeSavedCopy(_ entry: LocalEntry) throws {
        guard readyForLocalCopyRemoval else { throw LocalMusicError.transferBusy }
        guard LocalMusicStore.valid(entry) else { throw LocalMusicError.invalidData }
        // The caller cancels this library's request first. Any request still holding the hash, including
        // one for the same track in another library, can reuse the file.
        let kept = try Self.discard([SavedAudioPin(track: entry.track.id, hash: entry.sha256)], keeping: requestedAudio,
                                    store: store, cache: playbackCache.store, protected: playbackCache.protectedPaths,
                                    database: store.database())
        onSaved?()
        if !kept.isEmpty { throw LocalMusicError.removalIncomplete }
    }

    func cancel() { cancel(reason: "cancel_requested") }

    func stopAndWait() async {
        let worker = saveWorker
        let retry = saveRetry
        let refresh = hostOperation?.task
        let artwork = artworkSource
        setSavesBackgrounded(true)
        cancelSavePreparations()
        stopHostPlayback()
        cancel()
        await worker?.value
        await retry?.value
        _ = await refresh?.result
        await artwork?.waitForArtwork()
    }

    func cancel(reason: String) {
        pendingHostRefresh = false
        hostOperation?.task.cancel()
        cancelActiveConnection(reason: reason)
    }

    private func cancelActiveConnection(reason: String) {
        connectionEvent("cancel", outcome: connected ? "disconnected" : "observed", fields: ["reason": reason])
        generation = UUID()
        if hostConnection != nil { artworkSource?.stop(); artworkSource = nil }
        connected = false
        busy = false
    }

    func playbackFile(_ track: Track, diagnostic: PlaybackDiagnosticContext? = nil,
                      allowAcquisition: Bool = true,
                      progress: @escaping (PlaybackPreparation) -> Void = { _ in }) async throws -> URL {
        progress(.checking)
        let selectedHost = hostConnection
        let entry: LocalEntry
        let libraryID: String
        do {
            guard let source = try await CatalogStorage.shared.entry(store: store, track: track.id) else { throw LocalMusicError.invalidData }
            entry = source.entry
            libraryID = source.library
        } catch { diagnostic?.failure("resolution", error); throw error }
        let files = store
        let hostCatalog = usesHostCatalog
        if let file = try await CatalogStorage.shared.perform({
            if hostCatalog, try !files.database().hasAudioPin(entry) { return nil as URL? }
            return try files.verifiedFile(entry, host: hostCatalog)
        }) { return file }
        guard !retainsHostCatalog else { throw LocalMusicError.disconnected }
        diagnostic?.record("resolution", "catalog_entry", fields: ["track_id": entry.track.id, "sha256": entry.sha256, "expected_size": String(entry.track.size ?? 0)])
        if let cached = try await playbackCache.fileInBackground(entry, diagnostic: diagnostic) {
            diagnostic?.record("selection", "mode", fields: ["mode": "local", "reason": "cache_hit"])
            return cached
        }
        try Task.checkCancellation()
        guard allowAcquisition else {
            diagnostic?.record("request", "rejected", fields: ["reason": "backgrounded"])
            throw LocalMusicError.backgroundAcquisition
        }
        diagnostic?.record("local", "acquisition_required", fields: ["reason": "no_usable_local_file"])
        // Held from before the download until the caller takes the verified file, so a trim cannot remove
        // the file between its placement and the lease that fileInBackground takes.
        let destination = playbackCache.store.fileURL(entry)
        playbackCache.lease(destination)
        defer { playbackCache.release(destination) }
        do { try await playbackCache.makeRoomInBackground(for: entry) }
        catch { diagnostic?.failure("cache_capacity", error); throw error }
        guard hostConnection?.address == selectedHost?.address, selectedHost?.library == libraryID,
              let source = makeLibrarySource() else { throw LocalMusicError.disconnected }
        connectionEvent("playback_connection_decision", fields: ["mode": connectionMode])
        if let diagnostic { diagnostics?.captureConnections(in: diagnostic) }
        diagnostic?.record("selection", "mode", fields: ["mode": connectionMode])
        progress(.connecting)
        let playbackID = UUID()
        hostPlaybackSources[playbackID] = source
        return try await withTaskCancellationHandler {
            defer { hostPlaybackSources[playbackID] = nil; source.stop() }
            try await source.download(entry, cache: playbackCache.store, diagnostic: diagnostic) { fraction in
                progress(.receiving(UInt64(fraction * Double(entry.track.size ?? 0)), entry.track.size ?? 0))
            }
            try Task.checkCancellation()
            guard let result = try await playbackCache.fileInBackground(entry, diagnostic: diagnostic) else { throw LocalMusicError.invalidData }
            guard hostConnection?.address == selectedHost?.address, hostConnection?.library == selectedHost?.library else {
                playbackCache.release(result)
                throw CancellationError()
            }
            return result
        } onCancel: {
            Task { @MainActor in source.stop() }
        }
    }

    func waitForIdle(until deadline: ContinuousClock.Instant? = nil) async throws {
        let attempt = generation
        while busy {
            try Task.checkCancellation()
            let id = UUID()
            let timeout = deadline.map { deadline in
                Task {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    idleWaiters.removeValue(forKey: id)?.resume(throwing: URLError(.timedOut))
                }
            }
            defer { timeout?.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                    else { idleWaiters[id] = waiter }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.idleWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
            try Task.checkCancellation()
            guard generation == attempt else { throw CancellationError() }
        }
    }
}
