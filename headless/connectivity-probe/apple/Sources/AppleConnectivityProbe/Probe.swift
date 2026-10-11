import CryptoKit
import Foundation
import IrohLib

@main
struct Probe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Usage: AppleConnectivityProbe <disposable-device.key> <peer-id> <relay-url|--lan>"])
        }
        let key = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let peer = try EndpointId.fromString(s: arguments[2])
        let local = arguments[3] == "--lan"
        let address = local
            ? try await Task.detached { try LANDiscovery.find(peer: arguments[2]) }.value
            : EndpointAddr(id: peer, relayUrl: arguments[3], addresses: [])
        let endpoint = try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(), secretKey: key,
            relayMode: local ? RelayMode.disabled() : try RelayMode.customFromUrls(urls: [arguments[3]])))
        do {
            let connection = try await endpoint.connect(
                addr: address,
                alpn: Data("syncstr/connectivity-probe/1".utf8))
            let before = connection.paths()
            let payload = Data((0..<65536).map { UInt8($0 % 251) })
            let stream = try await connection.openBi()
            try await stream.send().writeAll(buf: payload)
            try await stream.send().finish()
            let received = try await stream.recv().readToEnd(sizeLimit: 32)
            guard received == Data(SHA256.hash(data: payload)) else {
                throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Digest mismatch"])
            }
            func paths(_ snapshots: [PathSnapshot]) -> [[String: Any]] {
                snapshots.map { ["kind": $0.isIp ? "direct" : ($0.isRelay ? "relay" : "other"),
                                  "selected": $0.isSelected] }
            }
            let report: [String: Any] = ["bytes": payload.count, "sha256": received.map { String(format: "%02x", $0) }.joined(),
                "paths_before": paths(before), "paths_after": paths(connection.paths())]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            try connection.close(errorCode: 0, reason: Data("probe complete".utf8))
            try await endpoint.close()
        } catch {
            try? await endpoint.close()
            throw error
        }
    }
}
