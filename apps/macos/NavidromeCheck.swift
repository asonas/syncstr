import Foundation

final class FixtureProtocol: URLProtocol {
    static var reject = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)!.percentEncodedQuery!.contains("%2B"))
        let parameters = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        precondition(parameters["p"] == nil)
        precondition(parameters["t"]?.count == 32 && parameters["s"]!.count >= 6)
        precondition(parameters["u"] == "日本語+user")
        let payload: [String: Any]
        if Self.reject {
            payload = ["status": "failed", "error": ["code": 40]]
        } else if url.lastPathComponent == "ping.view" {
            payload = ["status": "ok"]
        } else {
            precondition(parameters["query"] == "")
            let offset = Int(parameters["songOffset"]!)!
            let count = offset == 0 ? 100 : 1
            precondition(offset == 0 || offset == 100)
            let songs = (offset..<(offset + count)).map { ["id": String($0), "title": "曲\($0)", "artist": "歌手"] }
            payload = ["status": "ok", "searchResult3": ["song": songs]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["subsonic-response": payload])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct Checks {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = try Navidrome(server: "https://music.example/subpath", username: "日本語+user", password: "fixture-password")
        let tracks = try await client.tracks(session: session)
        precondition(tracks.count == 101 && tracks.last?.title == "曲100")
        let stream = client.url("stream", parameters: [URLQueryItem(name: "id", value: tracks[0].id)])
        precondition(stream.path == "/subpath/rest/stream.view")
        precondition(!stream.absoluteString.contains("fixture-password"))
        print("PASS: authenticated paged library and stream request")
        FixtureProtocol.reject = true
        do {
            _ = try await client.tracks(session: session)
            fatalError("Authentication rejection accepted")
        } catch ClientError.authentication {}
        print("PASS: rejected login")
        do {
            _ = try Navidrome(server: "http://music.example", username: "user", password: "password")
            fatalError("HTTP accepted")
        } catch ClientError.invalidServer {}
        print("PASS: HTTPS required")
    }
}
