import Foundation
import IrohLib

@MainActor
final class ClusterDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private(set) var endpoints: [String: IrohLib.EndpointAddr] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_syncstr-cluster._udp.", inDomain: "local.")
    }

    func stop() {
        browser?.stop(); browser = nil
        services.forEach { $0.stop() }
        services = []; endpoints = [:]
    }

    func find(_ peer: String) async throws -> IrohLib.EndpointAddr {
        start()
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let endpoint = endpoints[peer] { return endpoint }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LocalMusicError.clusterUnavailable
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 256 else { return }
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if let data = service.txtRecordData(), let value = NetService.dictionary(fromTXTRecord: data)["id"],
           let id = String(data: value, encoding: .utf8) { endpoints.removeValue(forKey: id) }
        services.removeAll { $0 == service }
        service.stop()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let data = sender.txtRecordData() else { return }
        let properties = NetService.dictionary(fromTXTRecord: data)
        guard properties["version"] == Data("1".utf8), let bytes = properties["id"],
              let id = String(data: bytes, encoding: .utf8), ClusterIdentity.isLowercaseHex256(id),
              let key = try? IrohLib.EndpointId.fromString(s: id) else { return }
        let addresses = (sender.addresses ?? []).compactMap { data -> String? in
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress, data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == AF_INET else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
                guard getnameinfo(address, socklen_t(data.count), &host, socklen_t(host.count), &port, socklen_t(port.count), NI_NUMERICHOST | NI_NUMERICSERV) == 0 else { return nil }
                let hostname = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let number = String(decoding: port.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let octets = hostname.split(separator: ".").compactMap { Int($0) }
                guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }),
                      octets[0] == 10 || octets[0] == 127 || (octets[0] == 172 && (16...31).contains(octets[1]))
                        || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254),
                      let portNumber = Int(number), (1...65535).contains(portNumber) else { return nil }
                return "\(hostname):\(number)"
            }
        }
        if !addresses.isEmpty { endpoints[id] = IrohLib.EndpointAddr(id: key, relayUrl: nil, addresses: addresses) }
    }
}
