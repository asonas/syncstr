import AVFoundation
import Combine
import Network
import SwiftUI

struct Album: Identifiable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
    var artwork: String? = nil
    var detailArtist: String? = nil
    var coverArt: String? { artwork ?? tracks.compactMap(\.coverArt).first }
}

enum AlbumSortField { case title, artist }

struct RecentAlbumSection: Identifiable {
    let month: Date?
    var albums: [Album]
    var id: Date? { month }
}

enum LibraryDestination: String, CaseIterable {
    case recentlyAdded = "最近追加した項目"
    case albums = "アルバム"
    case artists = "アーティスト"
    case songs = "曲"
    case hiddenAlbums = "非表示にしたアルバム"

    var icon: String {
        switch self {
        case .recentlyAdded: "clock"
        case .albums: "layers"
        case .artists: "users"
        case .songs: "music"
        case .hiddenAlbums: "eye-off"
        }
    }
}

enum PlaybackRepeat: String, CaseIterable, Codable {
    case off = "オフ"
    case all = "すべて"
    case one = "1曲"
}

@MainActor
final class Library: ObservableObject {
    @Published private(set) var playlists: [PlaylistDocument] = [] {
        didSet {
            if let id = selectedPlaylist, !playlists.contains(where: { $0.id == id }) {
                selectedPlaylist = nil
                search = ""
            }
        }
    }
    @Published private(set) var playlistConflicts: Set<String> = []
    @Published var playlistMessage: String?
    @Published private(set) var refreshingPlaylists = false

    func loadPlaylists() async {
        let files = localStore
        let generation = catalogGeneration
        do {
            let saved = try await CatalogStorage.shared.perform { try files.database().playlistDocuments() }
            guard generation == catalogGeneration else { return }
            playlists = saved.documents
            playlistConflicts = saved.conflicts
            playlistMessage = nil
        } catch { if generation == catalogGeneration { playlistMessage = error.localizedDescription } }
    }

    func refreshPlaylists() async {
        guard !refreshingPlaylists else { return }
        refreshingPlaylists = true
        defer { refreshingPlaylists = false }
        await loadPlaylists()
    }

    func playlistTrack(_ item: PlaylistItem) -> Track? {
        guard let hash = item.sha256, let id = item.trackId, let catalog = localCatalog else { return nil }
        let canonical = catalog.organization?.canonicalTrack(id) ?? id
        return playlistTracksByIdentity[canonical + ":" + hash]
    }
    @Published var tracks: [Track] = [] { didSet { if !applyingPreparedCatalog { rebuildAlbums() } } }
    private var playlistTracksByIdentity: [String: Track] = [:]
    private var applyingPreparedCatalog = false
    private(set) var albums: [Album] = []
    private(set) var recentlyAddedAlbums: [Album] = []
    private(set) var recentlyAddedSections: [RecentAlbumSection] = []
    private(set) var hiddenAlbums: [Album] = []
    private(set) var catalogTracks: [Track] = []
    private var albumsByID: [String: Album] = [:]
    private var allAlbums: [Album] = []
    private var albumsByArtist: [String: [Album]] = [:]
    private var tracksByArtist: [String: [Track]] = [:]
    private(set) var artistNames: [String] = []
    @Published var connected = false
    @Published var current: Track?
    @Published var playing = false
    @Published var loading = false
    @Published private(set) var playbackPreparation = PlaybackPreparation.checking
    var playbackLoadingLabel: String {
        return playbackPreparation.label
    }
    @Published var refreshing = false
    @Published var restoringSession = true
    @Published var message: String?
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var queue: [Track] = []
    private var queueSelection: Int?
    @Published private(set) var shuffled = false
    @Published var repeatMode = PlaybackRepeat.off { didSet { persistPlayback() } }
    @Published private(set) var volume = 1.0
    @Published var destination = LibraryDestination.albums
    @Published var albumSortField = AlbumSortField.title
    @Published var albumSortDescending = false
    @Published var selectedAlbum: String?
    @Published var selectedPlaylist: String?
    @Published var selectedArtist: String?
    @Published var search = ""
    @Published var sidebarVisible = true
    @Published var showingNowPlaying = false
    @Published var localCopiesToRemove: [Track] = []
    @Published private(set) var pendingLocalCopyRemovals: [Track] = []
    private var removalLibraryID: String?
    @Published private(set) var artworkURLs: [String: URL] = [:]
    let localStore: LocalMusicStore
    let transfer: LocalTransfer
    private(set) var localFiles: [String: URL] = [:]
    private var managedTracks: Set<String> = []
    private(set) var localCatalog: LocalCatalog?
    private var transferChanges: AnyCancellable?
    private var removalChanges: AnyCancellable?
#if os(iOS)
    @Published private(set) var downloaded: Set<String> = []
#endif

    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var waitingObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var finishObserver: NSObjectProtocol?
    private var playbackErrorObserver: NSObjectProtocol?
    private var seeking: UUID?
    private var restoredLibrary = false
    private var restoreTask: Task<Void, Never>?
    private var restoreRequested = false
    private var catalogGeneration = UUID()
    private(set) var inventoryTask: Task<Void, Never>?
    private var pendingLocalPlaybackTrack: (id: String, request: UUID)?
    private var orderedQueue: [Track] = []
    private var wantsPlayback = false
    private var backgrounded = false
    private var playbackRequest = UUID()
    private var diagnostic: PlaybackDiagnosticContext?
    @Published private(set) var failedDiagnosticID: String?
    private var diagnosticFailed = false
    private var diagnosticAdvanced = false
    private var diagnosticPosition: Double?
    private var acquisition: Task<Void, Never>?
    private var restoringPlayback = false
    private var restoredPlaybackLibrary: String?
    private var lastPersistedSecond = -1.0
    @Published private(set) var playbackFailure: String?

    private struct PlaybackSnapshot: Codable {
        var queueSelection: Int? = nil
        let library: String
        let current: Track
        let position: Double
        let duration: Double
        let queue: [Track]
        let orderedQueue: [Track]
        let shuffled: Bool
        let repeatMode: PlaybackRepeat
    }
    private let makePlayer: (URL) -> AVPlayer
    let diagnostics: PlaybackDiagnostics

    init(makePlayer: @escaping (URL) -> AVPlayer = { SharedAudioPlayback.player($0) },
         diagnostics: PlaybackDiagnostics? = nil,
         localStore: LocalMusicStore = LocalMusicStore(), hostConfiguration: URLSessionConfiguration = .ephemeral,
         pathMonitor: NWPathMonitor? = NWPathMonitor()) {
        self.makePlayer = makePlayer
        self.diagnostics = diagnostics ?? PlaybackDiagnostics(root: localStore.root.appendingPathComponent("PlaybackDiagnostics"))
        self.localStore = localStore
        self.transfer = LocalTransfer(store: localStore, diagnostics: self.diagnostics, hostConfiguration: hostConfiguration, pathMonitor: pathMonitor)
        transfer.onCatalog = { [weak self] prepared in try self?.applyLocal(prepared) }
        transfer.onHostChange = { [weak self] host in
            guard let self else { return }
            inventoryTask?.cancel()
            if let host, localCatalog?.source == .host, localCatalog?.id == host.library { refreshLocalFiles() }
        }
        transfer.onHostPlaylists = { [weak self] documents, conflicts in
            self?.playlists = documents
            self?.playlistConflicts = conflicts
            self?.playlistMessage = nil
        }
        transfer.onHostDisconnected = { [weak self] in
            guard let self else { return }
            if localStore.hasCatalog { await openSavedLocalLibrary(); await loadPlaylists() }
            else { closeLibrary() }
        }
        transfer.onSaved = { [weak self] in
            guard let self else { return }
            if let current, localFiles[current.id] != nil, pendingLocalPlaybackTrack?.id != current.id {
                pendingLocalPlaybackTrack = (current.id, playbackRequest)
            }
            refreshLocalFiles()
            Task { await self.transfer.refreshSavedAudio() }
        }
        transferChanges = transfer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        removalChanges = transfer.$readyForLocalCopyRemoval.dropFirst().filter { $0 }.sink { [weak self] _ in
            // Published emits before readiness changes; resume after the transition finishes.
            Task { @MainActor [weak self] in self?.resumeLocalCopyRemovals() }
        }
    }

    nonisolated static func preparedAlbums(_ tracks: [Track], organization: AlbumOrganization?) -> [Album] {
        let records = Dictionary(uniqueKeysWithValues: (organization?.tracks ?? []).map { ($0.id, $0) })
        let images = organization.map(AlbumArtworkLookup.init)
        return Dictionary(grouping: tracks, by: \.albumKey).map { key, tracks in
            Album(id: key, title: tracks.first?.albumDisplayTitle ?? "アルバム未設定",
                  artist: organization?.artistCredit(for: tracks.sorted {
                      ($0.discNumber ?? 1, $0.track ?? 0, $0.id) < ($1.discNumber ?? 1, $1.track ?? 0, $1.id)
                  }, records: records) ?? tracks.first?.artist ?? "アーティスト不明",
                  tracks: tracks.sorted {
                      if ($0.discNumber ?? 1) != ($1.discNumber ?? 1) {
                          return ($0.discNumber ?? 1) < ($1.discNumber ?? 1)
                      }
                      if ($0.track ?? 0) != ($1.track ?? 0) { return ($0.track ?? 0) < ($1.track ?? 0) }
                      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                  }, artwork: organization.flatMap { images?.coverAsset(for: key, in: $0) },
                  detailArtist: organization?.artistCredit(for: tracks, records: records, abbreviatingMultipleArtists: true)
                    ?? (Set(tracks.compactMap(\.artist).filter { !$0.isEmpty }).count > 1 ? "V.A." : tracks.first?.artist))
        }.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private func rebuildAlbums() {
        applyAlbums(Self.preparedAlbums(tracks, organization: localCatalog?.organization))
    }

    private func applyAlbums(_ prepared: [Album]) {
        albums = prepared
        albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        allAlbums = albums
        rebuildVisibleCatalog()
    }

    private func rebuildVisibleCatalog() {
        hiddenAlbums = allAlbums.filter { isAlbumHidden($0.id) }
        let hiddenIDs = Set(hiddenAlbums.map(\.id))
        albums = allAlbums.filter { !hiddenIDs.contains($0.id) }
        let dates: [(album: Album, addedAt: Int64?)] = albums.map { album in
            (album, album.tracks.compactMap(\.addedAt).max())
        }
        let recent = dates.sorted { left, right in
            if left.addedAt != right.addedAt { return (left.addedAt ?? 0) > (right.addedAt ?? 0) }
            return left.album.id < right.album.id
        }
        recentlyAddedAlbums = recent.map(\.album)
        recentlyAddedSections = []
        let calendar = Calendar.current
        for item in recent {
            let month = item.addedAt.flatMap {
                calendar.dateInterval(of: .month, for: Date(timeIntervalSince1970: Double($0) / 1000))?.start
            }
            if recentlyAddedSections.last?.month == month, !recentlyAddedSections.isEmpty {
                recentlyAddedSections[recentlyAddedSections.count - 1].albums.append(item.album)
            } else {
                recentlyAddedSections.append(RecentAlbumSection(month: month, albums: [item.album]))
            }
        }
        catalogTracks = tracks.filter { !hiddenIDs.contains($0.albumKey) }
        tracksByArtist = Dictionary(grouping: catalogTracks) { $0.artist ?? "アーティスト不明" }
        artistNames = tracksByArtist.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        albumsByArtist = [:]
        for album in albums {
            var credits = Set(album.tracks.map { $0.artist ?? "アーティスト不明" })
            if let artist = album.detailArtist, artist != "V.A." { credits.insert(artist) }
            for artist in credits {
                albumsByArtist[artist, default: []].append(album)
            }
        }
    }

    func isAlbumHidden(_ id: String) -> Bool { localCatalog?.organization?.isHidden(id) ?? false }


    func album(id: String) -> Album? { albumsByID[id] }
    func albums(for artist: String) -> [Album] { albumsByArtist[artist] ?? [] }
    func tracks(for artist: String) -> [Track] { tracksByArtist[artist] ?? [] }

    var visibleRecentlyAddedSections: [RecentAlbumSection] {
        recentlyAddedSections.compactMap { section in
            let albums = section.albums.filter { search.isEmpty || $0.title.localizedStandardContains(search)
                || $0.artist.localizedStandardContains(search) }
            return albums.isEmpty ? nil : RecentAlbumSection(month: section.month, albums: albums)
        }
    }

    var visibleAlbums: [Album] {
        let albums: [Album]
        switch destination {
        case .recentlyAdded: albums = recentlyAddedAlbums
        case .hiddenAlbums: albums = hiddenAlbums
        default: albums = self.albums
        }
        let filtered = albums.filter { search.isEmpty || $0.title.localizedStandardContains(search)
            || $0.artist.localizedStandardContains(search) }
        return destination == .recentlyAdded ? filtered : sortedAlbums(filtered)
    }

    func sortedAlbums(_ albums: [Album]) -> [Album] {
        albums.sorted { lhs, rhs in
            let primary = albumSortField == .title
                ? lhs.title.localizedStandardCompare(rhs.title)
                : lhs.artist.localizedStandardCompare(rhs.artist)
            let secondary = albumSortField == .title
                ? lhs.artist.localizedStandardCompare(rhs.artist)
                : lhs.title.localizedStandardCompare(rhs.title)
            let order = primary != .orderedSame ? primary : secondary
            if order == .orderedSame { return albumSortDescending ? lhs.id > rhs.id : lhs.id < rhs.id }
            return order == (albumSortDescending ? .orderedDescending : .orderedAscending)
        }
    }

    var artists: [String] {
        guard !search.isEmpty else { return artistNames }
        return artistNames.filter { $0.localizedStandardContains(search) }
    }

    var visibleTracks: [Track] {
        let source: [Track]
        if !search.isEmpty {
            source = catalogTracks
        } else if let selectedAlbum, let album = album(id: selectedAlbum) {
            source = album.tracks
        } else if let selectedArtist {
            source = tracks(for: selectedArtist)
        } else {
            source = catalogTracks
        }
        return source.filter {
            search.isEmpty || $0.title.localizedStandardContains(search)
                || ($0.artist?.localizedStandardContains(search) ?? false)
                || ($0.album?.localizedStandardContains(search) ?? false)
        }
    }

    var currentIndex: Int? {
        if let queueSelection, queue.indices.contains(queueSelection), queue[queueSelection].id == current?.id { return queueSelection }
        return queue.firstIndex { $0.id == current?.id }
    }
    var canGoPrevious: Bool { currentIndex != nil }
    var canGoNext: Bool { currentIndex.map { $0 + 1 < queue.count || repeatMode == .all } ?? false }
    var canSeek: Bool { player?.currentItem?.status == .readyToPlay && !loading && duration > 0 }
    var playbackAction: String { loading ? "再生の準備をキャンセル" : playing || wantsPlayback ? "一時停止" : "再生" }
    func navigate(_ destination: LibraryDestination) {
        self.destination = destination
        selectedAlbum = nil
        selectedPlaylist = nil
        selectedArtist = nil
        showingNowPlaying = false
    }

    func openPlaylist(_ id: String) {
        navigate(destination)
        selectedPlaylist = id
    }

    func openAlbum(_ id: String) {
        selectedPlaylist = nil
        selectedAlbum = id
        search = ""
        showingNowPlaying = false
    }

    /// Going to the background cancels a running restore. A call that arrives while one runs is
    /// remembered, so a restore that ends unfinished runs again instead of waiting for the next call.
    /// The restore runs in a task the library owns, so the view task that started it can end without
    /// cancelling the retry.
    func restoreLibrary() async {
        // Every activation calls this; once restored it must stay a no-op that records nothing.
        if restoredLibrary && restoreTask == nil { return }
        transfer.connectionEvent("startup_restore_called")
        if let restoreTask {
            restoreRequested = true
            await restoreTask.value
            return
        }
        let task = Task { [weak self] in _ = await self?.runRestore() }
        restoreTask = task
        await task.value
    }

    private func runRestore() async {
        defer { restoreTask = nil }
        repeat {
            restoreRequested = false
            restoringSession = false
            let restored = await transfer.restoreHost()
            if transfer.usesHostCatalog {
                if localCatalog?.source != .host { await openSavedLocalLibrary() }
                await loadPlaylists()
            }
            restoredLibrary = restored && !(transfer.usesHostCatalog && localCatalog?.source != .host)
        } while !restoredLibrary && restoreRequested
        if transfer.hasHostActivity { transfer.refreshConnection() }
        transfer.resumeSaves()
    }

    func reload() {
        guard !transfer.retainsHostCatalog else { return }
        transfer.connectionEvent("library_reload_called")
        transfer.refreshRequested()
    }

    private func applyLocal(_ prepared: PreparedLocalCatalog) throws {
        inventoryTask?.cancel()
        catalogGeneration = UUID()
        let catalog = prepared.catalog
        let sameLibrary = localCatalog?.id == catalog.id
        if !sameLibrary {
            pendingLocalPlaybackTrack = nil
            transfer.cancelSavePreparations()
            transfer.stopSaveWorker()
            stop()
            current = nil
            queue = []
            orderedQueue = []
        }
        localCatalog = catalog
        transfer.diagnosticLibraryID = catalog.id
        transfer.connectionEvent("library_selected")
        applyingPreparedCatalog = true
        tracks = prepared.tracks
        applyingPreparedCatalog = false
        let tracksByID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        playlistTracksByIdentity = [:]
        for entry in catalog.entries {
            let canonical = catalog.organization?.canonicalTrack(entry.track.id) ?? entry.track.id
            if let track = tracksByID[canonical] ?? tracksByID[entry.track.id] {
                playlistTracksByIdentity[canonical + ":" + entry.sha256] = track
            }
        }
        applyAlbums(prepared.albums)
        artworkURLs = prepared.artworkURLs
        connected = true
        restoringSession = false
        refreshing = false
        message = nil
        if !sameLibrary { navigate(.albums) }
        else if let selectedAlbum { self.selectedAlbum = catalog.organization?.canonical(selectedAlbum) }
        var retained: [String: URL] = [:]
        if sameLibrary {
            for entry in catalog.entries {
                if let url = localFiles[entry.track.id], localStore.hostFileURLs(entry).contains(url) {
                    retained[entry.track.id] = url
                }
            }
        }
        applyLocalFiles(retained, inventoryComplete: false)
        refreshLocalFiles()
        restorePlayback()
        if let current, !tracks.contains(where: { $0.id == current.id }) {
            pause()
            playbackFailure = "この曲はライブラリから削除されているため再生できません。別の曲を選んでください。"
        }
    }

    func artworkURL(for id: String) -> URL? {
        guard localCatalog?.remoteArtwork?.contains(id) == true else { return artworkURLs[id] }
        if let url = artworkURLs[id], url == localStore.artworkURL(asset: id) { return url }
        if transfer.retainsHostCatalog {
            let url = localStore.artworkURL(asset: id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        transfer.requestHostArtwork(id) { [weak self] asset, url in
            guard let self, localCatalog?.remoteArtwork?.contains(asset) == true else { return }
            artworkURLs[asset] = url
        }
        return nil
    }

    func refreshLocalFiles() {
        let previous = inventoryTask
        previous?.cancel()
        guard let localCatalog else { return }
        func publish(_ files: [String: URL]) {
            objectWillChange.send()
            applyLocalFiles(files)
        }
        let generation = catalogGeneration
        let host = transfer.hostConnection?.address
        inventoryTask = Task { [localStore] in
            await previous?.value
            let files = try? await CatalogStorage.shared.savedHostFiles(in: localCatalog, store: localStore)
            guard let files, !Task.isCancelled, catalogGeneration == generation, host == transfer.hostConnection?.address else { return }
            publish(files)
        }
    }

    private func applyLocalFiles(_ files: [String: URL], inventoryComplete: Bool = true) {
        managedTracks = Set(files.keys)
        localFiles = files
#if os(iOS)
        downloaded = Set(localFiles.keys)
#endif
        guard inventoryComplete else { return }
        // Playback from the playback cache goes on when the saved copy of the same track goes away, and so does
        // playback of a saved file that stays because another saved track still holds its audio.
        if let pending = pendingLocalPlaybackTrack, pending.request == playbackRequest,
           current?.id == pending.id, transfer.hasLibrarySource, localFiles[pending.id] == nil,
           transfer.playbackCache.protectedURL == nil
            || openedSavedFile.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true { stop() }
        pendingLocalPlaybackTrack = nil
    }

    /// A track is being prepared and the player has no file open yet, so it may still read from the saved folder.
    /// Once a file is open, `openedSavedFile` says where it is.
    private var acquiringAudio: Bool { loading && transfer.playbackCache.protectedURL == nil }

    /// The file the player has open when it is in the saved folder rather than in the playback cache.
    private var openedSavedFile: URL? {
        guard let url = transfer.playbackCache.protectedURL?.resolvingSymlinksInPath(),
              url.deletingLastPathComponent().path == localStore.root.resolvingSymlinksInPath().path else { return nil }
        return url
    }

    func openSavedLocalLibrary() async {
        let generation = catalogGeneration
        let files = localStore
        do {
            guard let snapshot = try await localStore.snapshotInBackground() else { return }
            try Task.checkCancellation()
            guard catalogGeneration == generation else { return }
            if transfer.hostConnection == nil {
                await transfer.restoreHost()
                guard transfer.usesHostCatalog, catalogGeneration == generation else { return }
            }
            let prepared = try await CatalogStorage.shared.perform { try PreparedLocalCatalog(snapshot.catalog, store: files) }
            guard catalogGeneration == generation else { return }
            try applyLocal(prepared)
        } catch {
            if catalogGeneration == generation, !(error is CancellationError) { message = error.localizedDescription }
        }
    }

    func startAlbum(_ tracks: [Track], shuffled: Bool = false) {
        guard connected, !tracks.isEmpty else { return }
        self.shuffled = shuffled
        orderedQueue = tracks
        queue = shuffled ? tracks.shuffled() : tracks
        if let first = queue.first { select(first, autoplay: true, queueIndex: 0) }
    }

    func play(_ track: Track, in tracks: [Track]? = nil) {
        guard connected else { return }
        if let tracks {
            orderedQueue = tracks
            queue = shuffled ? [track] + tracks.filter { $0.id != track.id }.shuffled() : tracks
        }
        if !queue.contains(where: { $0.id == track.id }) { queue = [track]; orderedQueue = [track] }
        if loading, current?.id == track.id {
            diagnostic?.record("request", "reuse_acquisition", fields: ["reason": "same_track_selected"])
            persistPlayback()
            return
        }
        select(track, autoplay: true, queueIndex: queue.firstIndex { $0.id == track.id })
    }

    func playPlaylist(_ tracks: [Track], at index: Int) {
        guard connected, tracks.indices.contains(index) else { return }
        shuffled = false
        orderedQueue = tracks
        queue = tracks
        select(tracks[index], autoplay: true, queueIndex: index)
    }

    private func select(_ track: Track, autoplay: Bool, at start: Double = 0, queueIndex: Int? = nil) {
        queueSelection = queueIndex ?? (current?.id == track.id ? currentIndex : queue.firstIndex { $0.id == track.id })
        stop()
        current = track
        duration = max(0, track.duration ?? 0)
        position = start
        playbackFailure = nil
        message = nil
        wantsPlayback = autoplay
        persistPlayback()
        guard autoplay else { return }
        resumePlayback()
    }

    func resumePlayback() {
        guard let current, !loading else { return }
        let retryOf = diagnosticFailed ? diagnostic?.id : nil
        if diagnostic == nil || diagnosticFailed {
            let entry = localCatalog?.entries.first { $0.track.id == current.id }
            diagnostic = diagnostics.begin(title: current.title, track: current.id,
                sha256: entry?.sha256, library: localCatalog?.id, retryOf: retryOf)
            diagnostic?.record("environment", "runtime", fields: ["bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
                "app_path": Bundle.main.bundleURL.path, "settings_root": localStore.root.path,
                "catalog_path": localStore.root.appendingPathComponent("catalog.sqlite").path])
            diagnosticFailed = false
            diagnosticAdvanced = false
            diagnosticPosition = nil
        }
        let trace = diagnostic
        trace?.record("request", "resume", fields: ["already_playing": String(playing)])
        guard tracks.contains(where: { $0.id == current.id }) else {
            trace?.record("request", "rejected", outcome: "failed", fields: ["reason": "track_removed"], terminal: true)
            diagnosticFailed = true
            failedDiagnosticID = trace?.id
            wantsPlayback = false
            playbackFailure = "この曲はライブラリから削除されているため再生できません。別の曲を選んでください。"
            return
        }
        if playing { return }
#if os(iOS)
        guard activateAudio() else { wantsPlayback = false; return }
#endif
        wantsPlayback = true
        playbackFailure = nil
        if player?.currentItem?.status == .failed {
            let start = position
            let retryTrace = diagnostic
            diagnostic = nil
            stop()
            diagnostic = retryTrace
            duration = max(0, current.duration ?? 0)
            position = start
            wantsPlayback = true
        }
        if let player, player.currentItem?.status != .failed {
            trace?.record("player", "reuse")
            if let url = transfer.playbackCache.protectedURL {
                do { try transfer.playbackCache.markPlayed(url) }
                catch { message = "キャッシュの利用日時を更新できませんでした。\(error.localizedDescription)" }
            }
            if duration > 0 && position >= duration { seek(to: 0) }
            player.play()
            return
        }
        let request = playbackRequest
        playbackPreparation = .checking
        loading = true
        let preceding = acquisition
        acquisition = Task { [weak self] in
            guard let self else { return }
            do {
                await preceding?.value
                try Task.checkCancellation()
                let url = try await transfer.playbackFile(current, diagnostic: trace, allowAcquisition: !backgrounded) { [weak self] phase in
                    guard let self, self.playbackRequest == request, self.wantsPlayback else { return }
                    self.playbackPreparation = phase
                }
                // A cached file stays leased until preparePlayer makes it the protected one.
                defer { transfer.playbackCache.release(url) }
                try Task.checkCancellation()
                guard playbackRequest == request, wantsPlayback else { return }
                preparePlayer(url, at: duration > 0 && position >= duration ? 0 : position)
            } catch {
                trace?.failure("acquisition", error, terminal: playbackRequest == request)
                guard playbackRequest == request else { return }
                diagnosticFailed = true
                failedDiagnosticID = trace?.id
                loading = false
                wantsPlayback = false
                playbackFailure = "音源を取得できませんでした。\(error.localizedDescription)"
                persistPlayback()
            }
        }
    }

    private func preparePlayer(_ url: URL, at start: Double) {
        let trace = diagnostic
        trace?.file(url, role: "player_input", stage: "player")
        diagnosticPosition = nil
        loading = true
        playbackPreparation = .preparing
        transfer.playbackCache.protectedURL = url
        do { try transfer.playbackCache.markPlayed(url) }
        catch { message = "キャッシュの利用日時を更新できませんでした。\(error.localizedDescription)" }
        let player = makePlayer(url)
        player.volume = Float(volume)
        trace?.record("player", "created", fields: ["has_item": String(player.currentItem != nil)])
        guard let item = player.currentItem else { return }
        self.player = player
        trace?.record("player", "item_status", fields: ["status": String(item.status.rawValue)])
        if item.status == .failed, let error = item.error { trace?.failure("player", error, terminal: true) }
        playbackErrorObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item, queue: .main) { notification in
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                trace?.failure("player", error, terminal: true)
            } else { trace?.record("player", "failed_to_end", outcome: "failed", terminal: true) }
        }
        waitingObservation = player.observe(\.reasonForWaitingToPlay, options: [.initial, .new]) { player, _ in
            trace?.record("player", "waiting_reason", fields: ["reason": player.reasonForWaitingToPlay?.rawValue ?? "none"])
        }
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                trace?.record("player", "time_control", fields: ["status": String(player.timeControlStatus.rawValue), "waiting_reason": player.reasonForWaitingToPlay?.rawValue ?? "none"])
                playing = player.timeControlStatus == .playing
                loading = wantsPlayback && player.currentItem?.status != .failed && player.currentItem?.status != .readyToPlay
            }
        }
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                trace?.record("player", "item_status", fields: ["status": String(item.status.rawValue)])
                if item.status == .failed {
                    if let error = item.error { trace?.failure("player", error, terminal: true) }
                    else { trace?.record("player", "item_failed", outcome: "failed", terminal: true) }
                }
                guard let self, self.player?.currentItem === item, item.status == .failed else { return }
                diagnosticFailed = true
                failedDiagnosticID = trace?.id
                self.player?.pause()
                playing = false
                loading = false
                wantsPlayback = false
                playbackFailure = "曲を再生できませんでした。再試行するか、別の曲を選んでください。"
            }
        }
        durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                let seconds = item.duration.seconds
                if seconds.isFinite && seconds > 0 { duration = seconds }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self, weak player] time in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player, seeking == nil else { return }
                if time.seconds.isFinite {
                    if !diagnosticAdvanced, player.timeControlStatus == .playing,
                       let previous = diagnosticPosition, time.seconds > previous, time.seconds - previous < 1 {
                        diagnosticAdvanced = true
                        trace?.record("player", "first_advancement", outcome: "succeeded")
                    }
                    diagnosticPosition = time.seconds
                    position = max(0, time.seconds)
                    if position.rounded(.down) != lastPersistedSecond { persistPlayback() }
                }
            }
        }
        finishObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                playing = false
                loading = false
                trace?.record("player", "ended", outcome: "completed", terminal: true)
                position = duration
                wantsPlayback = false
                if repeatMode == .one, let current { select(current, autoplay: true) }
                else if canGoNext {
                    if shuffled && repeatMode == .all && currentIndex == queue.count - 1 {
                        var nextRound = orderedQueue.shuffled()
                        if nextRound.count > 1, nextRound.first?.id == current?.id { nextRound.swapAt(0, 1) }
                        queue = nextRound
                        if let first = queue.first { select(first, autoplay: true, queueIndex: 0) }
                    } else { advance(autoplay: true) }
                } else {
                    let end = duration
                    stop()
                    duration = end
                    position = end
                    persistPlayback()
                }
            }
        }
        if start > 0 {
            let request = playbackRequest
            seeking = request
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
                Task { @MainActor in
                    guard let self, let player, self.player === player, self.playbackRequest == request else { return }
                    self.seeking = nil
                    if self.wantsPlayback { player.play() }
                }
            }
        } else { player.play() }
    }

    func previous() {
        guard let index = currentIndex else { return }
        let autoplay = wantsPlayback || playing
        if position >= 3 || (index == 0 && repeatMode != .all) {
            if canSeek { seek(to: 0) }
            else if let current { select(current, autoplay: autoplay) }
        } else {
            let previous = index > 0 ? index - 1 : queue.count - 1
            select(queue[previous], autoplay: autoplay, queueIndex: previous)
        }
    }

    func next() {
        advance(autoplay: wantsPlayback || playing)
    }

    private func advance(autoplay: Bool) {
        guard canGoNext, let index = currentIndex else { return }
        let next = (index + 1) % queue.count
        select(queue[next], autoplay: autoplay, queueIndex: next)
    }

    func setShuffle(_ enabled: Bool) {
        guard shuffled != enabled else { return }
        shuffled = enabled
        if enabled {
            if let index = currentIndex {
                queue = Array(queue.prefix(index + 1)) + queue.dropFirst(index + 1).shuffled()
            } else { queue = orderedQueue.shuffled() }
        } else {
            let occurrence = currentIndex.map { index in queue.prefix(index + 1).filter { $0.id == current?.id }.count - 1 } ?? 0
            queue = orderedQueue
            let indices = queue.indices.filter { queue[$0].id == current?.id }
            queueSelection = indices.indices.contains(occurrence) ? indices[occurrence] : nil
        }
        persistPlayback()
    }

    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(1, max(0, value))
        player?.volume = Float(volume)
    }

    func seek(to seconds: Double) {
        guard let player, canSeek, seconds.isFinite else { return }
        diagnosticPosition = nil
        let target = min(max(0, seconds), duration)
        let id = UUID()
        seeking = id
        position = target
        persistPlayback()
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player, seeking == id else { return }
                seeking = nil
            }
        }
    }

    func togglePlayback(in tracks: [Track]) {
        guard let first = tracks.first else { return }
        play(first, in: tracks)
    }

    func togglePlayback() {
        if playing || loading || wantsPlayback { pause() }
        else { resumePlayback() }
    }

    func pause() {
        diagnostic?.record("player", "pause")
        diagnosticPosition = nil
        playbackRequest = UUID()
        acquisition?.cancel()
        wantsPlayback = false
        seeking = nil
        player?.pause()
        playing = false
        loading = false
        persistPlayback()
    }

    func setBackgrounded(_ backgrounded: Bool) {
        self.backgrounded = backgrounded
        transfer.setSavesBackgrounded(backgrounded)
        if backgrounded, loading, player == nil {
            pause()
            playbackFailure = "バックグラウンドでは音源を取得できません。アプリを開いて再試行してください。"
        }
    }

    private func stop() {
        diagnostic?.record("player", "stop_or_replace", outcome: "stopped", terminal: true)
        diagnostic = nil
        diagnosticFailed = false
        diagnosticPosition = nil
        playbackRequest = UUID()
        acquisition?.cancel()
        wantsPlayback = false
        observation = nil
        itemObservation = nil
        waitingObservation = nil
        durationObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }
        finishObserver = nil
        if let playbackErrorObserver { NotificationCenter.default.removeObserver(playbackErrorObserver) }
        playbackErrorObserver = nil
        player?.pause()
        player = nil
        transfer.playbackCache.protectedURL = nil
        transfer.playbackCache.requestTrim(after: acquisition) { [weak self] error in
            self?.message = "再生キャッシュを整理できませんでした。\(error.localizedDescription)"
        }
        playing = false
        loading = false
        seeking = nil
        position = 0
        duration = 0
    }

    func persistPlayback() {
        guard !restoringPlayback, let id = localCatalog?.id, let current else { return }
        do {
            let snapshot = PlaybackSnapshot(queueSelection: currentIndex, library: id, current: current, position: position, duration: duration,
                queue: queue, orderedQueue: orderedQueue, shuffled: shuffled, repeatMode: repeatMode)
            try JSONEncoder().encode(snapshot).write(to: localStore.root.appendingPathComponent("playback.json"), options: .atomic)
            lastPersistedSecond = position.rounded(.down)
        } catch { message = "再生位置を保存できませんでした。\(error.localizedDescription)" }
    }

    private func restorePlayback() {
        guard let id = localCatalog?.id, restoredPlaybackLibrary != id else { return }
        restoredPlaybackLibrary = id
        let url = localStore.root.appendingPathComponent("playback.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode(PlaybackSnapshot.self, from: Data(contentsOf: url))
            guard saved.library == id, saved.position.isFinite, saved.position >= 0, saved.duration.isFinite, saved.duration >= 0,
                  saved.queue.contains(where: { $0.id == saved.current.id }) else { return }
            restoringPlayback = true
            defer { restoringPlayback = false }
            let latest = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            queue = saved.queue.map { latest[$0.id] ?? $0 }
            orderedQueue = saved.orderedQueue.map { latest[$0.id] ?? $0 }
            shuffled = saved.shuffled
            repeatMode = saved.repeatMode
            current = latest[saved.current.id] ?? saved.current
            queueSelection = saved.queueSelection
            duration = saved.duration
            position = saved.duration > 0 ? min(saved.position, saved.duration) : saved.position
        } catch { message = "前回の再生状態を復元できませんでした。\(error.localizedDescription)" }
    }

    func closeLibrary() {
        inventoryTask?.cancel()
        pendingLocalPlaybackTrack = nil
        pendingLocalCopyRemovals = []
        removalLibraryID = nil
        localCopiesToRemove = []
        playlists = []
        playlistConflicts = []
        playlistTracksByIdentity = [:]
        playlistMessage = nil
        catalogGeneration = UUID()
        transfer.cancelSavePreparations()
        transfer.stopSaveWorker()
        transfer.cancel()
#if os(iOS)
        downloaded = []
#endif
        localFiles = [:]
        managedTracks = []
        localCatalog = nil
        stop()
        current = nil
        restoredPlaybackLibrary = nil
        try? FileManager.default.removeItem(at: localStore.root.appendingPathComponent("playback.json"))
        tracks = []
        queue = []
        orderedQueue = []
        artworkURLs = [:]
        connected = false
        search = ""
        navigate(.albums)
        message = nil
        refreshing = false
    }

    func hasManagedCopy(_ track: Track) -> Bool {
        return managedTracks.contains(track.id)
    }

    func canRemoveLocalCopy(_ track: Track) -> Bool {
        hasManagedCopy(track)
    }

    func isLocalCopyRemovalPending(_ track: Track) -> Bool {
        guard localCatalog?.id == removalLibraryID else { return false }
        return pendingLocalCopyRemovals.contains { $0.id == track.id }
    }

    func removeAllSavedMusic() async {
        do {
            try await transfer.removeAllSavedAudio { [weak self] in
                guard let self else { return }
                // A track being prepared may be reading from the saved folder too.
                if acquiringAudio || openedSavedFile != nil { stop() }
            }
        } catch { message = error.localizedDescription }
    }

    func removeLocalCopies(_ confirmedTracks: [Track]) {
        guard let libraryID = localCatalog?.id else { return }
        if removalLibraryID != libraryID { pendingLocalCopyRemovals = [] }
        removalLibraryID = libraryID
        for track in confirmedTracks where canRemoveLocalCopy(track) && !isLocalCopyRemovalPending(track) {
            pendingLocalCopyRemovals.append(track)
        }
        localCopiesToRemove = []
        resumeLocalCopyRemovals()
    }

    private func resumeLocalCopyRemovals() {
        guard transfer.readyForLocalCopyRemoval, !pendingLocalCopyRemovals.isEmpty else { return }
        guard localCatalog?.id == removalLibraryID else {
            pendingLocalCopyRemovals = []
            removalLibraryID = nil
            return
        }
        do {
            let tracks = pendingLocalCopyRemovals.filter(canRemoveLocalCopy)
            try transfer.cancelSaves(containing: tracks)
            var failure: Error?
            var entries: [LocalEntry] = []
            for track in tracks {
                do {
                    guard let entry = try localStore.database().playbackEntry(track.id)?.entry else { throw LocalMusicError.invalidData }
                    entries.append(entry)
                } catch { failure = failure ?? error }
            }
            // The player may still hold audio from before a catalog update, or the cache copy of the same audio,
            // so compare the audio of the saved file it has open, whatever its extension, with the audio whose files go.
            // Audio another saved track still holds keeps its file, so playing it goes on.
            // When the pins cannot be read, the removal below still runs, and playback of any of this audio stops.
            let removed = (try? transfer.audioRemoved(with: entries)) ?? Set(entries.map(\.sha256))
            if openedSavedFile.map({ removed.contains($0.deletingPathExtension().lastPathComponent) }) == true
                || (acquiringAudio && tracks.contains { $0.id == current?.id }) { stop() }
            // One file that cannot be removed does not stop the others; its pin stays so it still shows as saved.
            for entry in entries {
                do { try transfer.removeSavedCopy(entry) }
                catch LocalMusicError.transferBusy { throw LocalMusicError.transferBusy }
                catch { failure = failure ?? error }
            }
            refreshLocalFiles()
            if let failure { message = failure.localizedDescription }
        } catch LocalMusicError.transferBusy {
            return
        } catch { message = error.localizedDescription }
        pendingLocalCopyRemovals = []
        removalLibraryID = nil
        transfer.resumeSaves()
    }

#if os(iOS)
    private func activateAudio() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            message = "音声出力を開始できませんでした。再生をもう一度お試しください。"
            return false
        }
    }
#endif
}
