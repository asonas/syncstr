import AVFoundation
import Combine
import SwiftUI

struct Album: Identifiable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
    var artwork: String? = nil
    var coverArt: String? { artwork ?? tracks.compactMap(\.coverArt).first }
}

#if os(macOS)
enum AlbumSortField { case title, artist }
#endif

enum LibraryDestination: String, CaseIterable {
    case albums = "アルバム"
    case artists = "アーティスト"
    case songs = "曲"
    case hiddenAlbums = "非表示にしたアルバム"

    var symbol: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "person.2"
        case .songs: "music.note.list"
        case .hiddenAlbums: "eye.slash"
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
    @Published var tracks: [Track] = [] { didSet { rebuildAlbums() } }
    private(set) var albums: [Album] = []
    private(set) var hiddenAlbums: [Album] = []
    private(set) var catalogTracks: [Track] = []
    private var albumsByID: [String: Album] = [:]
    private var allAlbums: [Album] = []
    private var visibilityChange: Task<Void, Never>?
    private var visibilityGeneration = UUID()
    @Published private var visibilityRequests: [String: Int] = [:]
    private var albumsByArtist: [String: [Album]] = [:]
    private var tracksByArtist: [String: [Track]] = [:]
    private var artistNames: [String] = []
    @Published var connected = false
    @Published var current: Track?
    @Published var playing = false
    @Published var loading = false
    @Published var refreshing = false
    @Published var restoringSession = true
    @Published var message: String?
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var queue: [Track] = []
    @Published private(set) var shuffled = false
    @Published var repeatMode = PlaybackRepeat.off { didSet { persistPlayback() } }
    @Published private(set) var volume = 1.0
    @Published var destination = LibraryDestination.albums
#if os(macOS)
    @Published var albumSortField = AlbumSortField.title
    @Published var albumSortDescending = false
#endif
    @Published var selectedAlbum: String?
    @Published var selectedArtist: String?
    @Published var search = ""
    @Published var sidebarVisible = true
    @Published var showingNowPlaying = false
    @Published var showingOrganization = false
    @Published var localCopiesToRemove: [Track] = []
    @Published private(set) var artworkURLs: [String: URL] = [:]
    let localStore: LocalMusicStore
    let transfer: LocalTransfer
    private(set) var localFiles: [String: URL] = [:]
    private(set) var localCatalog: LocalCatalog?
    private var transferChanges: AnyCancellable?
#if os(macOS)
    private var localFolder: LocalFolder?
    var hasLocalFolder: Bool { localFolder != nil }
    private var scopedFolder: URL?
#endif
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

    init(makePlayer: @escaping (URL) -> AVPlayer = { AVPlayer(url: $0) },
         diagnostics: PlaybackDiagnostics? = nil,
         localStore: LocalMusicStore = LocalMusicStore(),
         pairingSecrets: CredentialStore = CredentialStore(service: "as.ason.syncstr.local-pair"),
         peerSecrets: CredentialStore = CredentialStore(service: "as.ason.syncstr.p2p.identity"),
         peerPairing: CredentialStore = CredentialStore(service: "as.ason.syncstr.p2p.peer")) {
        self.makePlayer = makePlayer
        self.diagnostics = diagnostics ?? PlaybackDiagnostics(root: localStore.root.appendingPathComponent("PlaybackDiagnostics"))
        self.localStore = localStore
        self.transfer = LocalTransfer(store: localStore, secrets: pairingSecrets, peerSecrets: peerSecrets, peerPairing: peerPairing, diagnostics: self.diagnostics)
        transfer.onCatalog = { [weak self] catalog in try self?.openLocal(catalog) }
        transfer.onOrganization = { [weak self] organization in
            do { try self?.saveOrganization(organization) }
            catch { self?.message = error.localizedDescription }
        }
        transfer.onSaved = { [weak self] in
            guard let self else { return }
            let wasLocal = current.map { self.localFiles[$0.id] != nil } ?? false
            refreshLocalFiles()
            if wasLocal, transfer.clusterRegistration != nil, let current, localFiles[current.id] == nil { stop() }
        }
        transferChanges = transfer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    private func rebuildAlbums() {
        let organization = localCatalog?.organization
        let records = Dictionary(uniqueKeysWithValues: (organization?.tracks ?? []).map { ($0.id, $0) })
        let images = organization.map(AlbumArtworkLookup.init)
        albums = Dictionary(grouping: tracks, by: \.albumKey).map { key, tracks in
            Album(id: key, title: tracks.first?.album ?? "アルバム名不明",
                  artist: organization?.artistCredit(for: tracks.sorted {
                      ($0.discNumber ?? 1, $0.track ?? 0, $0.id) < ($1.discNumber ?? 1, $1.track ?? 0, $1.id)
                  }, records: records) ?? tracks.first?.artist ?? "アーティスト不明",
                  tracks: tracks.sorted {
                      if ($0.discNumber ?? 1) != ($1.discNumber ?? 1) {
                          return ($0.discNumber ?? 1) < ($1.discNumber ?? 1)
                      }
                      if ($0.track ?? 0) != ($1.track ?? 0) { return ($0.track ?? 0) < ($1.track ?? 0) }
                      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                  }, artwork: organization.flatMap { images?.coverAsset(for: key, in: $0) })
        }.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            return $0.id < $1.id
        }
        albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        allAlbums = albums
        rebuildVisibleCatalog()
    }

    private func rebuildVisibleCatalog() {
        hiddenAlbums = allAlbums.filter { isAlbumHidden($0.id) }
        let hiddenIDs = Set(hiddenAlbums.map(\.id))
        albums = allAlbums.filter { !hiddenIDs.contains($0.id) }
        catalogTracks = tracks.filter { !hiddenIDs.contains($0.albumKey) }
        tracksByArtist = Dictionary(grouping: catalogTracks) { $0.artist ?? "アーティスト不明" }
        artistNames = tracksByArtist.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        albumsByArtist = [:]
        for album in albums {
            for artist in Set(album.tracks.map { $0.artist ?? "アーティスト不明" }) {
                albumsByArtist[artist, default: []].append(album)
            }
        }
    }

    func isAlbumHidden(_ id: String) -> Bool { localCatalog?.organization?.isHidden(id) ?? false }

    func isSavingAlbumVisibility(_ id: String) -> Bool { visibilityRequests[id, default: 0] > 0 }

    func albumVisibilityLabel(_ id: String) -> String {
        if isSavingAlbumVisibility(id) { return "保存しています…" }
        return isAlbumHidden(id) ? "非表示を解除する" : "非表示にする"
    }

    @discardableResult
    func setAlbumHidden(_ id: String, hidden: Bool) -> Task<Void, Never> {
        setAlbumsHidden([id], hidden: hidden)
    }

    @discardableResult
    func setAlbumsHidden(_ ids: Set<String>, hidden: Bool) -> Task<Void, Never> {
        let previous = visibilityChange
        let generation = visibilityGeneration
        let libraryID = localCatalog?.id
        for id in ids { visibilityRequests[id, default: 0] += 1 }
        let task = Task {
            defer {
                if visibilityGeneration == generation {
                    for id in ids {
                        visibilityRequests[id, default: 0] -= 1
                        if visibilityRequests[id] == 0 { visibilityRequests.removeValue(forKey: id) }
                    }
                }
            }
            await previous?.value
            guard visibilityGeneration == generation, let libraryID, localCatalog?.id == libraryID else { return }
            do {
                let result = try await localStore.setAlbumsHidden(ids, hidden: hidden, libraryID: libraryID)
                guard visibilityGeneration == generation, localCatalog?.id == libraryID,
                      var organization = localCatalog?.organization else { return }
                // Apply visibility only so edits received during the save remain intact.
                let existing = Set(organization.choices.map(\.id))
                organization.choices += result.organization.choices.filter { $0.kind == "visibility" && !existing.contains($0.id) }
                organization.preferred.merge(result.organization.preferred.filter { $0.key.hasPrefix("visibility:") }) { _, saved in saved }
                localCatalog?.organization = organization
                objectWillChange.send()
                rebuildVisibleCatalog()
                if let selectedAlbum, ids.contains(selectedAlbum) { self.selectedAlbum = nil }
#if os(macOS)
                if var folder = localFolder, folder.catalog.id == libraryID, let catalog = localCatalog {
                    folder.catalog = catalog
                    localFolder = folder
                    transfer.updateHostedCatalog(catalog)
                }
#endif
                transfer.organizationChanged(pendingMetadata: result.pendingMetadata)
            } catch {
                if visibilityGeneration == generation { message = error.localizedDescription }
            }
        }
        visibilityChange = task
        return task
    }

    func album(id: String) -> Album? { albumsByID[id] }
    func albums(for artist: String) -> [Album] { albumsByArtist[artist] ?? [] }
    func tracks(for artist: String) -> [Track] { tracksByArtist[artist] ?? [] }

    var visibleAlbums: [Album] {
        let albums = destination == .hiddenAlbums ? hiddenAlbums : self.albums
        let filtered = albums.filter { search.isEmpty || $0.title.localizedStandardContains(search)
            || $0.artist.localizedStandardContains(search) }
#if os(macOS)
        return filtered.sorted { lhs, rhs in
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
#else
        return filtered
#endif
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

    var currentIndex: Int? { queue.firstIndex { $0.id == current?.id } }
    var canGoPrevious: Bool { currentIndex != nil }
    var canGoNext: Bool { currentIndex.map { $0 + 1 < queue.count || repeatMode == .all } ?? false }
    var canSeek: Bool { player?.currentItem?.status == .readyToPlay && !loading && duration > 0 }
    var playbackAction: String { loading ? "再生の準備をキャンセル" : playing || wantsPlayback ? "一時停止" : "再生" }
    var savedAudioBytes: Int64 {
        var counted = Set<String>()
        return (localCatalog?.entries ?? []).reduce(0) { total, entry in
            guard localStore.hasFile(entry), counted.insert(entry.sha256).inserted else { return total }
            return total + Int64(entry.track.size ?? 0)
        }
    }

    func navigate(_ destination: LibraryDestination) {
        self.destination = destination
        selectedAlbum = nil
        selectedArtist = nil
        showingNowPlaying = false
    }

    func restoreLibrary() async {
        transfer.connectionEvent("startup_restore_called")
        guard !restoredLibrary else {
            transfer.connectionEvent("startup_connect_skipped", fields: ["reason": "already_restored"])
            return
        }
        restoredLibrary = true
        if FileManager.default.fileExists(atPath: localStore.root.appendingPathComponent("active").path) {
            await openSavedLocalLibrary()
        }
        // Local music must remain usable while Keychain or remote setup is unavailable.
        restoringSession = false
#if os(macOS)
        Task { [weak self] in
            guard let self else { return }
            await transfer.restorePairing()
            if transfer.pairedName != nil { await startPairing(newPairing: false) }
        }
#endif
        await transfer.restorePeer()
        if transfer.clusterRegistration != nil && !transfer.busy { transfer.connectCluster() }
        else { transfer.connectionEvent("startup_connect_skipped", fields: ["reason": transfer.busy ? "busy" : "no_in_memory_cluster_registration", "legacy_auto_connect": "not_requested"]) }
        transfer.resumeSaves()
    }

    func reload() {
        transfer.connectionEvent("library_reload_called")
        if transfer.clusterRegistration != nil { transfer.connectCluster(); return }
#if os(macOS)
        if let folder = localFolder, folder.catalog.id == localCatalog?.id { transfer.connectionEvent("reload_connect_skipped", fields: ["reason": "local_folder_rescan"]); Task { await chooseFolder(folder.root) }; return }
#endif
        if transfer.peerName != nil { Task { await transfer.reconnectPeer() } }
        else { transfer.connectionEvent("reload_connect_skipped", fields: ["reason": "peer_name_unavailable"]) }
    }

    func openLocal(_ catalog: LocalCatalog) throws {
        var catalog = catalog
        catalog.organize()
        try localStore.save(catalog)
        try Data().write(to: localStore.root.appendingPathComponent("active"), options: .atomic)
        let sameLibrary = localCatalog?.id == catalog.id
        if !sameLibrary {
            visibilityGeneration = UUID()
            visibilityRequests = [:]
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
        tracks = organizedTracks(catalog)
        artworkURLs = Dictionary(uniqueKeysWithValues: catalog.entries.compactMap { entry in
            entry.track.coverArt.map { ($0, localStore.artworkURL(entry)) }
        })
        for asset in catalog.organization?.artwork?.assets.keys.map({ $0 }) ?? [] { artworkURLs[asset] = localStore.artworkURL(asset: asset) }
        connected = true
        restoringSession = false
        refreshing = false
        message = nil
        if !sameLibrary { navigate(.albums) }
        else if let selectedAlbum { self.selectedAlbum = catalog.organization?.canonical(selectedAlbum) }
        refreshLocalFiles()
        restorePlayback()
        if let current, !tracks.contains(where: { $0.id == current.id }) {
            pause()
            playbackFailure = "この曲はライブラリから削除されているため再生できません。別の曲を選んでください。"
        }
    }

    private func organizedTracks(_ catalog: LocalCatalog) -> [Track] {
        let organization = catalog.organization
        let images = organization.map(AlbumArtworkLookup.init)
        let albums = Dictionary(uniqueKeysWithValues: (organization?.albums ?? []).map { ($0.id, $0) })
        var covers: [String: String] = [:]
        if let organization, let images {
            for album in Set(images.albumIDs.values).union(catalog.entries.compactMap(\.track.albumId)) {
                covers[album] = images.coverAsset(for: album, in: organization)
            }
        }
        return catalog.entries.map { entry in
            var track = entry.track
            let id = organization?.canonicalTrack(track.id) ?? track.id
            track.albumId = images?.albumIDs[id] ?? track.albumId
            if let id = track.albumId, let album = albums[id] { track.album = album.title }
            if let album = track.albumId, let asset = covers[album] { track.coverArt = asset }
            return track
        }
    }

    func saveOrganization(_ organization: AlbumOrganization) throws {
        guard var catalog = localCatalog else { throw LocalMusicError.invalidData }
        let selectedMembers = albums.first { $0.id == selectedAlbum }?.tracks.map(\.id) ?? []
        try organization.validate()
        catalog.organization = organization
        catalog.organize()
        try localStore.save(catalog, clusterEdits: true)
        localCatalog = catalog
        tracks = organizedTracks(catalog)
        for asset in catalog.organization?.artwork?.assets.keys.map({ $0 }) ?? [] { artworkURLs[asset] = localStore.artworkURL(asset: asset) }
        if let id = current?.id, let updated = tracks.first(where: { $0.id == id }) { current = updated }
        if let selectedAlbum { self.selectedAlbum = catalog.organization?.canonical(selectedAlbum) }
        if let selectedAlbum, !albums.contains(where: { $0.id == selectedAlbum }) {
            let moved = Set(selectedMembers.compactMap { catalog.organization?.albumID(for: $0) })
            self.selectedAlbum = moved.count == 1 ? moved.first : nil
        }
#if os(macOS)
        if var folder = localFolder, folder.catalog.id == catalog.id {
            folder.catalog = catalog
            localFolder = folder
            transfer.updateHostedCatalog(catalog)
        }
#endif
    }

    func reassociate(old: String, replacement: String, organization: AlbumOrganization) throws {
        guard var catalog = localCatalog, old != replacement,
              !catalog.entries.contains(where: { $0.track.id == old }),
              let index = catalog.entries.firstIndex(where: { $0.track.id == replacement }),
              let oldRecord = organization.tracks.first(where: { $0.id == old }),
              !organization.choices.contains(where: { $0.subject == replacement && $0.kind == "membership" }) else {
            throw LocalMusicError.invalidData
        }
        var organization = organization
        var entry = catalog.entries[index]
        entry.track.id = old
        if entry.track.coverArt != nil { entry.track.coverArt = old }
        catalog.entries[index] = entry
        organization.tracks.removeAll { $0.id == replacement }
        if let recordIndex = organization.tracks.firstIndex(where: { $0.id == oldRecord.id }) {
            organization.tracks[recordIndex].sha256 = entry.sha256
            if let imported = entry.importedAlbum { organization.tracks[recordIndex].imported = imported }
        }
        catalog.organization = organization
#if os(macOS)
        if var folder = localFolder {
            folder.files[old] = folder.files.removeValue(forKey: replacement)
            folder.catalog = catalog
            try localStore.save(folder)
            localFolder = folder
        }
#endif
        try localStore.save(catalog)
        localCatalog = catalog
        tracks = organizedTracks(catalog)
        refreshLocalFiles()
        transfer.updateHostedCatalog(catalog)
    }

    func refreshLocalFiles() {
        guard let localCatalog else { return }
        localFiles = Dictionary(uniqueKeysWithValues: localCatalog.entries.filter { localStore.hasFile($0) }
            .map { ($0.track.id, localStore.fileURL($0)) })
#if os(macOS)
        if let folder = localFolder, folder.catalog.id == localCatalog.id {
            localFiles.merge(folder.files) { _, original in original }
        }
#endif
#if os(iOS)
        downloaded = Set(localFiles.keys)
#endif
    }

    var hasSavedLocalLibrary: Bool {
        localStore.hasCatalog
    }

    func openSavedLocalLibrary() async {
        do {
#if os(macOS)
            if let snapshot = try localStore.snapshot(), try localStore.database().clusterRegistration() != nil {
                try openLocal(snapshot.catalog)
                if snapshot.sourceRoot != nil {
                    do {
                        let data = try Data(contentsOf: localStore.root.appendingPathComponent("folder.bookmark"))
                        var stale = false
                        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                            relativeTo: nil, bookmarkDataIsStale: &stale)
                        let scoped = url.startAccessingSecurityScopedResource()
                        if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
                        scopedFolder = scoped ? url : nil
                        let files = await Task.detached {
                            var files: [String: URL] = [:]
                            for entry in snapshot.catalog.entries {
                                guard let path = snapshot.sourcePaths[entry.track.id] else { continue }
                                let file = url.appendingPathComponent(path).resolvingSymlinksInPath()
                                guard file.path.hasPrefix(url.resolvingSymlinksInPath().path + "/"),
                                      (try? LocalMusicStore.digest(file: file)) == entry.sha256 else { continue }
                                files[entry.track.id] = file
                            }
                            return files
                        }.value
                        localFolder = LocalFolder(root: url, catalog: snapshot.catalog, files: files, skipped: [])
                        refreshLocalFiles()
                    } catch { message = "元の音楽フォルダを開けませんでした。ライブラリと保存済み音源は保持しています。設定からアクセスを確認してください。" }
                }
                return
            }
            if let snapshot = try localStore.snapshot(), snapshot.sourceRoot == nil {
                try openLocal(snapshot.catalog)
                return
            }
            let data = try Data(contentsOf: localStore.root.appendingPathComponent("folder.bookmark"))
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale)
            await chooseFolder(url)
#else
            if let catalog = try localStore.load() { try openLocal(catalog) }
#endif
        } catch { message = error.localizedDescription }
    }

#if os(macOS)
    func chooseFolder(_ url: URL) async {
        guard !refreshing || restoringSession else { return }
        refreshing = true
        defer { refreshing = false }
        let scoped = url.startAccessingSecurityScopedResource()
        var releaseScopeOnFailure = scoped
        do {
            let previous = try localStore.snapshot()
            let bookmarkURL = localStore.root.appendingPathComponent("folder.bookmark")
            var previousFolder = localFolder?.root
            if previousFolder == nil, let data = try? Data(contentsOf: bookmarkURL) {
                var stale = false
                previousFolder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            let sameFolder = previousFolder?.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.resolvingSymlinksInPath().path
            let id = sameFolder ? previous?.catalog.id ?? UUID().uuidString : UUID().uuidString
            var folder = try await Task.detached { try await LocalFolder.scan(url, id: id, previous: previous) }.value
            if sameFolder, let previous {
                let scanned = Set(folder.catalog.entries.map { $0.track.id })
                folder.catalog.entries += previous.catalog.entries.filter { !scanned.contains($0.track.id) && localStore.hasFile($0) }
            }
            try localStore.prepare()
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try localStore.save(folder)
            try bookmark.write(to: localStore.root.appendingPathComponent("folder.bookmark"), options: .atomic)
            try openLocal(folder.catalog)
            if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
            scopedFolder = scoped ? url : nil
            releaseScopeOnFailure = false
            localFolder = folder
            refreshLocalFiles()
            if !folder.skipped.isEmpty { message = "読み込めなかった音源: " + folder.skipped.joined(separator: "、") }
            if transfer.pairedName != nil { try await transfer.host(folder) }
        } catch {
            if releaseScopeOnFailure { url.stopAccessingSecurityScopedResource() }
            if localCatalog == nil, let saved = try? localStore.load() {
                try? openLocal(saved)
            }
            message = error.localizedDescription
        }
    }

    func startPairing(newPairing: Bool = true) async {
        guard let localFolder else { return }
        do {
            guard try localStore.database().clusterRegistration() == nil else { return }
            try await transfer.host(localFolder, newPairing: newPairing)
        }
        catch { message = error.localizedDescription }
    }
#endif

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
        select(track, autoplay: true)
    }

    private func select(_ track: Track, autoplay: Bool, at start: Double = 0) {
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
#if os(macOS)
        if diagnostic == nil || diagnosticFailed {
            let entry = localCatalog?.entries.first { $0.track.id == current.id }
            diagnostic = diagnostics.begin(title: current.title, track: current.id,
                sha256: entry?.sha256, library: localCatalog?.id, retryOf: retryOf)
            diagnostic?.record("environment", "runtime", fields: ["bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
                "app_path": Bundle.main.bundleURL.path, "settings_root": localStore.root.path,
                "catalog_path": localStore.root.appendingPathComponent("catalog.sqlite").path,
                "credential_storage": "keychain", "peer_credential_service": "as.ason.syncstr.p2p.peer"])
            diagnosticFailed = false
            diagnosticAdvanced = false
            diagnosticPosition = nil
        }
#endif
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
        if let url = localFiles[current.id] {
            var role = "saved_copy"
            #if os(macOS)
            if localFolder?.files[current.id] != nil { role = "original_folder" }
            #endif
            trace?.file(url, role: role)
            trace?.record("selection", "mode", fields: ["mode": "local", "reason": role])
            preparePlayer(url, at: duration > 0 && position >= duration ? 0 : position)
            return
        }
        do {
            if let url = try transfer.cachedPlaybackFile(current, diagnostic: trace) {
                trace?.record("selection", "mode", fields: ["mode": "local", "reason": "cache_hit"])
                preparePlayer(url, at: duration > 0 && position >= duration ? 0 : position)
                return
            }
        } catch { trace?.failure("cache", error) }
        trace?.record("local", "acquisition_required", fields: ["reason": "no_usable_local_file"])
        if backgrounded {
            trace?.record("request", "rejected", outcome: "failed", fields: ["reason": "backgrounded"], terminal: true)
            diagnosticFailed = true
            failedDiagnosticID = trace?.id
            wantsPlayback = false
            playbackFailure = "バックグラウンドでは次の音源を取得できません。アプリを開いて再試行してください。"
            return
        }
        let request = playbackRequest
        loading = true
        let preceding = acquisition
        acquisition = Task { [weak self] in
            guard let self else { return }
            do {
                await preceding?.value
                try Task.checkCancellation()
                let url = try await transfer.playbackFile(current, diagnostic: trace)
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
                        if let first = queue.first { select(first, autoplay: true) }
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
        } else { select(queue[index > 0 ? index - 1 : queue.count - 1], autoplay: autoplay) }
    }

    func next() {
        advance(autoplay: wantsPlayback || playing)
    }

    private func advance(autoplay: Bool) {
        guard canGoNext, let index = currentIndex else { return }
        select(queue[(index + 1) % queue.count], autoplay: autoplay)
    }

    func setShuffle(_ enabled: Bool) {
        guard shuffled != enabled else { return }
        shuffled = enabled
        if enabled {
            if let index = currentIndex {
                queue = Array(queue.prefix(index + 1)) + queue.dropFirst(index + 1).shuffled()
            } else { queue = orderedQueue.shuffled() }
        } else { queue = orderedQueue }
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
        do { try transfer.playbackCache.trim() }
        catch { message = "再生キャッシュを整理できませんでした。\(error.localizedDescription)" }
        playing = false
        loading = false
        seeking = nil
        position = 0
        duration = 0
    }

    func persistPlayback() {
        guard !restoringPlayback, let id = localCatalog?.id, let current else { return }
        do {
            let snapshot = PlaybackSnapshot(library: id, current: current, position: position, duration: duration,
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
            duration = saved.duration
            position = saved.duration > 0 ? min(saved.position, saved.duration) : saved.position
        } catch { message = "前回の再生状態を復元できませんでした。\(error.localizedDescription)" }
    }

    func closeLibrary() {
        visibilityGeneration = UUID()
        visibilityRequests = [:]
        transfer.cancelSavePreparations()
        transfer.stopSaveWorker()
        transfer.cancel()
#if os(macOS)
        transfer.stopHosting()
        if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
        scopedFolder = nil
        localFolder = nil
#else
        downloaded = []
#endif
        localFiles = [:]
        localCatalog = nil
        try? FileManager.default.removeItem(at: localStore.root.appendingPathComponent("active"))
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
        localCatalog?.entries.first(where: { $0.track.id == track.id }).map(localStore.hasFile) ?? false
    }

    func canRemoveLocalCopy(_ track: Track) -> Bool {
        guard hasManagedCopy(track) else { return false }
        if let registration = transfer.clusterRegistration {
            return (try? registration.membership.verify(registration.localGrant).host) == false
        }
        return true
    }

    func removeLocalCopies() {
        do {
            let tracks = localCopiesToRemove.filter(canRemoveLocalCopy)
            try transfer.cancelSaves(containing: tracks)
            if let current, tracks.contains(where: { $0.id == current.id }) { stop() }
            for track in tracks {
                guard let entry = localCatalog?.entries.first(where: { $0.track.id == track.id }) else { throw LocalMusicError.invalidData }
                try transfer.removeClusterCopy(entry)
            }
            refreshLocalFiles()
        } catch { message = error.localizedDescription }
        localCopiesToRemove = []
        transfer.resumeSaves()
    }

    func addMusic(_ files: [URL]) async {
        if transfer.clusterRegistration != nil || transfer.peerConnected {
            transfer.uploadPeer(files: files)
            return
        }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var catalog = localCatalog ?? LocalCatalog(id: UUID().uuidString, name: "マイライブラリ", entries: [])
            let prepared = try await UploadedMusic.prepare(files, organization: catalog.organization ?? AlbumOrganization(), sourceID: catalog.id)
            catalog.organization = prepared.organization
            for (original, entry) in zip(files, prepared.entries) {
                let scoped = original.startAccessingSecurityScopedResource()
                defer { if scoped { original.stopAccessingSecurityScopedResource() } }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: original, to: temporary)
                try localStore.importFile(temporary, entry: entry)
                catalog.entries.removeAll { $0.track.id == entry.track.id }
                catalog.entries.append(entry)
                try localStore.save(catalog)
            }
            try openLocal(catalog)
        } catch {
            if let saved = try? localStore.load() { try? openLocal(saved) }
            message = "音楽を追加できませんでした。\(error.localizedDescription)"
        }
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
