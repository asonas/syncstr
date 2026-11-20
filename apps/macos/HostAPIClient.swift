import Foundation

struct HostAddress: Equatable, Sendable {
    let origin: URL
    var host: String { origin.host! }
    var port: Int? { origin.port }

    init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text, encodingInvalidCharacters: false), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.percentEncodedHost?.contains("%") == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.percentEncodedPath), !text.contains("\\"),
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !text.hasSuffix(":"), !text.hasSuffix(":/") else { throw HostAPIError.address }
        if let range = parts.rangeOfPort {
            guard let raw = parts.string, let port = Int(raw[range]), (1...65535).contains(port) else { throw HostAPIError.address }
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        if parts.port == 443 { parts.port = nil }
        guard let url = parts.url else { throw HostAPIError.address }
        origin = url
    }

    init(link: URL) throws {
        guard let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "syncstr", parts.host?.lowercased() == "open",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.path.isEmpty,
              let hosts = parts.queryItems?.filter({ $0.name == "host" }), hosts.count == 1,
              let address = hosts.first?.value else { throw HostAPIError.address }
        try self.init(address)
    }
}

struct HostLibraryInfo: Decodable {
    struct Host: Codable, Equatable {
        let id: String
        let address: String
        var role: String?
    }
    let library: String
    let name: String
    let host: Host
    let hosts: [Host]
    let role: String
    let marker: String
}

struct HostConnection: Equatable {
    let address: HostAddress
    let library: String
    var name: String
    var hosts: [HostLibraryInfo.Host]
    var etag: String?
    var marker: String?
    var hostSwitch: String?
}

enum HostAPIError: LocalizedError, Equatable {
    case address, notHost, notRunning, notFound, method, rateLimited(Int?), storage, status(Int)
    var errorDescription: String? {
        switch self {
        case .address: "HTTPSのホストアドレスを確認してください。"
        case .notHost: "このアドレスにSyncstrライブラリが見つかりません。"
        case .notRunning: "ホストでSyncstrを起動してください。"
        case .notFound: "ホストに要求した項目が見つかりません。"
        case .method: "このホストでは要求した操作を利用できません。"
        case .rateLimited: "ホストが混み合っています。しばらくしてから再試行してください。"
        case .storage: "ホストがライブラリを読み込めませんでした。"
        case .status(let code): "ホストから取得できませんでした（\(code)）。"
        }
    }
}

final class HostRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class HostAPIClient: Sendable {
    private let address: HostAddress
    private let session: URLSession
    private let switchObserved: @Sendable (String) -> Void

    init(address: HostAddress, configuration: URLSessionConfiguration = .ephemeral,
         switchObserved: @escaping @Sendable (String) -> Void = { _ in }) {
        self.address = address
        self.switchObserved = switchObserved
        let settings = configuration.copy() as! URLSessionConfiguration
        settings.timeoutIntervalForRequest = 60
        settings.timeoutIntervalForResource = max(settings.timeoutIntervalForResource, 7 * 86400)
        settings.waitsForConnectivity = false
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        session = URLSession(configuration: settings, delegate: HostRedirectPolicy(), delegateQueue: nil)
    }

    func stop() { session.invalidateAndCancel() }
    deinit { session.invalidateAndCancel() }

    private func request(_ path: String, timeout: TimeInterval = 15) -> URLRequest {
        URLRequest(url: address.origin.appendingPathComponent("api/v1/" + path),
                   cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    }

    private func response(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw HostAPIError.notHost }
        if let value = http.value(forHTTPHeaderField: "Syncstr-Switch") { switchObserved(value) }
        return http
    }

    private func check(_ response: HTTPURLResponse, body: Data) throws {
        struct Failure: Decodable { let error: String; let message: String }
        switch response.statusCode {
        case 200: return
        case 300..<400: throw HostAPIError.notHost
        case 416: throw HostAPIError.status(416)
        default: break
        }
        guard let failure = try? JSONDecoder().decode(Failure.self, from: body) else { throw HostAPIError.notRunning }
        switch failure.error {
        case "not-found": throw HostAPIError.notFound
        case "method-not-allowed": throw HostAPIError.method
        case "storage-failed": throw HostAPIError.storage
        case "rate-limited": throw HostAPIError.rateLimited(response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
        default:
            switch response.statusCode {
            case 404: throw HostAPIError.notFound
            case 405: throw HostAPIError.method
            case 429: throw HostAPIError.rateLimited(response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init))
            case 500: throw HostAPIError.storage
            default: throw HostAPIError.status(response.statusCode)
            }
        }
    }

    func library() async throws -> HostLibraryInfo {
        let (data, reply) = try await session.data(for: request("library"))
        try check(response(reply), body: data)
        guard let info = try? JSONDecoder().decode(HostLibraryInfo.self, from: data) else { throw HostAPIError.notHost }
        return info
    }

    @concurrent
    func catalog(etag: String?) async throws -> CatalogRefresh {
        struct Document: Decodable {
            let id: String
            let name: String
            let marker: String
            let entries: [LocalEntry]
            var organization: AlbumOrganization
            let playlists: [PlaylistDocument]
            let conflictedPlaylists: Set<String>
        }
        var get = request("catalog")
        get.setValue(etag, forHTTPHeaderField: "If-None-Match")
        get.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await session.data(for: get)
        let http = try self.response(response)
        if http.statusCode == 304, etag != nil { return .unchanged }
        try check(http, body: data)
        guard var document = try? JSONDecoder().decode(Document.self, from: data) else { throw HostAPIError.notHost }
        guard let tag = http.value(forHTTPHeaderField: "ETag"), tag == "W/\"\(document.id).\(document.marker)\"",
              Set(document.entries.map(\.track.id)).count == document.entries.count,
              document.entries.allSatisfy(LocalMusicStore.valid) else { throw LocalMusicError.invalidData }
        let assets = document.organization.artwork?.assets ?? [:]
        guard assets.allSatisfy({ ClusterIdentity.isLowercaseHex256($0.key) && $0.value.isEmpty }) else { throw LocalMusicError.invalidData }
        let ids = Set(assets.keys)
        document.organization.artwork?.assets = [:]
        try document.organization.validate(remoteAssets: ids)
        var catalog = LocalCatalog(id: document.id, name: document.name, entries: document.entries, organization: document.organization)
        catalog.remoteArtwork = ids
        return .updated(CatalogUpdate(catalog: catalog, playlists: document.playlists, conflicts: document.conflictedPlaylists,
                                      marker: document.marker, etag: tag, hostSwitch: http.value(forHTTPHeaderField: "Syncstr-Switch")))
    }

    func audio(sha256: String) async throws -> URL {
        guard ClusterIdentity.isLowercaseHex256(sha256) else { throw LocalMusicError.invalidData }
        var resume: Data?
        var delay = 2
        while true {
            try Task.checkCancellation()
            do {
                let file: URL
                let reply: URLResponse
                if let resume { (file, reply) = try await session.download(resumeFrom: resume) }
                else { (file, reply) = try await session.download(for: request("audio/" + sha256, timeout: 60)) }
                do {
                    let http = try response(reply)
                    if !(resume != nil && http.statusCode == 206), http.statusCode != 200 {
                        let handle = try FileHandle(forReadingFrom: file)
                        defer { try? handle.close() }
                        try check(http, body: try handle.read(upToCount: 65536) ?? Data())
                    }
                    return file
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
            } catch let error as URLError where error.code != .cancelled {
                resume = error.downloadTaskResumeData
                if resume == nil, ![.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                                    .cannotFindHost, .dnsLookupFailed, .resourceUnavailable].contains(error.code) { throw error }
            } catch HostAPIError.status(416) where resume != nil {
                resume = nil
            } catch HostAPIError.rateLimited(let after) {
                try await Task.sleep(for: .seconds(max(0, after ?? 0)))
                resume = nil
            }
            try await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 300)
        }
    }

    func artwork(id: String) async throws -> Data {
        guard ClusterIdentity.isLowercaseHex256(id) else { throw LocalMusicError.invalidData }
        var delay = 2
        while true {
            try Task.checkCancellation()
            let (bytes, reply) = try await session.data(for: request("artwork/" + id))
            let http = try response(reply)
            if http.statusCode == 429 {
                let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                try await Task.sleep(for: .seconds(max(0, after ?? 0)))
                try await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 300)
                continue
            }
            guard http.statusCode == 200 else { throw HostAPIError.status(http.statusCode) }
            guard LocalMusicStore.digest(bytes) == id, ArtworkImage.valid(bytes) else { throw LocalMusicError.invalidData }
            return bytes
        }
    }
}

