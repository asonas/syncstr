import CryptoKit
import Foundation

struct Track: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String?
    var album: String? = nil
    var albumId: String? = nil
    var coverArt: String? = nil
    var duration: Double? = nil
    var track: Int? = nil
    var discNumber: Int? = nil
    var suffix: String? = nil
    var size: UInt64? = nil

    var albumKey: String { albumId ?? "\(artist ?? "")\u{1f}\(album ?? "")" }
}

struct Navidrome {
    let server: URL
    private let username: String
    private let password: String

    init(server: String, username: String, password: String) throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil else {
            throw ClientError.invalidServer
        }
        self.server = url
        self.username = username
        self.password = password
    }

    func url(_ endpoint: String, parameters: [URLQueryItem] = []) -> URL {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        // OpenSubsonic requires MD5(password + salt) for token authentication.
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var parts = URLComponents(url: server.appendingPathComponent("rest/\(endpoint).view"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "c", value: "syncstr"),
            URLQueryItem(name: "f", value: "json")
        ] + parameters
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    func tracks(session: URLSession) async throws -> [Track] {
        _ = try await response("ping", session: session)
        var tracks: [Track] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let result = try await response("search3", parameters: [
                URLQueryItem(name: "query", value: ""),
                URLQueryItem(name: "artistCount", value: "0"),
                URLQueryItem(name: "albumCount", value: "0"),
                URLQueryItem(name: "songCount", value: "100"),
                URLQueryItem(name: "songOffset", value: String(offset))
            ], session: session)
            guard let search = result.searchResult3 else { throw ClientError.response }
            let page = search.song ?? []
            tracks += page
            if page.count < 100 { return tracks }
            offset += page.count
        }
    }

    func checksum(_ track: Track, session: URLSession) async throws -> String {
        let (bytes, response) = try await session.bytes(from: url("download", parameters: [URLQueryItem(name: "id", value: track.id)]))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ClientError.connection }
        var digest = SHA256()
        var buffer = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count == 65536 { digest.update(data: buffer); buffer.removeAll(keepingCapacity: true) }
        }
        digest.update(data: buffer)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func response(_ endpoint: String, parameters: [URLQueryItem] = [], session: URLSession) async throws -> Response {
        let (data, response) = try await session.data(from: url(endpoint, parameters: parameters))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClientError.connection
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.response.status == "ok" else {
            throw envelope.response.error?.code == 40 ? ClientError.authentication : ClientError.response
        }
        return envelope.response
    }

    struct Envelope: Decodable {
        let response: Response
        enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
    }
    struct Response: Decodable {
        let status: String
        let error: APIError?
        let searchResult3: Search?
    }
    struct APIError: Decodable { let code: Int }
    struct Search: Decodable { let song: [Track]? }
}

enum ClientError: LocalizedError {
    case invalidServer, connection, authentication, response
    var errorDescription: String? {
        switch self {
        case .invalidServer: "接続先には HTTPS のサーバーURLを入力してください。"
        case .connection: "サーバーへ接続できませんでした。接続先とネットワークを確認してください。"
        case .authentication: "ログインできませんでした。ユーザー名とパスワードを確認してください。"
        case .response: "サーバーから曲一覧を取得できませんでした。"
        }
    }
}

final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
