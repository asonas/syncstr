import Foundation
import Network
import Security
import SwiftUI

struct MusicMessage: Codable {
    var version = 1
    var kind: String
    var name: String? = nil
    var library: String? = nil
    var entry: LocalEntry? = nil
    var track: String? = nil
    var bytes: Data? = nil
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
        guard message.version == 1 else { throw LocalMusicError.invalidData }
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
    static let service = "_syncstr-music._tcp"
    @Published var nearby: [NearbyMusicDevice] = []
    @Published var code = ""
    @Published var status: String?
    @Published var pendingName: String?
    @Published var pairedName: String?
    @Published var busy = false
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
            peerName = try await peerPairing.load()?.name
        } catch { status = error.localizedDescription }
    }

    func connectPeer(addressText: String, expected: String, name: String) {
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
                try await channel.send(MusicMessage(kind: "hello", name: name))
                let header = try await channel.receive()
                guard header.kind == "catalog", let id = header.library, UUID(uuidString: id) != nil else { throw LocalMusicError.invalidData }
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
                let catalog = LocalCatalog(id: id, name: header.name ?? name, entries: entries)
                if let onCatalog { try onCatalog(catalog) } else { try store.save(catalog) }
                try await peerPairing.save(PairingCredentials(libraryID: expected, name: name, key: bytes.base64EncodedString()))
                guard generation == attempt else { return }
                self.catalog = catalog
                peerName = name
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
        do { try await peerPairing.remove(); peerName = nil; status = "P2Pの接続先を削除しました。保存済みの音楽は残ります。" }
        catch { status = error.localizedDescription }
    }

    func uploadPeer(files: [URL]) {
        guard let client = client as? PeerMusicConnection, connected, !busy else { return }
        let attempt = generation
        busy = true
        total = files.count
        completed = 0
        progress = 0
        operation = Task {
            defer { if generation == attempt { busy = false } }
            do {
                for url in files {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let entry = try await Task.detached {
                        let source = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard source.isRegularFile == true, let sourceSize = source.fileSize, sourceSize > 0,
                              UInt64(sourceSize) <= 20 * 1024 * 1024 * 1024,
                              ["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac"].contains(url.pathExtension.lowercased()) else {
                            throw LocalMusicError.invalidData
                        }
                        try FileManager.default.copyItem(at: url, to: temporary)
                        return try await UploadedMusic.entry(file: temporary, original: url)
                    }.value
                    guard LocalMusicStore.valid(entry) else { throw LocalMusicError.invalidData }
                    try Task.checkCancellation()
                    guard generation == attempt else { return }
                    status = "「\(entry.track.title)」を送信中…"
                    try await client.send(MusicMessage(kind: "put", entry: entry))
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
                status = "\(completed)曲を接続先に追加しました。ライブラリは再接続すると更新されます。"
            } catch {
                if generation == attempt { client.close(); self.client = nil; connected = false; status = error.localizedDescription }
            }
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        client?.close()
        client = nil
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
        try await channel.send(MusicMessage(kind: "catalog", name: folder.catalog.name, library: folder.catalog.id))
        for entry in folder.catalog.entries { try await channel.send(MusicMessage(kind: "entry", entry: entry)) }
        try await channel.send(MusicMessage(kind: "ready"))
        while true {
            let request = try await channel.receive()
            guard request.kind == "get", let id = request.track,
                  let entry = folder.catalog.entries.first(where: { $0.track.id == id }),
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
                try await channel.send(MusicMessage(kind: "hello", name: name))
                status = "Macでこの端末とのペアリングを承認してください。"
                let header = try await channel.receive()
                guard header.kind == "catalog", header.library == identity else { throw LocalMusicError.invalidData }
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
                    let savedByID = Dictionary(uniqueKeysWithValues: savedEntries.map { ($0.track.id, $0) })
                    let incomingIDs = Set(entries.map { $0.track.id })
                    entries = entries.map { savedByID[$0.track.id] ?? $0 }
                    entries += savedEntries.filter { !incomingIDs.contains($0.track.id) }
                }
                let catalog = LocalCatalog(id: identity, name: header.name ?? "Mac", entries: entries)
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

}
