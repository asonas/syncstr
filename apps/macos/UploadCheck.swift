import Foundation

final class UploadFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        precondition(request.httpMethod == "PUT")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-upload-token-0123456789abcdef")
        precondition(request.value(forHTTPHeaderField: "Content-Length") == "3")
        precondition(request.value(forHTTPHeaderField: "X-Content-SHA256") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        precondition(url.query == nil && !url.absoluteString.contains("fixture-upload-token"))
        let conflict = url.path.contains("/conflict/")
        let payload: [String: Any] = conflict ? ["error": "file_exists"] : [
            "filename": "曲 #1.wav", "bytes": 3,
            "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        ]
        if !conflict { precondition(url.path == "/base/v1/uploads/曲 #1.wav") }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: conflict ? 409 : 201,
                                                            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct UploadChecks {
    static func main() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("曲 #1.wav")
        try Data("abc".utf8).write(to: file)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let token = "fixture-upload-token-0123456789abcdef"
        let client = try UploadClient(server: "https://upload.example/base/", token: token)
        let receipt = try await client.upload(file, session: session)
        precondition(receipt.bytes == 3 && receipt.filename == file.lastPathComponent)
        let original = try Data(contentsOf: file)
        precondition(original == Data("abc".utf8))
        let conflict = try UploadClient(server: "https://upload.example/conflict", token: token)
        do { _ = try await conflict.upload(file, session: session); fatalError("Conflict accepted") }
        catch UploadError.rejected(409, _) {}
        do { _ = try UploadClient(server: "http://upload.example", token: token); fatalError("HTTP accepted") }
        catch UploadError.invalidServer {}
        print("PASS: upload headers, SHA-256, encoded filename, receipt, conflict and HTTPS requirement")
    }
}
