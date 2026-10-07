import AVFoundation
import Combine
import SwiftUI

struct Album: Identifiable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]
    var coverArt: String? { tracks.compactMap(\.coverArt).first }
}

struct LibraryUpload {
    let filename: String
    let bytes: UInt64
    let sha256: String
}

enum LibraryDestination: String, CaseIterable {
    case albums = "アルバム"
    case artists = "アーティスト"
    case songs = "曲"

    var symbol: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "person.2"
        case .songs: "music.note.list"
        }
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var server = ""
    @Published var username = ""
    @Published var password = ""
    @Published var tracks: [Track] = []
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
    @Published var destination = LibraryDestination.albums
    @Published var selectedAlbum: String?
    @Published var selectedArtist: String?
    @Published var search = ""
    @Published var sidebarVisible = true
    @Published var showingNowPlaying = false
    @Published private(set) var artworkURLs: [String: URL] = [:]
    @Published private(set) var local = false
    let localStore: LocalMusicStore
    let transfer: LocalTransfer
    private var localFiles: [String: URL] = [:]
    private var localCatalog: LocalCatalog?
    private var transferChanges: AnyCancellable?
#if os(macOS)
    private var localFolder: LocalFolder?
    private var scopedFolder: URL?
#endif
#if os(iOS)
    @Published private(set) var downloaded: Set<String> = []
    @Published private(set) var downloading: Set<String> = []
    var offlineTracks = OfflineTracks()
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var downloadAccount = ""
    private var downloadGeneration = UUID()
#endif

    private var client: Navidrome?
    private var player: AVPlayer?
    private var observation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var finishObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var pendingUploads: [String: LibraryUpload] = [:]
    private var excludedTrackIDs: Set<String> = []
    private var checkedChecksums: [String: String] = [:]
    private var seeking: UUID?
    private var restoredCredentials = false
    private let session: URLSession
    private let credentials: CredentialStore
    private let makePlayer: (URL) -> AVPlayer
    private let pollingSleep: (Duration) async throws -> Void

    init(
        session: URLSession = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil),
        credentials: CredentialStore = CredentialStore(),
        makePlayer: @escaping (URL) -> AVPlayer = { AVPlayer(url: $0) },
        pollingSleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        localStore: LocalMusicStore = LocalMusicStore()
    ) {
        self.session = session
        self.credentials = credentials
        self.makePlayer = makePlayer
        self.pollingSleep = pollingSleep
        self.localStore = localStore
        self.transfer = LocalTransfer(store: localStore)
        transfer.onCatalog = { [weak self] catalog in try self?.openLocal(catalog) }
        transfer.onSaved = { [weak self] in self?.refreshLocalFiles() }
        transferChanges = transfer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var albums: [Album] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, tracks in
            Album(id: key, title: tracks.first?.album ?? "アルバム名不明",
                  artist: tracks.first?.artist ?? "アーティスト不明",
                  tracks: tracks.sorted {
                      if ($0.discNumber ?? 1) != ($1.discNumber ?? 1) {
                          return ($0.discNumber ?? 1) < ($1.discNumber ?? 1)
                      }
                      if ($0.track ?? 0) != ($1.track ?? 0) { return ($0.track ?? 0) < ($1.track ?? 0) }
                      return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                  })
        }.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            let artistOrder = $0.artist.localizedStandardCompare($1.artist)
            if artistOrder != .orderedSame { return artistOrder == .orderedAscending }
            return $0.id < $1.id
        }
    }

    var visibleAlbums: [Album] {
        albums.filter { search.isEmpty || $0.title.localizedStandardContains(search)
            || $0.artist.localizedStandardContains(search) }
    }

    var artists: [String] {
        Set(tracks.map { $0.artist ?? "アーティスト不明" }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.filter { search.isEmpty || $0.localizedStandardContains(search) }
    }

    var visibleTracks: [Track] {
        let source: [Track]
        if !search.isEmpty {
            source = tracks
        } else if let selectedAlbum, let album = albums.first(where: { $0.id == selectedAlbum }) {
            source = album.tracks
        } else if let selectedArtist {
            source = tracks.filter { ($0.artist ?? "アーティスト不明") == selectedArtist }
        } else {
            source = tracks
        }
        return source.filter {
            search.isEmpty || $0.title.localizedStandardContains(search)
                || ($0.artist?.localizedStandardContains(search) ?? false)
                || ($0.album?.localizedStandardContains(search) ?? false)
        }
    }

    var currentIndex: Int? { queue.firstIndex { $0.id == current?.id } }
    var canGoPrevious: Bool { currentIndex.map { $0 > 0 } ?? false }
    var canGoNext: Bool { currentIndex.map { $0 + 1 < queue.count } ?? false }

    func navigate(_ destination: LibraryDestination) {
        self.destination = destination
        selectedAlbum = nil
        selectedArtist = nil
        showingNowPlaying = false
    }

    func restoreCredentials() async {
        guard !restoredCredentials else { return }
        restoredCredentials = true
        refreshing = true
        defer {
            refreshing = false
            restoringSession = false
        }
        do {
            if FileManager.default.fileExists(atPath: localStore.root.appendingPathComponent("active").path) {
                await openSavedLocalLibrary()
                return
            }
            if let saved = try await credentials.load() {
                server = saved.server
                username = saved.username
                password = saved.password
                let client = try Navidrome(server: server, username: username, password: password)
                load(client)
                await task?.value
            }
        } catch {
            message = "保存したログイン情報を読み込めませんでした。アカウントを入力してください。"
        }
    }

    func connect(server: String, username: String, password: String) {
        pollingTask?.cancel()
        pendingUploads = [:]
        excludedTrackIDs = []
        checkedChecksums = [:]
        message = nil
        do {
            let client = try Navidrome(server: server, username: username, password: password)
            let login = LoginCredentials(server: client.server.absoluteString, username: username, password: password)
            load(client, saving: login)
        } catch { message = error.localizedDescription }
    }

    func reload() {
#if os(macOS)
        if local, let url = localFolder?.root { Task { await chooseFolder(url) }; return }
#endif
        if let client { load(client) }
    }

    func openLocal(_ catalog: LocalCatalog) throws {
        try localStore.save(catalog)
        try Data().write(to: localStore.root.appendingPathComponent("active"), options: .atomic)
        task?.cancel()
        pollingTask?.cancel()
#if os(iOS)
        downloadGeneration = UUID()
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks = [:]
        downloading = []
        downloadAccount = ""
#endif
        stop()
        current = nil
        queue = []
        client = nil
        local = true
        localCatalog = catalog
        tracks = catalog.entries.map(\.track)
        artworkURLs = Dictionary(uniqueKeysWithValues: catalog.entries.compactMap { entry in
            entry.track.coverArt.map { ($0, localStore.artworkURL(entry)) }
        })
        connected = true
        restoringSession = false
        refreshing = false
        message = nil
        navigate(.albums)
        refreshLocalFiles()
    }

    func refreshLocalFiles() {
        guard let localCatalog else { return }
#if os(iOS)
        localFiles = Dictionary(uniqueKeysWithValues: localCatalog.entries.filter { localStore.hasFile($0) }
            .map { ($0.track.id, localStore.fileURL($0)) })
        downloaded = Set(localFiles.keys)
#endif
    }

    var hasSavedLocalLibrary: Bool {
        FileManager.default.fileExists(atPath: localStore.root.appendingPathComponent("catalog.json").path)
    }

    func openSavedLocalLibrary() async {
        do {
#if os(macOS)
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
            let oldCatalog = try localStore.load()
            let bookmarkURL = localStore.root.appendingPathComponent("folder.bookmark")
            var previousFolder = localFolder?.root
            if previousFolder == nil, let data = try? Data(contentsOf: bookmarkURL) {
                var stale = false
                previousFolder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            let sameFolder = previousFolder?.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.resolvingSymlinksInPath().path
            let id = sameFolder ? oldCatalog?.id ?? UUID().uuidString : UUID().uuidString
            let folder = try await Task.detached { try await LocalFolder.scan(url, id: id) }.value
            try localStore.prepare()
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            try bookmark.write(to: localStore.root.appendingPathComponent("folder.bookmark"), options: .atomic)
            try openLocal(folder.catalog)
            if let scopedFolder { scopedFolder.stopAccessingSecurityScopedResource() }
            scopedFolder = scoped ? url : nil
            releaseScopeOnFailure = false
            localFolder = folder
            localFiles = folder.files
            if !folder.skipped.isEmpty { message = "読み込めなかった音源: " + folder.skipped.joined(separator: "、") }
            try await transfer.host(folder)
        } catch {
            if releaseScopeOnFailure { url.stopAccessingSecurityScopedResource() }
            message = error.localizedDescription
        }
    }

    func startPairing() async {
        guard let localFolder else { return }
        do { try await transfer.host(localFolder, newPairing: true) }
        catch { message = error.localizedDescription }
    }
#endif

    @discardableResult
    func pollForLibraryUpdates(uploads: [LibraryUpload]) -> Task<Void, Never>? {
        pollingTask?.cancel()
        guard connected, !uploads.isEmpty else { return nil }
        if pendingUploads.isEmpty {
            excludedTrackIDs = Set(tracks.map(\.id))
            checkedChecksums = [:]
        }
        for upload in uploads { pendingUploads[upload.filename] = upload }
        pollingTask = Task { [weak self] in
            for attempt in 0..<10 {
                guard let sleep = self?.pollingSleep else { return }
                do { try await sleep(.seconds(1 << attempt)) }
                catch { return }
                guard !Task.isCancelled, let self, self.connected else { return }
                if self.refreshing { await self.task?.value }
                guard !Task.isCancelled, self.connected else { return }
                self.reload()
                await self.task?.value
                guard !Task.isCancelled else { return }
                await self.resolvePendingUploads()
                guard !Task.isCancelled else { return }
                if self.pendingUploads.isEmpty { return }
            }
        }
        return pollingTask
    }

    private func resolvePendingUploads() async {
        guard let client else { return }
        for track in tracks where !excludedTrackIDs.contains(track.id) {
            guard !Task.isCancelled else { return }
            let candidates = pendingUploads.values.filter { $0.bytes == track.size }
            guard !candidates.isEmpty else { continue }
            do {
                let checksum: String
                if let cached = checkedChecksums[track.id] { checksum = cached }
                else {
                    checksum = try await client.checksum(track, session: session)
                    try Task.checkCancellation()
                    checkedChecksums[track.id] = checksum
                }
                if let upload = candidates.first(where: { $0.sha256 == checksum }) {
                    pendingUploads[upload.filename] = nil
                    excludedTrackIDs.insert(track.id)
                }
            } catch {
                if Task.isCancelled { return }
            }
        }
    }

    private func load(_ client: Navidrome, saving login: LoginCredentials? = nil) {
        task?.cancel()
        refreshing = true
        message = nil
        task = Task {
            do {
                let tracks = try await client.tracks(session: session)
                guard !Task.isCancelled else { return }
                self.client = client
                self.transfer.cancel()
#if os(macOS)
                self.transfer.stopHosting()
#endif
                self.local = false
                self.localFiles = [:]
                try? FileManager.default.removeItem(at: localStore.root.appendingPathComponent("active"))
                self.tracks = tracks
#if os(iOS)
                let account = client.server.absoluteString + "\u{1f}" + username
                if downloadAccount != account {
                    downloadGeneration = UUID()
                    downloadTasks.values.forEach { $0.cancel() }
                    downloadTasks = [:]
                    downloading = []
                }
                downloadAccount = account
                downloaded = Set(tracks.filter { offlineTracks.contains(account: account, id: $0.id, suffix: $0.suffix) }.map(\.id))
#endif
                artworkURLs = Dictionary(uniqueKeysWithValues: Set(tracks.compactMap(\.coverArt)).map {
                    ($0, client.url("getCoverArt", parameters: [
                        URLQueryItem(name: "id", value: $0), URLQueryItem(name: "size", value: "400")
                    ]))
                })
                connected = true
                password = ""
                if let login {
                    do { try await credentials.save(login) }
                    catch {
                        guard !Task.isCancelled else { return }
                        message = "ログインしましたが、Keychain に保存できませんでした。次回は再入力が必要です。"
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                message = (error as? ClientError)?.localizedDescription ?? "接続に失敗しました。ネットワークを確認して、もう一度お試しください。"
            }
            guard !Task.isCancelled else { return }
            refreshing = false
        }
    }

    func play(_ track: Track, in tracks: [Track]? = nil) {
        guard local || client != nil else { return }
#if os(iOS)
        guard activateAudio() else { return }
#endif
        if let tracks { queue = tracks }
        if !queue.contains(where: { $0.id == track.id }) { queue = [track] }
        stop()
        current = track
        duration = max(0, track.duration ?? 0)
        message = nil
        var url = local ? localFiles[track.id] : client?.url("stream", parameters: [
            URLQueryItem(name: "id", value: track.id),
            URLQueryItem(name: "format", value: "raw")
        ])
#if os(iOS)
        if offlineTracks.contains(account: downloadAccount, id: track.id, suffix: track.suffix) {
            url = offlineTracks.url(account: downloadAccount, id: track.id, suffix: track.suffix)
        }
#endif
        guard let url else {
            message = "この曲はまだ保存されていません。Macに接続して保存してください。"
            return
        }
        loading = true
        let player = makePlayer(url)
        guard let item = player.currentItem else { return }
        self.player = player
        observation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player === player else { return }
                playing = player.timeControlStatus == .playing
                loading = player.currentItem?.status != .failed && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item, item.status == .failed else { return }
                self.player?.pause()
                playing = false
                loading = false
                message = "曲を再生できませんでした。接続を確認して曲を選び直してください。"
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
                if time.seconds.isFinite { position = max(0, time.seconds) }
            }
        }
        finishObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                playing = false
                loading = false
                position = duration
                next()
            }
        }
        player.play()
    }

    func previous() {
        guard canGoPrevious, let index = currentIndex else { return }
        play(queue[index - 1])
    }

    func next() {
        guard canGoNext, let index = currentIndex else { return }
        play(queue[index + 1])
    }

    func seek(to seconds: Double) {
        guard let player, seconds.isFinite, duration > 0 else { return }
        let target = min(max(0, seconds), duration)
        let id = UUID()
        seeking = id
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player, seeking == id else { return }
                seeking = nil
            }
        }
    }

    func togglePlayback(in tracks: [Track]) {
        guard let first = tracks.first else { return }
        if let current, tracks.contains(where: { $0.id == current.id }),
           let player, player.currentItem?.status != .failed {
            togglePlayback()
        } else {
            play(first, in: tracks)
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.rate != 0 || loading { pause() }
        else {
#if os(iOS)
            guard activateAudio() else { return }
#endif
            if duration > 0 && position >= duration {
                seek(to: 0)
            }
            player.play()
        }
    }

    func pause() {
        player?.pause()
        playing = false
        loading = false
    }

    private func stop() {
        observation = nil
        itemObservation = nil
        durationObservation = nil
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }
        finishObserver = nil
        player?.pause()
        player = nil
        playing = false
        loading = false
        seeking = nil
        position = 0
        duration = 0
    }

    func disconnect() {
        let wasLocal = local
        if local {
            transfer.cancel()
#if os(macOS)
            transfer.stopHosting()
#endif
            local = false
            localFiles = [:]
            try? FileManager.default.removeItem(at: localStore.root.appendingPathComponent("active"))
        }
        pollingTask?.cancel()
        pendingUploads = [:]
        excludedTrackIDs = []
        checkedChecksums = [:]
        task?.cancel()
        stop()
#if os(iOS)
        downloadTasks.values.forEach { $0.cancel() }
        downloadTasks = [:]
        downloading = []
        downloaded = []
        downloadAccount = ""
        downloadGeneration = UUID()
#endif
        client = nil
        current = nil
        tracks = []
        queue = []
        artworkURLs = [:]
        password = ""
        connected = false
        search = ""
        navigate(.albums)
        message = nil
        if wasLocal { refreshing = false; return }
        refreshing = true
        task = Task {
            do { try await credentials.remove() }
            catch { message = "ログアウトしましたが、Keychain の保存情報を削除できませんでした。" }
            refreshing = false
        }
    }

#if os(iOS)
    func download(_ track: Track) {
        if local {
            guard transfer.connected else { message = "設定またはアルバム画面からMacに接続して保存してください。"; return }
            transfer.copy([track])
            return
        }
        guard let client, !downloading.contains(track.id), !downloaded.contains(track.id) else { return }
        let account = downloadAccount
        let generation = downloadGeneration
        downloading.insert(track.id)
        downloadTasks[track.id] = Task {
            defer {
                if downloadGeneration == generation {
                    downloading.remove(track.id)
                    downloadTasks[track.id] = nil
                }
            }
            do {
                let (temporary, response) = try await session.download(from: client.url("download", parameters: [URLQueryItem(name: "id", value: track.id)]))
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.mimeType?.hasPrefix("audio/") == true || response.mimeType == "application/octet-stream" else {
                    throw ClientError.response
                }
                try offlineTracks.save(temporary, account: account, id: track.id, suffix: track.suffix)
                if downloadGeneration == generation { downloaded.insert(track.id) }
            } catch {
                if !Task.isCancelled && downloadGeneration == generation {
                    message = "「\(track.title)」を保存できませんでした。接続と端末の空き容量を確認して、もう一度お試しください。"
                }
            }
        }
    }

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
