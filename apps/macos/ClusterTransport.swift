import Foundation
import IrohLib
import Darwin

@MainActor
final class ClusterNetwork {
    private let discovery = ClusterDiscovery()
    private let store: LocalMusicStore
    private let secrets: CredentialStore
    private var session: ClusterSession?

    init(store: LocalMusicStore, secrets: CredentialStore) {
        self.store = store; self.secrets = secrets
    }

    func stop() {
        session?.close(); session = nil
        discovery.stop()
    }

    func recoverDownloadedFile(_ entry: LocalEntry) throws {
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

    private func addresses(database: CatalogDatabase) async throws -> [IrohLib.EndpointAddr] {
        guard let registration = try database.clusterRegistration() else { throw LocalMusicError.unauthorized }
        let own = try registration.membership.verify(registration.localGrant).member
        let hosts = Set(registration.membership.grants.filter {
            $0.host && $0.member != own && (try? registration.membership.verify($0.id)) != nil
        }.map(\.member))
        discovery.start()
        for _ in 0..<60 {
            try Task.checkCancellation()
            let found = discovery.endpoints.filter { hosts.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
            if !found.isEmpty { return found }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LocalMusicError.clusterUnavailable
    }

    func enroll(_ invitation: ClusterInvitation, name: String) async throws {
        let database = try store.database()
        let address = try await discovery.find(invitation.host)
        try await ClusterSession.enroll(invitation: invitation, address: address, secrets: secrets, database: database, name: name)
    }

    func refresh() async throws -> LocalCatalog {
        let database = try store.database()
        var successful = false
        var failure: Error = LocalMusicError.clusterUnavailable
        for address in try await addresses(database: database) {
            try Task.checkCancellation()
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
                session = current
                defer { current.close(); session = nil }
                try await current.reconcile(database: database)
                successful = true
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        guard successful else { throw failure }
        let catalog = try database.clusterCatalog()
        try store.save(catalog)
        return catalog
    }

    func download(object: String, progress: @escaping (Double) -> Void) async throws {
        let database = try store.database()
        var failure: Error = LocalMusicError.clusterUnavailable
        for address in try await addresses(database: database) {
            try Task.checkCancellation()
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
                session = current
                defer { current.close(); session = nil }
                try await current.reconcile(database: database)
                let entry = try database.clusterDownloadEntry(object: object, peer: current.peer)
                try await current.download(entry, store: store, database: database, progress: progress)
                try store.save(database.clusterCatalog())
                return
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        throw failure
    }

    func importHost() async throws -> String {
        let database = try store.database()
        do {
            let available = try await addresses(database: database)
            for address in available where try database.clusterCursor(address.id().description) > 0 {
                return address.id().description
            }
            if let address = available.first { return address.id().description }
        } catch { try Task.checkCancellation() }
        guard let registration = try database.clusterRegistration(),
              let host = registration.membership.grants.filter({ $0.host && (try? registration.membership.verify($0.id)) != nil })
                .map(\.member).sorted().first else { throw LocalMusicError.disconnected }
        return host
    }

    func upload(entry: LocalEntry, organization: AlbumOrganization, parents: [String], restore: Bool = false, host: String, file: URL, progress: @escaping (Double) -> Void) async throws -> String {
        let database = try store.database()
        let candidates = try await addresses(database: database).sorted { ($0.id().description == host ? 0 : 1) < ($1.id().description == host ? 0 : 1) }
        var failure: Error = LocalMusicError.clusterUnavailable
        for address in candidates {
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
                session = current
                defer { current.close(); session = nil }
                try await current.upload(entry: entry, organization: organization, parents: parents, restore: restore, file: file, progress: progress)
                try await current.reconcile(database: database)
                try store.save(database.clusterCatalog())
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
        let database = try store.database()
        let pending = try database.clusterMetadataEdits()
        guard !pending.isEmpty else { return }
        var failure: Error = LocalMusicError.clusterUnavailable
        for address in try await addresses(database: database) {
            do {
                let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
                session = current
                defer { current.close(); session = nil }
                for edit in try database.clusterMetadataEdits() {
                    do {
                        let revision = try await current.editMetadata(edit)
                        try database.finishClusterMetadataEdit(edit, revision: revision)
                    } catch LocalMusicError.clusterNeedsAttention {
                        failure = LocalMusicError.clusterNeedsAttention
                    }
                }
                try await current.reconcile(database: database)
                if try database.clusterMetadataEdits().isEmpty { return }
            } catch {
                try Task.checkCancellation()
                failure = error
            }
        }
        throw failure
    }

    func resolve(object: String, selected: String, parents: [String]) async throws -> LocalCatalog {
        let database = try store.database()
        guard let address = try await addresses(database: database).first else { throw LocalMusicError.disconnected }
        let current = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
        session = current
        defer { current.close(); session = nil }
        try await current.resolve(object: object, selected: selected, parents: parents)
        try await current.reconcile(database: database)
        let catalog = try database.clusterCatalog()
        try store.save(catalog)
        return catalog
    }

    func resolveAlbum(_ conflict: ClusterAlbumConflict, title: String) async throws -> LocalCatalog {
        let database = try store.database()
        let states = try database.clusterObjectStates()
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
        let catalog = try database.clusterCatalog()
        try store.save(catalog)
        return catalog
    }
}

@MainActor
final class ClusterSession {
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

    private let endpoint: IrohLib.Endpoint
    private let connection: IrohLib.Connection
    let peer: String

    private init(endpoint: IrohLib.Endpoint, connection: IrohLib.Connection, peer: String) {
        self.endpoint = endpoint; self.connection = connection; self.peer = peer
    }

    func close() {
        try? connection.close(errorCode: 0, reason: Data())
        Task { try? await endpoint.close() }
    }

    private static func open(address: IrohLib.EndpointAddr, alpn: String, secrets: CredentialStore) async throws -> ClusterSession {
        let endpoint = try await IrohLib.Endpoint.bind(options: IrohLib.EndpointOptions(
            preset: IrohLib.presetMinimal(), secretKey: await PeerMusicConnection.identity(secrets: secrets), relayMode: .disabled()))
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
        guard body.count <= 4 * 1024 * 1024 else { throw LocalMusicError.invalidData }
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
        guard count > 0, count <= 4 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        return try JSONDecoder().decode(type, from: await stream.recv().readExact(size: UInt32(count)))
    }

    static func enroll(invitation: ClusterInvitation, address: IrohLib.EndpointAddr, secrets: CredentialStore, database: CatalogDatabase, name: String) async throws {
        guard invitation.host == address.id().description else { throw LocalMusicError.unauthorized }
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

    static func connect(address: IrohLib.EndpointAddr, secrets: CredentialStore, database: CatalogDatabase) async throws -> ClusterSession {
        guard let registration = try database.clusterRegistration() else { throw LocalMusicError.unauthorized }
        let session = try await open(address: address, alpn: "syncstr/cluster/2", secrets: secrets)
        do {
            let stream = try await session.connection.openBi()
            try await session.send(Hello(capabilities: ClusterCapabilities(version: 1, membership: true, deletions: true, conflicts: true), proof: registration.membership), stream: stream)
            try await stream.send().finish()
            let hello = try await session.receive(Hello.self, stream: stream)
            guard hello.capabilities.allowsAutomaticWriter else { throw LocalMusicError.incompatiblePeer }
            try database.authenticateClusterPeer(session.peer, membership: hello.proof)
            return session
        } catch { session.close(); throw error }
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

    func upload(entry: LocalEntry, organization: AlbumOrganization, parents: [String], restore: Bool = false, file: URL, progress: @escaping (Double) -> Void) async throws {
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
            progress(Double(sent) / Double(size))
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

    func download(_ entry: LocalEntry, store: LocalMusicStore, database: CatalogDatabase, progress: @escaping (Double) -> Void) async throws {
        guard LocalMusicStore.valid(entry), let size = entry.track.size else { throw LocalMusicError.invalidData }
        let current = try database.clusterDownloadEntry(object: entry.sha256, peer: peer)
        guard current.track.size == size, let registration = try database.clusterRegistration() else { throw LocalMusicError.invalidData }
        let member = try registration.membership.verify(registration.localGrant).member
        let pending = try database.clusterJobs().first { $0.sha256 == entry.sha256 && $0.source == peer && $0.destination == member && $0.state == .queued }
        let job = pending ?? ClusterTransferJob(id: UUID().uuidString, sha256: entry.sha256, source: peer, destination: member, state: .queued)
        try database.enqueueClusterJob(job)
        try database.beginClusterJob(job.id)
        defer { try? database.retryClusterJob(job.id) }
        try store.prepare()
        let temporary = store.root.appendingPathComponent(".cluster-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw LocalMusicError.invalidData }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(240)) } catch { return }
            close()
        }
        defer { timeout.cancel() }
        let stream = try await connection.openBi()
        try await send(Request(operation: "audio", object: entry.sha256), stream: stream)
        try await stream.send().finish()
        let response = try await receive(Response.self, stream: stream)
        guard response.status == "audio", let remote = response.entry,
              remote.sha256 == entry.sha256, remote.track.size == size else { throw LocalMusicError.disconnected }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        var received: UInt64 = 0
        while received < size {
            try Task.checkCancellation()
            let bytes = try await stream.recv().readExact(size: UInt32(min(65536, size - received)))
            try file.write(contentsOf: bytes)
            received += UInt64(bytes.count)
            progress(Double(received) / Double(size))
        }
        guard try await stream.recv().readToEnd(sizeLimit: 1).isEmpty else { throw LocalMusicError.invalidData }
        try file.synchronize()
        try file.close()
        try Task.checkCancellation()
        let selected = try database.clusterDownloadEntry(object: entry.sha256, peer: peer)
        try await Task.detached { try store.importFile(temporary, entry: selected, recordReceipt: false) }.value
        let descriptor = Darwin.open(store.root.path, O_RDONLY)
        guard descriptor >= 0 else { throw LocalMusicError.invalidData }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw LocalMusicError.invalidData }
        try database.finishClusterDownload(job.id, entry: selected, file: store.fileURL(selected))
    }
}
