import Foundation
import CryptoKit
import IrohLib

@MainActor
protocol MusicChannel: AnyObject {
    func send(_ message: MusicMessage) async throws
    func receive() async throws -> MusicMessage
    func close()
}

extension MusicConnection: MusicChannel {}

extension MusicChannel {
    func sendOrganized(_ message: MusicMessage, organization: AlbumOrganization?) async throws {
        var header = message
        guard let organization else { try await send(header); return }
        let data = try JSONEncoder().encode(organization)
        guard data.count <= 64 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        if data.count <= 1024 * 1024 {
            header.organization = organization
            try await send(header)
        } else {
            header.track = "organization"
            try await send(header)
            for offset in stride(from: 0, to: data.count, by: 65536) {
                try await send(MusicMessage(kind: "organization", bytes: data.subdata(in: offset..<min(offset + 65536, data.count))))
            }
            try await send(MusicMessage(kind: "organization-end"))
        }
    }

    func receiveOrganization(_ header: MusicMessage) async throws -> AlbumOrganization? {
        if let organization = header.organization { try organization.validate(); return organization }
        guard header.track == "organization" else { return nil }
        var bytes = Data()
        while true {
            let message = try await receive()
            if message.kind == "organization-end" { break }
            guard message.kind == "organization", let chunk = message.bytes, !chunk.isEmpty,
                  chunk.count <= 65536, bytes.count + chunk.count <= 64 * 1024 * 1024 else { throw LocalMusicError.invalidData }
            bytes.append(chunk)
        }
        let organization = try JSONDecoder().decode(AlbumOrganization.self, from: bytes)
        try organization.validate()
        return organization
    }
}

struct PeerAddress: Codable {
    let version: Int
    let id: String
    let addresses: [String]
    let relay: String?
    var directory: String? = nil

    static func parse(_ text: String) throws -> PeerAddress {
        guard text.utf8.count <= 16384 else { throw LocalMusicError.invalidData }
        let address = try JSONDecoder().decode(PeerAddress.self, from: Data(text.utf8))
        _ = try address.endpoint(expected: address.id)
        if let directory = address.directory { _ = try address.directoryURL(directory) }
        guard !address.addresses.isEmpty || address.relay != nil || address.directory != nil else { throw LocalMusicError.invalidData }
        return address
    }

    private func directoryURL(_ value: String) throws -> URL {
        guard value.utf8.count <= 2048, let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw LocalMusicError.invalidData }
        return url
    }

    func resolved(secrets: CredentialStore) async throws -> PeerAddress {
        guard let directory else { return self }
        struct Envelope: Codable { let payload: String; let signature: String }
        struct Announcement: Decodable { let kind: String; let id: String; let time: Int64; let expires: Int64; let address: PeerAddress }
        let origin = try directoryURL(directory)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: await PeerMusicConnection.identity(secrets: secrets))
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: [
            "kind": "lookup", "id": key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
            "time": time, "target": id
        ], options: [.sortedKeys]), as: UTF8.self)
        let signature = try key.signature(for: Data(("syncstr-rendezvous-v1\n" + payload).utf8)).base64EncodedString()
        var request = URLRequest(url: origin.appendingPathComponent("v1/lookup"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Envelope(payload: payload, signature: signature))
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.host == origin.host, response.url?.scheme == "https" else { throw LocalMusicError.disconnected }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < 32768 else { throw LocalMusicError.invalidData }
            bytes.append(byte)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard let signature = Data(base64Encoded: envelope.signature), id.count == 64,
              id.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw LocalMusicError.invalidData }
        var publicBytes = Data()
        var cursor = id.startIndex
        while cursor < id.endIndex {
            let end = id.index(cursor, offsetBy: 2)
            guard let byte = UInt8(id[cursor..<end], radix: 16) else { throw LocalMusicError.invalidData }
            publicBytes.append(byte)
            cursor = end
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
        guard publicKey.isValidSignature(signature, for: Data(("syncstr-rendezvous-v1\n" + envelope.payload).utf8)) else {
            throw LocalMusicError.unauthorized
        }
        let announcement = try JSONDecoder().decode(Announcement.self, from: Data(envelope.payload.utf8))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard announcement.kind == "announce", announcement.id == id, announcement.address.id == id,
              announcement.time >= 0, announcement.time <= now + 60000,
              announcement.expires > now, announcement.expires <= announcement.time + 300000,
              announcement.address.relay == nil,
              announcement.address.directory == nil, !announcement.address.addresses.isEmpty else { throw LocalMusicError.invalidData }
        _ = try announcement.address.endpoint(expected: id)
        return announcement.address
    }

    func endpoint(expected: String) throws -> IrohLib.EndpointAddr {
        guard version == 1, id == expected, addresses.count <= 32,
              addresses.allSatisfy({ $0.utf8.count <= 128 }) else { throw LocalMusicError.invalidData }
        if let relay {
            guard relay.utf8.count <= 2048, let url = URL(string: relay), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else { throw LocalMusicError.invalidData }
        }
        return IrohLib.EndpointAddr(id: try IrohLib.EndpointId.fromString(s: id), relayUrl: relay, addresses: addresses)
    }
}

@MainActor
final class PeerMusicConnection: MusicChannel {
    static let alpn = Data("syncstr/music/1".utf8)
    private let endpoint: IrohLib.Endpoint
    private let connection: IrohLib.Connection
    private let stream: IrohLib.BiStream
    private var closed = false
    var isClosed: Bool { closed || connection.closeReason() != nil }

    private init(endpoint: IrohLib.Endpoint, connection: IrohLib.Connection, stream: IrohLib.BiStream) {
        self.endpoint = endpoint
        self.connection = connection
        self.stream = stream
    }

    static func identity(secrets: CredentialStore) async throws -> Data {
        if let saved = try await secrets.load() {
            guard let bytes = Data(base64Encoded: saved.key), bytes.count == 32 else { throw LocalMusicError.invalidData }
            return bytes
        }
        let key = IrohLib.SecretKey.generate()
        let bytes = key.toBytes()
        try await secrets.save(PairingCredentials(libraryID: "p2p", name: "device", key: bytes.base64EncodedString()))
        return bytes
    }

    static func publicID(secrets: CredentialStore) async throws -> String {
        try IrohLib.SecretKey.fromBytes(bytes: await identity(secrets: secrets)).public().description
    }

    static func connect(address: PeerAddress, expected: String, secrets: CredentialStore) async throws -> PeerMusicConnection {
        guard address.id == expected else { throw LocalMusicError.unauthorized }
        let resolved = try await address.resolved(secrets: secrets)
        let target = try resolved.endpoint(expected: expected)
        let endpoint = try await IrohLib.Endpoint.bind(options: IrohLib.EndpointOptions(
            preset: IrohLib.presetMinimal(), secretKey: await identity(secrets: secrets),
            relayMode: resolved.relay == nil ? IrohLib.RelayMode.disabled() : IrohLib.RelayMode.defaultMode()))
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            try? await endpoint.close()
        }
        defer { timeout.cancel() }
        do {
            let connection = try await endpoint.connect(addr: target, alpn: alpn)
            try Task.checkCancellation()
            guard connection.remoteId().description == expected else { throw LocalMusicError.unauthorized }
            let stream = try await connection.openBi()
            return PeerMusicConnection(endpoint: endpoint, connection: connection, stream: stream)
        } catch { try await endpoint.close(); throw error }
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? connection.close(errorCode: 0, reason: Data())
        Task { try? await endpoint.close() }
    }

    func send(_ message: MusicMessage) async throws {
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(message)
        guard !closed, body.count <= 2 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        let length = UInt32(body.count)
        var packet = Data([UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        packet.append(body)
        try await stream.send().writeAll(buf: packet)
    }

    func receive() async throws -> MusicMessage {
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            close()
        }
        defer { timeout.cancel() }
        let header = try await stream.recv().readExact(size: 4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 2 * 1024 * 1024 else { throw LocalMusicError.invalidData }
        let body = try await stream.recv().readExact(size: UInt32(count))
        let message = try JSONDecoder().decode(MusicMessage.self, from: body)
        guard message.version == 2 else { throw LocalMusicError.incompatiblePeer }
        return message
    }
}
