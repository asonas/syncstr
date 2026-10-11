import Foundation
import IrohLib

final class LANDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let expected: String
    private var services: [NetService] = []
    private var addresses: [String] = []

    private init(expected: String) { self.expected = expected }

    static func find(peer: String) throws -> EndpointAddr {
        let discovery = LANDiscovery(expected: peer)
        let browser = NetServiceBrowser()
        browser.delegate = discovery
        browser.searchForServices(ofType: "_syncstr-probe._udp.", inDomain: "local.")
        defer {
            browser.stop()
            discovery.services.forEach { $0.stop() }
        }
        let deadline = Date().addingTimeInterval(15)
        while discovery.addresses.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !discovery.addresses.isEmpty else {
            throw NSError(domain: "Probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bonjour discovery timed out"])
        }
        return EndpointAddr(id: try EndpointId.fromString(s: peer), relayUrl: nil, addresses: discovery.addresses)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        // The abbreviated instance name is only a filter; TXT and QUIC verify the full ID.
        guard service.name == String(expected.prefix(16)) else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let data = sender.txtRecordData() else { return }
        let properties = NetService.dictionary(fromTXTRecord: data)
        guard properties["id"] == Data(expected.utf8), properties["version"] == Data("1".utf8) else { return }
        addresses = (sender.addresses ?? []).compactMap { data in
            data.withUnsafeBytes { bytes -> String? in
                guard let base = bytes.baseAddress, data.count >= MemoryLayout<sockaddr>.size else { return nil }
                let socket = base.assumingMemoryBound(to: sockaddr.self)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
                guard getnameinfo(socket, socklen_t(data.count), &host, socklen_t(host.count),
                                  &port, socklen_t(port.count), NI_NUMERICHOST | NI_NUMERICSERV) == 0 else { return nil }
                let hostname = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let portNumber = String(decoding: port.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return hostname.contains(":") ? "[\(hostname)]:\(portNumber)" : "\(hostname):\(portNumber)"
            }
        }
    }
}
