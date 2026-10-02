import CryptoKit
import Foundation

struct UploadReceipt: Decodable {
    let filename: String
    let bytes: UInt64
    let sha256: String
}

final class UploadRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct UploadClient: Sendable {
    let server: URL
    private let token: String

    init(server: String, token: String) throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw UploadError.invalidServer }
        guard token.utf8.count >= 32, token.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw UploadError.invalidToken
        }
        self.server = url
        self.token = token
    }

    func checkConnection(session suppliedSession: URLSession? = nil) async throws {
        // Authentication precedes filename validation; this invalid name cannot create a file.
        let url = server.appendingPathComponent("v1/uploads/connection-check")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = Data()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        let session = suppliedSession ?? URLSession(configuration: config, delegate: UploadRedirectPolicy(), delegateQueue: nil)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        let code = (try? JSONDecoder().decode(UploadFailure.self, from: data))?.error
        guard http.statusCode == 400 && code == "invalid_filename" else {
            throw UploadError.rejected(http.statusCode, code)
        }
    }

    func upload(_ source: URL, session suppliedSession: URLSession? = nil,
                prepareCopy: (@Sendable (URL) throws -> Void)? = nil) async throws -> UploadReceipt {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent(source.lastPathComponent)
        let (size, checksum) = try await Task.detached {
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: snapshot)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
            try prepareCopy?(snapshot)
            let handle = try FileHandle(forReadingFrom: snapshot)
            defer { try? handle.close() }
            var digest = SHA256()
            var count: UInt64 = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
                count += UInt64(data.count)
            }
            return (count, digest.finalize().map { String(format: "%02x", $0) }.joined())
        }.value
        try Task.checkCancellation()
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard let name = source.lastPathComponent.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw UploadError.invalidFile
        }
        let basePath = parts.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        parts.percentEncodedPath = (basePath.isEmpty ? "" : "/\(basePath)") + "/v1/uploads/\(name)"
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        request.setValue(checksum, forHTTPHeaderField: "X-Content-SHA256")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 960
        let session = suppliedSession ?? URLSession(configuration: config, delegate: UploadRedirectPolicy(), delegateQueue: nil)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let (data, response) = try await session.upload(for: request, fromFile: snapshot)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }
        guard http.statusCode == 201 else {
            throw UploadError.rejected(http.statusCode, (try? JSONDecoder().decode(UploadFailure.self, from: data))?.error)
        }
        let receipt = try JSONDecoder().decode(UploadReceipt.self, from: data)
        guard receipt.filename == source.lastPathComponent, receipt.bytes == size, receipt.sha256 == checksum else {
            throw UploadError.invalidResponse
        }
        return receipt
    }
}

private struct UploadFailure: Decodable { let error: String }

enum UploadError: LocalizedError {
    case invalidServer, invalidToken, invalidFile, invalidResponse
    case rejected(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "アップロード先のHTTPS URLを入力してください。"
        case .invalidToken: return "アップロード用トークンを確認してください。"
        case .invalidFile: return "このファイル名ではアップロードできません。"
        case .invalidResponse: return "サーバーからの応答を確認できませんでした。"
        case .rejected(let status, let code):
            switch status {
            case 401: return "アップロード用トークンが拒否されました。"
            case 409: return "同名のファイルが保存されています。サーバー側を確認してください。"
            case 413: return "ファイルがサイズ制限を超えているか、サイズが一致しません。"
            case 422 where code == "checksum_mismatch": return "転送したファイルのチェックサムが一致しません。"
            case 422: return "音楽ファイルとして確認できませんでした。形式やファイルの内容を確認してください。"
            case 400: return "対応する音楽形式とファイル名を確認してください。"
            case 429: return "サーバーが転送中です。しばらくして再試行してください。"
            case 300..<400: return "アップロード先がリダイレクトしました。最終的なHTTPS URLを入力してください。"
            default: return "アップロードに失敗しました（HTTP \(status)）。"
            }
        }
    }
}
