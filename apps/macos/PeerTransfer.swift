import Foundation
import IrohLib

@MainActor
protocol MusicChannel: AnyObject {
    func send(_ message: MusicMessage) async throws
    func receive() async throws -> MusicMessage
    func close()
}

extension MusicConnection: MusicChannel {}

struct PeerAddress: Codable {
    let version: Int
    let id: String
    let addresses: [String]
    let relay: String?

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
        let target = try address.endpoint(expected: expected)
        let endpoint = try await IrohLib.Endpoint.bind(options: IrohLib.EndpointOptions(
            preset: IrohLib.presetMinimal(), secretKey: await identity(secrets: secrets),
            relayMode: address.relay == nil ? IrohLib.RelayMode.disabled() : IrohLib.RelayMode.defaultMode()))
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
        guard message.version == 1 else { throw LocalMusicError.invalidData }
        return message
    }
}
