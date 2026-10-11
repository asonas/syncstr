import Foundation
import Network
import Security
import SwiftUI

struct MusicMessage: Codable {
    var version = 4
    var kind: String
    var name: String? = nil
    var library: String? = nil
    var entry: LocalEntry? = nil
    var track: String? = nil
    var bytes: Data? = nil
    var organization: AlbumOrganization? = nil
    var clusterCapabilities: ClusterCapabilities? = nil
}

@MainActor
final class MusicConnection {
    let connection: NWConnection
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var startTimeout: Task<Void, Never>?

    init(_ connection: NWConnection) { self.connection = connection }

    static func parameters(code: String, identity: String) throws -> NWParameters {
        let compact = code.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        guard compact.count == 32, compact.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw LocalMusicError.invalidCode }
        var key = Data()
        var offset = compact.startIndex
        while offset < compact.endIndex {
            let end = compact.index(offset, offsetBy: 2)
            key.append(UInt8(compact[offset..<end], radix: 16)!)
            offset = end
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // RFC 5487 TLS_PSK_WITH_AES_128_GCM_SHA256 is absent from the Swift enum cases.
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0x00A8)!)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, keyData as dispatch_data_t, identityData as dispatch_data_t)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    static func newCode() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LocalMusicError.invalidData }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start() async throws {
        guard !started else { return }
        started = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                startWaiter = waiter
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready: self.finishStart(nil)
                        case .failed(let error): self.finishStart(error)
                        case .cancelled: self.finishStart(LocalMusicError.disconnected)
                        default: break
                        }
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
                startTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.close()
                }
                if Task.isCancelled { close() }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    private func finishStart(_ error: Error?) {
        guard let waiter = startWaiter else { return }
        startWaiter = nil
        startTimeout?.cancel()
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    func close() { connection.cancel() }

    func send(_ message: MusicMessage) async throws {
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(message)
        guard body.count <= 2 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        let count = UInt32(body.count)
        var packet = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        packet.append(body)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error { waiter.resume(throwing: error) } else { waiter.resume() }
                })
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    private func read(_ count: Int) async throws -> Data {
        var bytes = Data()
        while bytes.count < count {
            try Task.checkCancellation()
            let remaining = count - bytes.count
            let chunk: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiter in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, _, error in
                        if let data, !data.isEmpty { waiter.resume(returning: data) }
                        else { waiter.resume(throwing: error ?? LocalMusicError.disconnected) }
                    }
                }
            } onCancel: { [connection] in connection.cancel() }
            bytes.append(chunk)
        }
        return bytes
    }

    func receive() async throws -> MusicMessage {
        let timeout = Task { [connection] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            connection.cancel()
        }
        defer { timeout.cancel() }
        let header = try await read(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 2 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        let message = try JSONDecoder().decode(MusicMessage.self, from: await read(count))
        guard message.version == 4 else { throw LocalMusicError.incompatiblePeer }
        if message.kind == "denied" { throw LocalMusicError.unauthorized }
        if message.kind == "changed" { throw LocalMusicError.changedFile }
        return message
    }
}

struct NearbyMusicDevice: Identifiable {
    var id: String
    var name: String
    var endpoint: NWEndpoint
}

@MainActor
final class LocalTransfer: ObservableObject {
    private var hostedCatalog: LocalCatalog?

    func updateHostedCatalog(_ catalog: LocalCatalog) { hostedCatalog = catalog }
    static let service = "_syncstr-music._tcp"
    @Published var nearby: [NearbyMusicDevice] = []
    @Published var code = ""
    @Published var status: String?
    @Published var pendingName: String?
    @Published var pairedName: String?
    @Published var busy = false {
        didSet {
            if !busy && pendingOrganization {
                pendingOrganization = false
                Task { syncOrganization() }
            }
        }
    }
    private var pendingOrganization = false
    @Published var completed = 0
    @Published var total = 0
    @Published var progress = 0.0
    @Published var connected = false
    @Published private(set) var activeTrack: String?
    var onCatalog: ((LocalCatalog) throws -> Void)?
    var onSaved: (() -> Void)?
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var channels: [UUID: MusicConnection] = [:]
    private var client: (any MusicChannel)?
    let peerSecrets: CredentialStore
    private let peerPairing: CredentialStore
    @Published var peerID = ""
    @Published var peerName: String?
    @Published var peerAddressText = ""
    @Published private(set) var clusterRegistration: ClusterRegistration?
    @Published private(set) var clusterBatches: [ClusterImportBatch] = []
    @Published private(set) var clusterConflicts: [ClusterObjectState] = []
    @Published private(set) var clusterChanges: [ClusterChange] = []
    @Published private(set) var disputedMembers: [String] = []
    @Published private(set) var clusterAlbumConflicts: [ClusterAlbumConflict] = []
    @Published private(set) var automaticCellular = false
    private let clusterPath = NWPathMonitor()
    private var automaticAudioOperation = false
    private var clusterRetry: Task<Void, Never>?
    private lazy var clusterNetwork = ClusterNetwork(store: store, secrets: peerSecrets)
    private var recoveredClusterJobs = false
    var peerConnected: Bool { connected && client is PeerMusicConnection }
    private var operation: Task<Void, Never>?
    private var approval: CheckedContinuation<Bool, Never>?
    private var approvalTimeout: Task<Void, Never>?
    private var peerCredential: PairingCredentials?
    private var catalog: LocalCatalog?
    private var generation = UUID()
    private var hosting = UUID()
    let secrets: CredentialStore
    var store: LocalMusicStore
    private(set) var advertisedPort: NWEndpoint.Port?
    var pairingPayload: String? {
#if os(macOS)
        guard !code.isEmpty, let folder else { return nil }
        return "syncstr-pair:\(folder.catalog.id):\(code)"
#else
        return nil
#endif
    }
#if os(macOS)
    private var folder: LocalFolder?
#endif

    init(store: LocalMusicStore = LocalMusicStore(), secrets: CredentialStore = CredentialStore(
        service: "as.ason.syncstr.local-pair", label: "syncstr paired device"),
        peerSecrets: CredentialStore = CredentialStore(service: "as.ason.syncstr.p2p.identity"),
        peerPairing: CredentialStore = CredentialStore(service: "as.ason.syncstr.p2p.peer")) {
        self.store = store
        self.secrets = secrets
        self.peerSecrets = peerSecrets
        self.peerPairing = peerPairing
        clusterPath.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, self.clusterRegistration != nil else { return }
                let permitted = ClusterTransferPolicy.permitsAutomaticAudio(online: path.status == .satisfied,
                    cellular: path.usesInterfaceType(.cellular), optedIn: self.automaticCellular)
                if !permitted && self.automaticAudioOperation {
                    self.cancel()
                    self.status = "自動転送を一時停止しました。音源はこの端末に保持しています。"
                    return
                }
                guard !self.busy, permitted,
                      self.clusterBatches.contains(where: { $0.items.contains(where: { $0.state == .queued }) }) else { return }
                self.connectCluster()
            }
        }
        clusterPath.start(queue: .global(qos: .utility))
    }

    deinit { clusterPath.cancel() }

    func setAutomaticCellular(_ enabled: Bool) {
        do {
            try store.database().setClusterAutomaticCellular(enabled)
            automaticCellular = enabled
            scheduleClusterRetry()
        } catch { status = error.localizedDescription }
    }

    private var permitsAutomaticAudio: Bool {
        let path = clusterPath.currentPath
        return ClusterTransferPolicy.permitsAutomaticAudio(online: path.status == .satisfied,
            cellular: path.usesInterfaceType(.cellular), optedIn: automaticCellular)
    }

    func browse() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .waiting: self?.status = "端末を探せません。同じWi-Fiと設定のローカルネットワーク許可を確認してください。"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.nearby = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    let parts = name.components(separatedBy: " | ")
                    guard parts.count == 2, UUID(uuidString: parts[1]) != nil else { return nil }
                    return NearbyMusicDevice(id: "Syncstr-" + parts[1], name: parts[0], endpoint: result.endpoint)
                }.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
    }

    func stopBrowsing() { browser?.cancel(); browser = nil; nearby = [] }

    func restorePairing() async {
        do { pairedName = try await secrets.load()?.name }
        catch { status = "ペアリング情報を読み込めませんでした。もう一度お試しください。" }
    }

    func restorePeer() async {
        do {
            peerID = try await PeerMusicConnection.publicID(secrets: peerSecrets)
            let database = try store.database()
            try updateClusterState(database)
            automaticCellular = try database.clusterAutomaticCellular()
            if !recoveredClusterJobs {
                try database.recoverClusterJobs()
                recoveredClusterJobs = true
            }
            let saved = try await peerPairing.load()
            peerName = saved?.name
            peerAddressText = saved.flatMap { Data(base64Encoded: $0.key) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let saved {
                try store.rememberClusterPeer(ClusterKnownPeer(id: saved.libraryID, name: saved.name,
                    address: peerAddressText.isEmpty ? nil : peerAddressText))
            }
            scheduleClusterRetry()
        } catch { status = error.localizedDescription }
    }

    private func updateClusterState(_ database: CatalogDatabase) throws {
        clusterRegistration = try database.clusterRegistration()
        clusterBatches = try database.clusterBatches()
        clusterChanges = try database.clusterChanges()
        clusterConflicts = try database.clusterObjectStates().filter(\.conflicted)
        clusterAlbumConflicts = try database.clusterAlbumConflicts()
        disputedMembers = try clusterRegistration?.membership.revocationState().disputed.sorted() ?? []
    }

    private func scheduleClusterRetry() {
        clusterRetry?.cancel()
        guard clusterRegistration != nil, clusterBatches.contains(where: { $0.items.contains(where: { $0.state == .queued }) }) else { return }
        clusterRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self else { return }
            guard !self.busy, self.permitsAutomaticAudio else { self.scheduleClusterRetry(); return }
            self.connectCluster()
        }
    }

    func connectCluster(invitation: String? = nil, name: String = "ライブラリ") {
        cancel()
        let attempt = generation
        busy = true
        status = "ライブラリの保存先を探しています…"
        operation = Task {
            defer { if generation == attempt { busy = false; scheduleClusterRetry() } }
            do {
                if let invitation {
                    try await clusterNetwork.enroll(ClusterInvitation.parse(invitation), name: name)
                    clusterRegistration = try store.database().clusterRegistration()
                }
                let catalog = try await clusterNetwork.refresh()
                try Task.checkCancellation()
                guard generation == attempt else { return }
                try onCatalog?(catalog)
                self.catalog = catalog
                let database = try store.database()
                try updateClusterState(database)
                connected = true
                status = "ライブラリを更新しました。音源を選んでこの端末に保存できます。"
                for batch in clusterBatches where permitsAutomaticAudio && batch.items.contains(where: { $0.state == .queued }) {
                    try Task.checkCancellation()
                    try await sendClusterBatch(batch, database: database, attempt: attempt)
                }
            } catch {
                if generation == attempt {
                    try? updateClusterState(store.database())
                    status = error.localizedDescription
                }
            }
        }
    }

    func resolveCluster(_ conflict: ClusterObjectState, selected: String) {
        guard !busy else { return }
        let attempt = generation
        busy = true
        operation = Task {
            defer { if generation == attempt { busy = false } }
            do {
                let catalog = try await clusterNetwork.resolve(object: conflict.object, selected: selected, parents: conflict.heads.map(\.id))
                try Task.checkCancellation()
                guard generation == attempt else { return }
                try onCatalog?(catalog)
                self.catalog = catalog
                let database = try store.database()
                try updateClusterState(database)
                status = "選んだ内容を保存先に反映しました。"
            } catch {
                if generation == attempt { status = error.localizedDescription }
            }
        }
    }

    func resolveClusterAlbum(_ conflict: ClusterAlbumConflict, title: String) {
        guard !busy, conflict.titles.contains(title) else { return }
        let attempt = generation
        busy = true
        operation = Task {
            defer { if generation == attempt { busy = false; scheduleClusterRetry() } }
            do {
                let catalog = try await clusterNetwork.resolveAlbum(conflict, title: title)
                try Task.checkCancellation()
                guard generation == attempt else { return }
                try onCatalog?(catalog)
                self.catalog = catalog
                try updateClusterState(store.database())
                status = "選んだアルバム名を保存先に反映しました。"
            } catch { if generation == attempt { status = error.localizedDescription } }
        }
    }

    func importCluster(_ files: [URL]) {
        guard !busy, clusterRegistration != nil else { return }
        let attempt = generation
        busy = true; completed = 0; total = files.count; progress = 0
        status = "音源の情報を確認しています…"
        operation = Task {
            defer { if generation == attempt { busy = false; scheduleClusterRetry() } }
            do {
                let database = try store.database()
                var batch = ClusterImportBatch(id: UUID().uuidString, host: try await clusterNetwork.importHost(), items: [])
                var organization = try store.load()?.organization ?? AlbumOrganization()
                for original in files {
                    try Task.checkCancellation()
                    var item = ClusterImportBatch.Item(id: UUID().uuidString, name: original.lastPathComponent,
                        parents: [], state: .queued, createdCopy: false, localCopy: .pending)
                    do {
                        let scoped = original.startAccessingSecurityScopedResource()
                        defer { if scoped { original.stopAccessingSecurityScopedResource() } }
                        let snapshot = store.root.appendingPathComponent(".import-" + item.id).appendingPathExtension(original.pathExtension)
                        defer { try? FileManager.default.removeItem(at: snapshot) }
                        try FileManager.default.copyItem(at: original, to: snapshot)
                        let entry = try await UploadedMusic.entry(file: snapshot, original: original)
                        try Task.checkCancellation()
                        organization.importEntries([entry], sourceID: peerID)
                        try organization.validate()
                        item.entry = entry; item.organization = organization
                        if let state = try database.clusterObjectStates().first(where: { $0.object == entry.sha256 }) {
                            item.parents = state.heads.map(\.id)
                            if try !state.conflicted && !state.heads.isEmpty && state.selected(in: database.clusterChanges()) == nil {
                                item.state = .awaitingRestore
                                item.error = "ライブラリから削除された音源です。再追加には確認が必要です。"
                            }
                        }
                        item.createdCopy = !store.hasFile(entry)
                        try store.importFile(snapshot, entry: entry)
                    } catch {
                        try Task.checkCancellation()
                        item.state = .failed; item.error = error.localizedDescription
                    }
                    batch.items.append(item)
                    try database.saveClusterBatch(batch)
                    clusterBatches = try database.clusterBatches()
                }
                if permitsAutomaticAudio { try await sendClusterBatch(batch, database: database, attempt: attempt) }
                else { status = "音源をこの端末に保持しました。Wi-Fiに接続すると保存先へ追加します。" }
            } catch {
                if generation == attempt { status = error.localizedDescription }
            }
        }
    }

    func retryClusterBatch(_ id: String) {
        guard !busy, let batch = clusterBatches.first(where: { $0.id == id }) else { return }
        guard permitsAutomaticAudio else { status = "Wi-Fiへの接続後に再試行してください。音源は保持しています。"; return }
        let attempt = generation
        busy = true
        operation = Task {
            defer { if generation == attempt { busy = false; scheduleClusterRetry() } }
            do { try await sendClusterBatch(batch, database: store.database(), attempt: attempt) }
            catch { if generation == attempt { status = error.localizedDescription } }
        }
    }

    func confirmClusterRestore(batchID: String, itemID: String) {
        guard !busy, var batch = clusterBatches.first(where: { $0.id == batchID }),
              let index = batch.items.firstIndex(where: { $0.id == itemID && $0.state == .awaitingRestore }) else { return }
        do {
            batch.items[index].restore = true
            batch.items[index].state = .queued
            batch.items[index].error = nil
            let database = try store.database()
            try database.saveClusterBatch(batch)
            clusterBatches = try database.clusterBatches()
            retryClusterBatch(batchID)
            scheduleClusterRetry()
        } catch { status = error.localizedDescription }
    }

    private func sendClusterBatch(_ original: ClusterImportBatch, database: CatalogDatabase, attempt: UUID) async throws {
        automaticAudioOperation = true
        defer { if generation == attempt { automaticAudioOperation = false } }
        var batch = original
        completed = batch.items.filter { $0.state == .stored }.count
        total = batch.items.count
        for index in batch.items.indices where batch.items[index].state == .queued || batch.items[index].state == .failed {
            try Task.checkCancellation()
            guard permitsAutomaticAudio else { status = "自動転送を一時停止しました。音源は保持しています。"; return }
            guard let entry = batch.items[index].entry, let organization = batch.items[index].organization else { continue }
            status = "「\(batch.items[index].name)」を追加中…"
            do {
                try await clusterNetwork.upload(entry: entry, organization: organization, parents: batch.items[index].parents,
                    restore: batch.items[index].restore ?? false, host: batch.host, file: store.fileURL(entry)) { fraction in
                    self.progress = (Double(self.completed) + fraction) / Double(max(1, self.total))
                }
                try Task.checkCancellation()
                guard generation == attempt else { return }
                batch.items[index].state = .stored; batch.items[index].error = nil
                completed += 1
            } catch {
                try Task.checkCancellation()
                if case LocalMusicError.clusterUnavailable = error { batch.items[index].state = .queued }
                else { batch.items[index].state = .failed }
                batch.items[index].error = error.localizedDescription
            }
            try database.saveClusterBatch(batch)
            clusterBatches = try database.clusterBatches()
        }
        if let catalog = try store.load() { try onCatalog?(catalog); self.catalog = catalog }
        try updateClusterState(database)
        onSaved?()
        status = "\(total)曲中\(completed)曲を保存先に追加しました。"
    }

    func decideClusterCopies(batchID: String, keep: Bool) {
        guard !busy, var batch = clusterBatches.first(where: { $0.id == batchID }) else { return }
        do {
            for index in batch.items.indices where batch.items[index].state == .stored && batch.items[index].createdCopy && batch.items[index].localCopy == .pending {
                guard let entry = batch.items[index].entry else { throw LocalMusicError.invalidData }
                if !keep {
                    let needed = clusterBatches.flatMap(\.items).contains {
                        $0.entry?.sha256 == entry.sha256 && $0.state != .stored
                    }
                    guard !needed else { throw LocalMusicError.invalidData }
                    let file = store.fileURL(entry)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    try store.database().forgetReceived(entry)
                }
                batch.items[index].localCopy = keep ? .keep : .remove
                try store.database().saveClusterBatch(batch)
            }
            let database = try store.database()
            try database.saveClusterBatch(batch)
            clusterBatches = try database.clusterBatches()
            onSaved?()
        } catch { status = error.localizedDescription }
    }

    func removeClusterCopy(_ entry: LocalEntry) throws {
        guard !busy, clusterRegistration != nil, LocalMusicStore.valid(entry) else { throw LocalMusicError.invalidData }
        let database = try store.database()
        let batches = try database.clusterBatches()
        guard !batches.flatMap(\.items).contains(where: { $0.entry?.sha256 == entry.sha256 && $0.state != .stored }) else {
            throw LocalMusicError.clusterNeedsAttention
        }
        let file = store.fileURL(entry)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try database.forgetReceived(entry)
        for var batch in batches {
            for index in batch.items.indices where batch.items[index].entry?.sha256 == entry.sha256 && batch.items[index].state == .stored {
                batch.items[index].localCopy = .remove
            }
            try database.saveClusterBatch(batch)
        }
        clusterBatches = try database.clusterBatches()
        onSaved?()
    }

    func connectPeer(addressText: String, expected: String, name: String) {
        guard clusterRegistration == nil else { return }
        cancel()
        let attempt = generation
        busy = true
        status = "P2Pで接続中…"
        operation = Task {
            defer { if generation == attempt { busy = false } }
            do {
                guard addressText.utf8.count <= 16384 else { throw LocalMusicError.invalidData }
                let bytes = Data(addressText.utf8)
                let address = try JSONDecoder().decode(PeerAddress.self, from: bytes)
                let channel = try await PeerMusicConnection.connect(address: address, expected: expected, secrets: peerSecrets)
                guard generation == attempt, !Task.isCancelled else { channel.close(); return }
                client = channel
                try await channel.sendOrganized(MusicMessage(kind: "hello", name: name, clusterCapabilities: ClusterCapabilities(version: 1)), organization: try store.load()?.organization)
                let header = try await channel.receive()
                guard header.kind == "catalog", let id = header.library, UUID(uuidString: id) != nil else { throw LocalMusicError.invalidData }
                let incomingOrganization = try await channel.receiveOrganization(header)
                var entries: [LocalEntry] = []
                var metadataBytes = 0
                var ids = Set<String>()
                while true {
                    let message = try await channel.receive()
                    if message.kind == "ready" { break }
                    guard message.kind == "entry", let entry = message.entry, LocalMusicStore.valid(entry),
                          ids.insert(entry.track.id).inserted else { throw LocalMusicError.invalidData }
                    metadataBytes += try JSONEncoder().encode(entry).count
                    guard entries.count < 100000, metadataBytes <= 256 * 1024 * 1024 else { throw LocalMusicError.invalidData }
                    entries.append(entry)
                }
                guard generation == attempt, !Task.isCancelled else { channel.close(); return }
                if let previous = try store.load(), previous.id == id {
                    let saved = previous.entries.filter { store.hasFile($0) }
                    entries += saved.filter { !ids.contains($0.track.id) }
                }
                let catalog = try mergedCatalog(id: id, name: header.name ?? name, entries: entries, incoming: incomingOrganization)
                if let onCatalog { try onCatalog(catalog) } else { try store.save(catalog) }
                try await peerPairing.save(PairingCredentials(libraryID: expected, name: name, key: bytes.base64EncodedString()))
                try store.rememberClusterPeer(ClusterKnownPeer(id: expected, name: name, address: addressText))
                guard generation == attempt else { return }
                self.catalog = catalog
                peerName = name
                peerAddressText = addressText
                connected = true
                status = "P2Pで接続しました。アルバムを選んで保存できます。"
            } catch {
                if generation == attempt { client?.close(); client = nil; connected = false; status = error.localizedDescription }
            }
        }
    }

    func reconnectPeer() async {
        do {
            guard let saved = try await peerPairing.load(), let bytes = Data(base64Encoded: saved.key),
                  let address = String(data: bytes, encoding: .utf8) else { throw LocalMusicError.invalidData }
            connectPeer(addressText: address, expected: saved.libraryID, name: saved.name)
        } catch { status = error.localizedDescription }
    }

    func forgetPeer() async {
        cancel()
        do {
            if let saved = try await peerPairing.load() { try store.forgetClusterPeer(saved.libraryID) }
            try await peerPairing.remove()
            peerName = nil; peerAddressText = ""; status = "P2Pの接続先を削除しました。保存済みの音楽は残ります。"
        }
        catch { status = error.localizedDescription }
    }

    func uploadPeer(files: [URL]) {
        if clusterRegistration != nil { importCluster(files); return }
        guard let client = client as? PeerMusicConnection, connected, !busy else { return }
        if client.isClosed {
            do {
                let address = try PeerAddress.parse(peerAddressText)
                connectPeer(addressText: peerAddressText, expected: address.id, name: peerName ?? "")
                let attempt = generation
                let connection = operation
                Task {
                    await connection?.value
                    guard generation == attempt, connected, !busy else { return }
                    uploadPeer(files: files)
                }
            } catch { status = error.localizedDescription }
            return
        }
        let attempt = generation
        busy = true
        total = files.count
        completed = 0
        progress = 0
        operation = Task {
            defer { if generation == attempt { busy = false } }
            do {
                let sourceID = UserDefaults.standard.string(forKey: "musicImportSourceID") ?? UUID().uuidString
                UserDefaults.standard.set(sourceID, forKey: "musicImportSourceID")
                let prepared = try await UploadedMusic.prepare(files, organization: try store.load()?.organization ?? AlbumOrganization(), sourceID: sourceID)
                for (url, entry) in zip(files, prepared.entries) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try await Task.detached {
                        let source = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard source.isRegularFile == true, let sourceSize = source.fileSize, sourceSize > 0,
                              UInt64(sourceSize) <= 20 * 1024 * 1024 * 1024,
                              ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac"].contains(url.pathExtension.lowercased()) else {
                            throw LocalMusicError.invalidData
                        }
                        try FileManager.default.copyItem(at: url, to: temporary)
                        guard try LocalMusicStore.digest(file: temporary) == entry.sha256 else { throw LocalMusicError.changedFile }
                    }.value
                    guard LocalMusicStore.valid(entry) else { throw LocalMusicError.invalidData }
                    try Task.checkCancellation()
                    guard generation == attempt else { return }
                    status = "「\(entry.track.title)」を送信中…"
                    try await client.sendOrganized(MusicMessage(kind: "put", entry: entry), organization: prepared.organization)
                    guard try await client.receive().kind == "accept" else { throw LocalMusicError.invalidData }
                    let handle = try FileHandle(forReadingFrom: temporary)
                    defer { try? handle.close() }
                    var sent = 0
                    while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                        try await client.send(MusicMessage(kind: "data", bytes: bytes))
                        sent += bytes.count
                        progress = (Double(completed) + Double(sent) / Double(entry.track.size!)) / Double(max(1, total))
                    }
                    try await client.send(MusicMessage(kind: "end"))
                    let response = try await client.receive()
                    guard response.kind == "saved", let saved = response.entry, LocalMusicStore.valid(saved),
                          saved.sha256 == entry.sha256, saved.track.size == entry.track.size else { throw LocalMusicError.invalidData }
                    completed += 1
                }
                progress = 1
                status = "\(completed)曲を接続先に追加しました。ライブラリを更新中…"
                await reconnectPeer()
            } catch {
                if generation == attempt { client.close(); self.client = nil; connected = false; status = error.localizedDescription }
            }
        }
    }

    var onOrganization: ((AlbumOrganization) -> Void)?

    private func mergedCatalog(id: String, name: String, entries: [LocalEntry], incoming: AlbumOrganization?) throws -> LocalCatalog {
        guard let incoming else { throw LocalMusicError.incompatiblePeer }
        var catalog = LocalCatalog(id: id, name: name, entries: entries,
            organization: try store.load()?.organization)
        var organization = catalog.organization ?? AlbumOrganization()
        try organization.merge(incoming)
        catalog.organization = organization
        catalog.organize()
        return catalog
    }

    func syncOrganization() {
        guard let client, connected else { return }
        guard !busy else { pendingOrganization = true; return }
        busy = true
        let attempt = generation
        operation = Task {
            defer { if generation == attempt { busy = false } }
            do {
                try await client.sendOrganized(MusicMessage(kind: "organize"), organization: try store.load()?.organization)
                let response = try await client.receive()
                guard response.kind == "organized", let incoming = try await client.receiveOrganization(response) else { throw LocalMusicError.invalidData }
                var organization = try store.load()?.organization ?? AlbumOrganization()
                try organization.merge(incoming)
                guard generation == attempt else { return }
                onOrganization?(organization)
            } catch {
                guard generation == attempt else { return }
                client.close()
                connected = false
                status = "変更は端末に保存しました。再接続すると同期します。"
            }
        }
    }

    func cancel() {
        clusterRetry?.cancel(); clusterRetry = nil
        automaticAudioOperation = false
        generation = UUID()
        operation?.cancel()
        operation = nil
        client?.close()
        client = nil
        clusterNetwork.stop()
        connected = false
        busy = false
        activeTrack = nil
        approve(false)
    }

    func approve(_ allow: Bool) {
        let waiter = approval
        approval = nil
        pendingName = nil
        approvalTimeout?.cancel()
        waiter?.resume(returning: allow)
    }

    func forget() async {
        cancel()
        stopHosting()
        do {
            try await secrets.remove()
            peerCredential = nil
            pairedName = nil
            code = ""
            status = "ペアリングを解除しました。保存済みの音楽は残ります。"
        } catch { status = "ペアリング情報を削除できませんでした。もう一度お試しください。" }
    }

    func stopHosting() {
        hosting = UUID()
        approve(false)
        listener?.cancel()
        listener = nil
        channels.values.forEach { $0.close() }
        channels = [:]
        advertisedPort = nil
    }

#if os(macOS)
    func host(_ folder: LocalFolder, newPairing: Bool = false) async throws {
        if newPairing { await forget() }
        stopHosting()
        let epoch = hosting
        self.folder = folder
        hostedCatalog = folder.catalog
        peerCredential = try await secrets.load()
        guard hosting == epoch else { return }
        if let credential = peerCredential, credential.libraryID != folder.catalog.id {
            try await secrets.remove()
            peerCredential = nil
        }
        pairedName = peerCredential?.name
        let secret = try peerCredential?.key ?? MusicConnection.newCode()
        code = peerCredential == nil ? secret : ""
        let listener = try NWListener(using: MusicConnection.parameters(code: secret, identity: folder.catalog.id))
        self.listener = listener
        var deviceName = (Host.current().localizedName ?? "Mac").replacingOccurrences(of: " | ", with: " ")
        while deviceName.utf8.count > 20 { deviceName.removeLast() }
        listener.service = NWListener.Service(name: deviceName + " | " + folder.catalog.id, type: Self.service)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready: self.advertisedPort = listener?.port; self.status = "iPhoneでSyncstrを開いて接続してください。"
                case .failed, .waiting: self.status = "共有を開始できません。ローカルネットワークの許可を確認してやり直してください。"
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.channels.count < 2 else { connection.cancel(); return }
                let id = UUID()
                let channel = MusicConnection(connection)
                self.channels[id] = channel
                defer { channel.close(); self.channels[id] = nil }
                do { try await self.serve(channel, secret: secret, folder: folder, epoch: epoch) }
                catch { self.status = error.localizedDescription }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    private func serve(_ channel: MusicConnection, secret: String, folder: LocalFolder, epoch: UUID) async throws {
        try await channel.start()
        let hello = try await channel.receive()
        guard hosting == epoch else { throw LocalMusicError.unauthorized }
        if hello.kind == "cluster-hello" {
            try await channel.send(MusicMessage(kind: "upgrade-required", clusterCapabilities: ClusterCapabilities(version: 1)))
            return
        }
        guard hello.kind == "hello", let name = hello.name, !name.isEmpty, name.utf8.count <= 128 else { throw LocalMusicError.invalidData }
        if peerCredential == nil {
            guard approval == nil else { throw LocalMusicError.unauthorized }
            pendingName = name
            let accepted = await withCheckedContinuation { waiter in
                approval = waiter
                approvalTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    self?.approve(false)
                }
            }
            guard accepted, hosting == epoch else { try await channel.send(MusicMessage(kind: "denied")); return }
            let credential = PairingCredentials(libraryID: folder.catalog.id, name: name, key: secret)
            try await secrets.save(credential)
            guard hosting == epoch else { throw LocalMusicError.unauthorized }
            peerCredential = credential
            pairedName = name
            code = ""
        }
        var catalog = hostedCatalog ?? folder.catalog
        if let incoming = try await channel.receiveOrganization(hello) {
            var organization = catalog.organization ?? AlbumOrganization()
            try organization.merge(incoming)
            catalog.organization = organization
            try store.save(catalog)
            hostedCatalog = catalog
            onOrganization?(organization)
        }
        try await channel.sendOrganized(MusicMessage(kind: "catalog", name: catalog.name, library: catalog.id, clusterCapabilities: ClusterCapabilities(version: 1)), organization: catalog.organization)
        for entry in catalog.entries { try await channel.send(MusicMessage(kind: "entry", entry: entry)) }
        try await channel.send(MusicMessage(kind: "ready"))
        while true {
            let request = try await channel.receive()
            if request.kind == "organize" {
                guard let incoming = try await channel.receiveOrganization(request) else { throw LocalMusicError.invalidData }
                var catalog = hostedCatalog ?? folder.catalog
                var organization = catalog.organization ?? AlbumOrganization()
                try organization.merge(incoming)
                catalog.organization = organization
                try store.save(catalog)
                hostedCatalog = catalog
                onOrganization?(organization)
                try await channel.sendOrganized(MusicMessage(kind: "organized"), organization: organization)
                continue
            }
            guard request.kind == "get", let id = request.track,
                  let entry = (hostedCatalog ?? folder.catalog).entries.first(where: { $0.track.id == id }),
                  let url = folder.files[id],
                  url.resolvingSymlinksInPath().path.hasPrefix(folder.root.path + "/") else {
                throw LocalMusicError.unauthorized
            }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let matches = try await Task.detached {
                try FileManager.default.copyItem(at: url, to: temporary)
                return try LocalMusicStore.digest(file: temporary) == entry.sha256
            }.value
            guard hosting == epoch else { throw LocalMusicError.unauthorized }
            guard matches else {
                try await channel.send(MusicMessage(kind: "changed")); continue
            }
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            while let bytes = try handle.read(upToCount: 65536), !bytes.isEmpty {
                try await channel.send(MusicMessage(kind: "data", bytes: bytes))
            }
            try await channel.send(MusicMessage(kind: "end", track: id))
        }
    }
#endif

    func connect(_ device: NearbyMusicDevice, code: String, name: String) {
        guard clusterRegistration == nil else { return }
        cancel()
        let attempt = generation
        busy = true
        status = "Macに接続中…"
        operation = Task {
            defer { if generation == attempt { busy = false } }
            do {
                let saved = try await secrets.load()
                let identity = String(device.id.dropFirst("Syncstr-".count))
                guard UUID(uuidString: identity) != nil else { throw LocalMusicError.invalidData }
                let secret = code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && saved?.libraryID == identity ? saved!.key : code
                let channel = MusicConnection(NWConnection(to: device.endpoint,
                    using: try MusicConnection.parameters(code: secret, identity: identity)))
                client = channel
                try await channel.start()
                try await channel.sendOrganized(MusicMessage(kind: "hello", name: name, clusterCapabilities: ClusterCapabilities(version: 1)), organization: try store.load()?.organization)
                status = "Macでこの端末とのペアリングを承認してください。"
                let header = try await channel.receive()
                guard header.kind == "catalog", header.library == identity else { throw LocalMusicError.invalidData }
                let incomingOrganization = try await channel.receiveOrganization(header)
                var entries: [LocalEntry] = []
                var metadataBytes = 0
                while true {
                    let message = try await channel.receive()
                    if message.kind == "ready" { break }
                    guard message.kind == "entry", let entry = message.entry, LocalMusicStore.valid(entry) else { throw LocalMusicError.invalidData }
                    metadataBytes += try JSONEncoder().encode(entry).count
                    guard entries.count < 100000, metadataBytes <= 256 * 1024 * 1024 else { throw LocalMusicError.invalidData }
                    entries.append(entry)
                }
                try Task.checkCancellation()
                guard generation == attempt else { return }
                if let previous = try store.load(), previous.id == identity {
                    let savedEntries = previous.entries.filter { store.hasFile($0) }
                    let incomingIDs = Set(entries.map { $0.track.id })
                    entries += savedEntries.filter { !incomingIDs.contains($0.track.id) }
                }
                let catalog = try mergedCatalog(id: identity, name: header.name ?? "Mac", entries: entries, incoming: incomingOrganization)
                if let onCatalog { try onCatalog(catalog) }
                else { try store.save(catalog) }
                try await secrets.save(PairingCredentials(libraryID: identity, name: device.name, key: secret))
                guard generation == attempt else { return }
                self.catalog = catalog
                pairedName = device.name
                connected = true
                status = "アルバムを選んで保存できます。転送中は両方のアプリを開いてください。"
            } catch {
                if generation == attempt { client?.close(); client = nil; status = error.localizedDescription; connected = false }
            }
        }
    }

    func copy(_ tracks: [Track]) {
        if clusterRegistration != nil { copyCluster(tracks); return }
        guard let client, let catalog, connected, !busy else { return }
        let entries = tracks.compactMap { track in catalog.entries.first { $0.track.id == track.id } }
        let attempt = generation
        busy = true
        completed = 0
        total = entries.count
        progress = 0
        operation = Task {
            defer { if generation == attempt { busy = false; activeTrack = nil } }
            do {
                try store.prepare()
                for entry in entries {
                    try Task.checkCancellation()
                    activeTrack = entry.track.id
                    let files = store
                    let alreadySaved = try await Task.detached {
                        try files.hasFile(entry) && LocalMusicStore.digest(file: files.fileURL(entry)) == entry.sha256
                    }.value
                    try Task.checkCancellation()
                    if alreadySaved {
                        completed += 1
                        continue
                    }
                    status = "「\(entry.track.title)」を保存中…"
                    let temporary = store.root.appendingPathComponent("partial-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                    let handle = try FileHandle(forWritingTo: temporary)
                    defer { try? handle.close() }
                    try await client.send(MusicMessage(kind: "get", track: entry.track.id))
                    var received: UInt64 = 0
                    while true {
                        let message = try await client.receive()
                        if message.kind == "end", message.track == entry.track.id { break }
                        guard message.kind == "data", let bytes = message.bytes, !bytes.isEmpty, bytes.count <= 65536,
                              received + UInt64(bytes.count) <= entry.track.size! else { throw LocalMusicError.invalidData }
                        try handle.write(contentsOf: bytes)
                        received += UInt64(bytes.count)
                        progress = (Double(completed) + Double(received) / Double(entry.track.size!)) / Double(max(1, total))
                    }
                    try handle.close()
                    try Task.checkCancellation()
                    guard generation == attempt else { return }
                    try await Task.detached { try files.importFile(temporary, entry: entry) }.value
                    guard generation == attempt else { return }
                    completed += 1
                    onSaved?()
                }
                progress = 1
                status = "\(completed)曲を保存しました。Macを閉じても聴けます。"
            } catch {
                if generation == attempt { client.close(); self.client = nil; connected = false; status = error.localizedDescription }
            }
        }
    }

    private func copyCluster(_ tracks: [Track]) {
        guard !busy else { return }
        let attempt = generation
        busy = true; completed = 0; total = tracks.count; progress = 0
        operation = Task {
            defer { if generation == attempt { busy = false; activeTrack = nil } }
            do {
                let saved = try store.load()
                for track in tracks {
                    try Task.checkCancellation()
                    guard let entry = saved?.entries.first(where: { $0.track.id == track.id }) else { throw LocalMusicError.invalidData }
                    let files = store
                    if try await Task.detached(operation: {
                        try files.hasFile(entry) && LocalMusicStore.digest(file: files.fileURL(entry)) == entry.sha256
                    }).value {
                        try clusterNetwork.recoverDownloadedFile(entry)
                        completed += 1
                        continue
                    }
                    activeTrack = track.id
                    status = "「\(track.title)」を保存中…"
                    try await clusterNetwork.download(object: entry.sha256) { fraction in
                        self.progress = (Double(self.completed) + fraction) / Double(max(1, self.total))
                    }
                    try Task.checkCancellation()
                    guard generation == attempt else { return }
                    completed += 1
                    onSaved?()
                }
                progress = 1
                status = "\(completed)曲を保存しました。オフラインでも聴けます。"
            } catch {
                if generation == attempt { status = error.localizedDescription }
            }
        }
    }

}
