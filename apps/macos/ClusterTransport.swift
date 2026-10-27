import Foundation
import IrohLib
import Darwin

@MainActor
final class ClusterNetwork {
    func playlistExchange(_ request: PlaylistRequest? = nil) async throws -> PlaylistResponse? {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        var failure: Error = LocalMusicError.clusterUnavailable
        var successful = false
        for address in try await addresses(database: database) {
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database, playlists: true)
                defer { current.close() }
                let response: PlaylistResponse?
                if let request { response = try await current.playlistRequest(request) }
                else { response = nil }
                if let response, response.status == "rejected" { throw PlaylistImportError.rejected(response.reason ?? "取り込みを確認してください。") }
                try await current.reconcilePlaylists(database: database)
                successful = true
                if response != nil { return response }
            } catch {
                try Task.checkCancellation()
                failure = error
                if error is PlaylistImportError { throw error }
            }
        }
        if successful { return nil }
        throw failure
    }

    private let discovery = ClusterDiscovery()
    private let store: LocalMusicStore
    private let secrets: CredentialStore
    private var session: ClusterSession?
    private(set) var lastPath: String?

    init(store: LocalMusicStore, secrets: CredentialStore) {
        self.store = store; self.secrets = secrets
    }

    func stop() {
        session?.close(); session = nil
        discovery.stop()
    }

    func recoverDownloadedFile(_ entry: LocalEntry) async throws {
        try await Self.recoverDownloadedFile(entry, store: store)
    }

    @TransportActor
    private static func recoverDownloadedFile(_ entry: LocalEntry, store: LocalMusicStore) throws {
        let database = try store.database()
        guard let registration = try database.clusterRegistration() else { return }
        let member = try registration.membership.verify(registration.localGrant).member
        let jobs = try database.clusterJobs().filter { $0.sha256 == entry.sha256 && $0.destination == member && $0.state == .queued }
        guard !jobs.isEmpty else { return }
        let file = try FileHandle(forWritingTo: store.fileURL(entry))
        defer { try? file.close() }
        try file.synchronize()
        let descriptor = Darwin.open(store.root.path, O_RDONLY)
        guard descriptor >= 0 else { throw LocalMusicError.invalidData }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw LocalMusicError.invalidData }
        for job in jobs {
            try database.beginClusterJob(job.id)
            do { try database.finishClusterDownload(job.id, entry: entry, file: store.fileURL(entry)) }
            catch { try database.retryClusterJob(job.id); throw error }
        }
    }

    private func addresses(database: CatalogDatabase, diagnostic: PlaybackDiagnosticContext? = nil) async throws -> [IrohLib.EndpointAddr] {
        guard let registration = try await CatalogStorage.shared.perform({ try database.clusterRegistration() }) else { throw LocalMusicError.unauthorized }
        let own = try registration.membership.verify(registration.localGrant).member
        let hosts = Set(registration.membership.grants.filter {
            $0.host && $0.member != own && (try? registration.membership.verify($0.id)) != nil
        }.map(\.member))
        if let diagnostic {
            for grant in registration.membership.grants {
                let reason = !grant.host ? "not_host" : grant.member == own ? "self" :
                    (try? registration.membership.verify(grant.id)) == nil ? "invalid_grant" : "eligible"
                diagnostic.record("selection", "membership", fields: ["device_id": grant.member, "reason": reason, "device_name": "not_observable"])
            }
        }
        diagnostic?.record("selection", "eligible", fields: ["count": String(hosts.count)])
        discovery.start()
        if let configured = registration.relay {
            let relay = try ClusterInvitation.validatedRelay(configured)
            for _ in 0..<4 {
                try Task.checkCancellation()
                if discovery.endpoints.keys.contains(where: hosts.contains) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            return try hosts.sorted {
                let left = discovery.endpoints[$0] != nil; let right = discovery.endpoints[$1] != nil
                return left == right ? $0 < $1 : left
            }.map { host in
                IrohLib.EndpointAddr(id: try IrohLib.EndpointId.fromString(s: host), relayUrl: relay,
                    addresses: discovery.endpoints[host]?.directAddresses() ?? [])
            }
        }
        for _ in 0..<60 {
            try Task.checkCancellation()
            let found = discovery.endpoints.filter { hosts.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
            if !found.isEmpty {
                for host in hosts where !found.contains(where: { $0.id().description == host }) {
                    diagnostic?.record("selection", "excluded", fields: ["device_id": host, "reason": "no_discovered_endpoint"])
                }
                return found
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        diagnostic?.record("selection", "no_candidates", outcome: "failed", fields: ["count": "0", "reason": hosts.isEmpty ? "no_authorized_hosts" : "no_discovered_endpoint"])
        throw LocalMusicError.clusterUnavailable
    }

    func enroll(_ invitation: ClusterInvitation, name: String) async throws {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        let address = try await discovery.find(invitation.host)
        try await ClusterSession.enroll(invitation: invitation, address: address, secrets: secrets, database: database, name: name)
    }

    func refresh() async throws -> LocalCatalog {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        var successful = false
        var failure: Error = LocalMusicError.clusterUnavailable
        for address in try await addresses(database: database) {
            try Task.checkCancellation()
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
                session = current
                defer { current.close(); session = nil }
                try await current.reconcile(database: database)
                let missing = try await CatalogStorage.shared.perform { try database.clusterCatalog().organization?.tracks.filter { $0.imported.tagValues == nil } ?? [] }
                let records = try await CatalogStorage.shared.perform { try database.clusterChanges() }
                let live = try await CatalogStorage.shared.perform { Set(try database.clusterObjectStates().filter {
                    guard !$0.conflicted else { return false }
                    return try $0.selected(in: records)?.action.entry != nil
                }.map(\.object)) }
                for object in Set(missing.map(\.sha256)).intersection(live).sorted() {
                    try Task.checkCancellation()
                    try await current.recoverEvidence(object: object)
                }
                if !missing.isEmpty { try await current.reconcile(database: database) }
                lastPath = current.selectedPath
                successful = true
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        guard successful else { throw failure }
        let catalog = try await UploadedMusic.recoverClusterEvidence(try await CatalogStorage.shared.perform { try database.clusterCatalog() }, store: store)
        try await CatalogStorage.shared.perform { try files.save(catalog, clusterEdits: true) }
        return catalog
    }

    func download(object: String, cache: LocalMusicStore? = nil, diagnostic: PlaybackDiagnosticContext? = nil, progress: @escaping @MainActor (Double) -> Void) async throws {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        var failure: Error = LocalMusicError.clusterUnavailable
        let candidates: [IrohLib.EndpointAddr]
        do { candidates = try await addresses(database: database, diagnostic: diagnostic) }
        catch { diagnostic?.failure("selection", error); throw error }
        diagnostic?.record("selection", "candidates", fields: ["count": String(candidates.count), "reason": candidates.isEmpty ? "no_authorized_hosts" : "available"])
        for (ordinal, address) in candidates.enumerated() {
            let trace = diagnostic?.source(ordinal + 1, peer: address.id().description)
            var stage = "connection"
            try Task.checkCancellation()
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database, diagnostic: trace)
                session = current
                defer {
                    trace?.record("connection", "final_path", fields: ["path": current.selectedPath ?? "unknown"])
                    current.close(); session = nil
                }
                stage = "synchronization"
                trace?.record(stage, "start")
                try await current.reconcile(database: database)
                trace?.record(stage, "finished", outcome: "succeeded")
                stage = "resolution"
                trace?.record(stage, "local_catalog", fields: ["sha256": object, "evidence": "local_synchronized_catalog"])
                let peer = current.peer
                let entry = try await CatalogStorage.shared.perform { try database.clusterDownloadEntry(object: object, peer: peer) }
                trace?.record(stage, "authorized", outcome: "succeeded", fields: ["track_id": entry.track.id, "sha256": entry.sha256])
                stage = "transfer"
                try await current.download(entry, store: cache ?? store, database: database, cacheOnly: cache != nil, diagnostic: trace, progress: progress)
                lastPath = current.selectedPath
                if cache != nil { return }
                let catalog = try await UploadedMusic.recoverClusterEvidence(try await CatalogStorage.shared.perform { try database.clusterCatalog() }, store: store)
                try await CatalogStorage.shared.perform { try files.save(catalog, clusterEdits: true) }
                return
            } catch let error as IrohLib.IrohError {
                trace?.failure(stage, error)
                try Task.checkCancellation()
                failure = LocalMusicError.clusterUnavailable
            } catch {
                trace?.failure(stage, error)
                try Task.checkCancellation()
                failure = error
            }
        }
        throw failure
    }

    func importHost() async throws -> String {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        do {
            let available = try await addresses(database: database)
            for address in available {
                let peer = address.id().description
                if try await CatalogStorage.shared.perform({ try database.clusterCursor(peer) > 0 }) { return peer }
            }
            if let address = available.first { return address.id().description }
        } catch { try Task.checkCancellation() }
        guard let registration = try await CatalogStorage.shared.perform({ try database.clusterRegistration() }),
              let host = registration.membership.grants.filter({ $0.host && (try? registration.membership.verify($0.id)) != nil })
                .map(\.member).sorted().first else { throw LocalMusicError.disconnected }
        return host
    }

    func upload(entry: LocalEntry, organization: AlbumOrganization, parents: [String], restore: Bool = false, host: String, file: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> String {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        let candidates = try await addresses(database: database).sorted { ($0.id().description == host ? 0 : 1) < ($1.id().description == host ? 0 : 1) }
        var failure: Error = LocalMusicError.clusterUnavailable
        for address in candidates {
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
                session = current
                defer { current.close(); session = nil }
                try await current.upload(entry: entry, organization: organization, parents: parents, restore: restore, file: file, progress: progress)
                lastPath = current.selectedPath
                try await current.reconcile(database: database)
                try await CatalogStorage.shared.perform { try files.save(database.clusterCatalog()) }
                return current.peer
            } catch is IrohLib.IrohError {
                failure = LocalMusicError.clusterUnavailable
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        throw failure
    }

    func syncMetadata() async throws {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        let pending = try await CatalogStorage.shared.perform { try database.clusterMetadataEdits() }
        guard !pending.isEmpty else { return }
        var failure: Error = LocalMusicError.clusterUnavailable
        for address in try await addresses(database: database) {
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
                session = current
                defer { current.close(); session = nil }
                for edit in try await CatalogStorage.shared.perform({ try database.clusterMetadataEdits() }) {
                    do {
                        let revision = try await current.editMetadata(edit)
                        try await CatalogStorage.shared.perform { try database.finishClusterMetadataEdit(edit, revision: revision) }
                    } catch LocalMusicError.clusterNeedsAttention {
                        failure = LocalMusicError.clusterNeedsAttention
                    }
                }
                try await current.reconcile(database: database)
                lastPath = current.selectedPath
                if try await CatalogStorage.shared.perform({ try database.clusterMetadataEdits().isEmpty }) { return }
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        throw failure
    }

    func resolve(object: String, selected: String, parents: [String]) async throws -> LocalCatalog {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        guard let address = try await addresses(database: database).first else { throw LocalMusicError.disconnected }
        let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
        session = current
        defer { current.close(); session = nil }
        try await current.resolve(object: object, selected: selected, parents: parents)
        try await current.reconcile(database: database)
        lastPath = current.selectedPath
        let catalog = try await CatalogStorage.shared.perform { try database.clusterCatalog() }
        try await CatalogStorage.shared.perform { try files.save(catalog) }
        return catalog
    }

    func resolveAlbum(_ conflict: ClusterAlbumConflict, title: String) async throws -> LocalCatalog {
        let files = store
        let database = try await CatalogStorage.shared.perform { try files.database() }
        let states = try await CatalogStorage.shared.perform { try database.clusterObjectStates() }
        var heads: [String: String] = [:]
        for object in conflict.objects {
            guard let state = states.first(where: { $0.object == object }), state.heads.count == 1 else { throw LocalMusicError.clusterNeedsAttention }
            heads[object] = state.heads[0].id
        }
        guard let address = try await addresses(database: database).first else { throw LocalMusicError.clusterUnavailable }
        let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
        session = current
        defer { current.close(); session = nil }
        try await current.resolveAlbum(album: conflict.id, title: title, heads: heads)
        try await current.reconcile(database: database)
        lastPath = current.selectedPath
        let catalog = try await CatalogStorage.shared.perform { try database.clusterCatalog() }
        try await CatalogStorage.shared.perform { try files.save(catalog) }
        return catalog
    }
}

@TransportActor
final class ClusterSession {
    func playlistRequest(_ request: PlaylistRequest) async throws -> PlaylistResponse {
        let stream = try await connection.openBi()
        try await send(request, stream: stream)
        try await stream.send().finish()
        return try await receive(PlaylistResponse.self, stream: stream)
    }

    func reconcilePlaylists(database: CatalogDatabase) async throws {
        var after = try database.playlistCursor(peer)
        for _ in 0..<10000 {
            let page = try await playlistRequest(PlaylistRequest(operation: "page", after: after))
            guard page.status == "page", let next = page.next else { throw LocalMusicError.invalidData }
            guard let record = page.record else { return }
            guard next > after else { throw LocalMusicError.invalidData }
            try database.receivePlaylist(peer: peer, sequence: next, record: record)
            after = next
        }
        throw LocalMusicError.invalidData
    }

    private struct Hello: Codable { let capabilities: ClusterCapabilities; let proof: ClusterMembership }
    private struct EnrollmentRequest: Encodable { let version = 1; let secret: String }
    private struct EnrollmentResponse: Decodable { let status: String; let grant: String?; let proof: ClusterMembership? }
    private struct Request: Encodable {
        let operation: String
        var after: Int64? = nil
        var object: String? = nil
        var entry: LocalEntry? = nil
        var organization: AlbumOrganization? = nil
        var parents: [String]? = nil
        var selected: String? = nil
        var restore: Bool? = nil
        var album: String? = nil
        var title: String? = nil
        var heads: [String: String]? = nil
    }
    private struct Response: Decodable {
        struct Signature: Decodable { let id: String; let signature: String }
        let status: String
        let next: Int64?
        let change: Signature?
        let signingPayload: String?
        let entry: LocalEntry?
        let object: String?
        let revision: String?
        enum CodingKeys: String, CodingKey { case status, next, change, entry, object, revision; case signingPayload = "signing_payload" }
    }

    nonisolated private let endpoint: IrohLib.Endpoint
    nonisolated private let connection: IrohLib.Connection
    nonisolated let peer: String
    nonisolated var selectedPath: String? {
        guard let path = connection.paths().first(where: \.isSelected) else { return nil }
        return path.isIp ? "direct" : (path.isRelay ? "relay" : nil)
    }

    private init(endpoint: IrohLib.Endpoint, connection: IrohLib.Connection, peer: String) {
        self.endpoint = endpoint; self.connection = connection; self.peer = peer
    }

    nonisolated func close() {
        try? connection.close(errorCode: 0, reason: Data())
        Task { try? await endpoint.close() }
    }

    private static func open(address: IrohLib.EndpointAddr, alpn: String, secrets: CredentialStore) async throws -> ClusterSession {
        let relay = try address.relayUrl().map(ClusterInvitation.validatedRelay)
        let endpoint = try await IrohLib.Endpoint.bind(options: IrohLib.EndpointOptions(
            preset: IrohLib.presetMinimal(), secretKey: await PeerMusicConnection.identity(secrets: secrets),
            relayMode: try relay.map { try IrohLib.RelayMode.customFromUrls(urls: [$0]) } ?? .disabled()))
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            try? await endpoint.close()
        }
        defer { timeout.cancel() }
        do {
            let connection = try await endpoint.connect(addr: address, alpn: Data(alpn.utf8))
            guard connection.remoteId().description == address.id().description else { throw LocalMusicError.unauthorized }
            return ClusterSession(endpoint: endpoint, connection: connection, peer: connection.remoteId().description)
        } catch { try? await endpoint.close(); throw error }
    }

    private func send<T: Encodable>(_ message: T, stream: IrohLib.BiStream) async throws {
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(message)
        guard body.count <= 64 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        let length = UInt32(body.count)
        var packet = Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        packet.append(body)
        try await stream.send().writeAll(buf: packet)
    }

    private func receive<T: Decodable>(_ type: T.Type, stream: IrohLib.BiStream) async throws -> T {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            close()
        }
        defer { timeout.cancel() }
        let header = try await stream.recv().readExact(size: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 64 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        return try JSONDecoder().decode(type, from: await stream.recv().readExact(size: UInt32(count)))
    }

    static func enroll(invitation: ClusterInvitation, address: IrohLib.EndpointAddr, secrets: CredentialStore, database: CatalogDatabase, name: String) async throws {
        guard invitation.host == address.id().description, address.relayUrl() == nil else { throw LocalMusicError.unauthorized }
        let session = try await open(address: address, alpn: "syncstr/enrollment/1", secrets: secrets)
        defer { session.close() }
        let stream = try await session.connection.openBi()
        try await session.send(EnrollmentRequest(secret: invitation.secret), stream: stream)
        try await stream.send().finish()
        let response = try await session.receive(EnrollmentResponse.self, stream: stream)
        guard response.status == "enrolled", let grant = response.grant, let proof = response.proof else { throw LocalMusicError.unauthorized }
        try database.enrollCluster(invitation: invitation, grantID: grant, membership: proof,
            ownID: await PeerMusicConnection.publicID(secrets: secrets), name: name)
    }

    static func connect(address: IrohLib.EndpointAddr, secrets: CredentialStore, database: CatalogDatabase, diagnostic: PlaybackDiagnosticContext? = nil, playlists: Bool = false) async throws -> ClusterSession {
        guard let registration = try database.clusterRegistration() else { throw LocalMusicError.unauthorized }
        diagnostic?.record("connection", "start", fields: ["path": "unknown", "reason": "not_established", "reused": "false"])
        let session = try await open(address: address, alpn: playlists ? "syncstr/playlists/1" : "syncstr/cluster/3", secrets: secrets)
        diagnostic?.record("connection", "established", outcome: "succeeded", fields: ["peer_id": session.peer, "identity_match": "true", "path": session.selectedPath ?? "unknown"])
        diagnostic?.record("authentication", "start")
        do {
            let stream = try await session.connection.openBi()
            try await session.send(Hello(capabilities: ClusterCapabilities(version: 1, membership: true, deletions: true, conflicts: true), proof: registration.membership), stream: stream)
            try await stream.send().finish()
            let hello = try await session.receive(Hello.self, stream: stream)
            guard hello.capabilities.allowsAutomaticWriter else { throw LocalMusicError.incompatiblePeer }
            try database.authenticateClusterPeer(session.peer, membership: hello.proof)
            diagnostic?.record("authentication", "verified", outcome: "succeeded")
            return session
        } catch { diagnostic?.failure("authentication", error); session.close(); throw error }
    }

    func reconcile(database: CatalogDatabase) async throws {
        var after = try database.clusterCursor(peer)
        for _ in 0..<1024 {
            let stream = try await connection.openBi()
            try await send(Request(operation: "changes", after: after), stream: stream)
            try await stream.send().finish()
            let page = try await receive(Response.self, stream: stream)
            guard page.status == "page", let next = page.next else { throw LocalMusicError.invalidData }
            guard let change = page.change else { return }
            guard next > after, let payload = page.signingPayload else { throw LocalMusicError.invalidData }
            try database.receiveClusterPage(peer: peer, sequence: next, signed: ClusterSignedChange(id: change.id, signature: change.signature, payload: payload))
            after = next
        }
    }

    func recoverEvidence(object: String) async throws {
        let stream = try await connection.openBi()
        try await send(Request(operation: "evidence", object: object), stream: stream)
        try await stream.send().finish()
        let response = try await receive(Response.self, stream: stream)
        guard response.status == "unavailable" || (response.status == "stored" && response.object == object) else {
            throw LocalMusicError.invalidData
        }
    }

    func upload(entry: LocalEntry, organization: AlbumOrganization, parents: [String], restore: Bool = false, file: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard LocalMusicStore.valid(entry), let size = entry.track.size,
              try LocalMusicStore.digest(file: file) == entry.sha256 else { throw LocalMusicError.changedFile }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(240)) } catch { return }
            close()
        }
        defer { timeout.cancel() }
        let stream = try await connection.openBi()
        try await send(Request(operation: "upload", entry: entry, organization: organization, parents: parents, restore: restore), stream: stream)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var sent: UInt64 = 0
        while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty {
            try Task.checkCancellation()
            guard sent + UInt64(bytes.count) <= size else { throw LocalMusicError.changedFile }
            try await stream.send().writeAll(buf: bytes)
            sent += UInt64(bytes.count)
            await progress(Double(sent) / Double(size))
        }
        guard sent == size else { throw LocalMusicError.changedFile }
        try await stream.send().finish()
        let response = try await receive(Response.self, stream: stream)
        if response.status == "needs-attention" { throw LocalMusicError.clusterNeedsAttention }
        guard response.status == "stored", response.object == entry.sha256 else { throw LocalMusicError.invalidData }
    }

    func resolve(object: String, selected: String, parents: [String]) async throws {
        let stream = try await connection.openBi()
        try await send(Request(operation: "resolve", object: object, parents: parents, selected: selected), stream: stream)
        try await stream.send().finish()
        let response = try await receive(Response.self, stream: stream)
        guard response.status == "resolved", response.object == object else { throw LocalMusicError.invalidData }
    }

    func resolveAlbum(album: String, title: String, heads: [String: String]) async throws {
        let stream = try await connection.openBi()
        try await send(Request(operation: "album-title", album: album, title: title, heads: heads), stream: stream)
        try await stream.send().finish()
        let response = try await receive(Response.self, stream: stream)
        guard response.status == "resolved", response.object == album else { throw LocalMusicError.invalidData }
    }

    func editMetadata(_ edit: ClusterMetadataEdit) async throws -> String {
        let stream = try await connection.openBi()
        try await send(Request(operation: "metadata", entry: edit.entry, organization: edit.organization, parents: edit.parents), stream: stream)
        try await stream.send().finish()
        let response = try await receive(Response.self, stream: stream)
        if response.status == "needs-attention" { throw LocalMusicError.clusterNeedsAttention }
        guard response.status == "edited", response.object == edit.entry.sha256,
              let revision = response.revision, ClusterIdentity.isLowercaseHex256(revision) else { throw LocalMusicError.invalidData }
        return revision
    }

    func download(_ entry: LocalEntry, store: LocalMusicStore, database: CatalogDatabase, cacheOnly: Bool = false, diagnostic: PlaybackDiagnosticContext? = nil, progress: @escaping @MainActor (Double) -> Void) async throws {
        var stage = "resolution"
        var received: UInt64 = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        let download = PlaybackDownload(store: store)
        do {
            guard LocalMusicStore.valid(entry), let size = entry.track.size else { throw LocalMusicError.invalidData }
            diagnostic?.record("transfer", "expected", fields: ["expected_size": String(size), "sha256": entry.sha256])
            let current = try database.clusterDownloadEntry(object: entry.sha256, peer: peer)
            guard current.track.size == size, let registration = try database.clusterRegistration() else { throw LocalMusicError.invalidData }
            let member = try registration.membership.verify(registration.localGrant).member
            let pending = try database.clusterJobs().first { $0.sha256 == entry.sha256 && $0.source == peer && $0.destination == member && $0.state == .queued }
            let job = pending ?? ClusterTransferJob(id: UUID().uuidString, sha256: entry.sha256, source: peer, destination: member, state: .queued)
            if !cacheOnly {
                try database.enqueueClusterJob(job)
                try database.beginClusterJob(job.id)
            }
            defer { if !cacheOnly { try? database.retryClusterJob(job.id) } }
            stage = "save"
            try await download.prepare()
            diagnostic?.record("save", "temporary_created", outcome: "succeeded")
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(240)) } catch { return }
                close()
            }
            defer { timeout.cancel() }
            stage = "remote_resolution"
            let stream = try await connection.openBi()
            diagnostic?.record(stage, "request", fields: ["sha256": entry.sha256, "track_id": entry.track.id])
            try await send(Request(operation: "audio", object: entry.sha256), stream: stream)
            try await stream.send().finish()
            let response = try await receive(Response.self, stream: stream)
            diagnostic?.record(stage, "response", fields: ["protocol_status": ["audio", "unavailable", "denied", "error"].contains(response.status) ? response.status : "unrecognized",
                "sha_match": String(response.entry?.sha256 == entry.sha256), "size_match": String(response.entry?.track.size == size), "remote_internal_resolution": "not_observable"])
            guard response.status == "audio", let remote = response.entry,
                  remote.sha256 == entry.sha256, remote.track.size == size else { throw LocalMusicError.disconnected }
            stage = "save"
            await progress(0)
            while received < size {
                stage = "transfer"
                try Task.checkCancellation()
                let bytes = try await stream.recv().readExact(size: UInt32(min(65536, size - received)))
                received += UInt64(bytes.count)
                stage = "save"
                try await download.append(bytes)
                if ProcessInfo.processInfo.systemUptime - lastProgress >= 1 {
                    await progress(Double(received) / Double(size))
                    diagnostic?.record("transfer", "progress", fields: ["received_bytes": String(received)])
                    lastProgress = ProcessInfo.processInfo.systemUptime
                }
            }
            stage = "transfer"
            guard try await stream.recv().readToEnd(sizeLimit: 1).isEmpty else { throw LocalMusicError.invalidData }
            diagnostic?.record("transfer", "eof", outcome: "succeeded", fields: ["received_bytes": String(received)])
            stage = "save"
            try Task.checkCancellation()
            stage = "resolution"
            let selected = try database.clusterDownloadEntry(object: entry.sha256, peer: peer)
            stage = "import"
            _ = try await download.finish(selected, diagnostic: diagnostic, durable: true)
            stage = "save"
            if !cacheOnly { try database.finishClusterDownload(job.id, entry: selected, file: store.fileURL(selected)) }
            await progress(1)
            diagnostic?.record("save", "durable", outcome: "succeeded")
        } catch {
            await download.discard()
            diagnostic?.record(stage, "incomplete", outcome: "failed", fields: ["received_bytes": String(received)])
            diagnostic?.failure(stage, error)
            throw error
        }
    }
}
