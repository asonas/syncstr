import XCTest
@testable import Syncstr

final class PhoneAPIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload: [String: Any]
        if request.url!.lastPathComponent == "ping.view" {
            payload = ["status": "ok"]
        } else {
            payload = ["status": "ok", "searchResult3": ["song": [
                ["id": "voyager", "title": "Voyager", "artist": "Daft Punk", "album": "Remix", "albumId": "remix", "suffix": "wav"]
            ]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["subsonic-response": payload])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LoginTests: XCTestCase {
    @MainActor
    func testSavedLoginLoadsLibraryAndLogoutRemovesIt() async throws {
        let store = CredentialStore(service: "as.ason.syncstr.test." + UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneAPIProtocol.self]
        let session = URLSession(configuration: configuration)
        do {
            try await store.save(LoginCredentials(server: "https://fixture.invalid", username: "listener", password: "fixture-password"))
            let library = Library(session: session, credentials: store)
            await library.restoreCredentials()
            XCTAssertTrue(library.connected)
            XCTAssertFalse(library.restoringSession)
            XCTAssertEqual(library.albums.map(\.title), ["Remix"])
            XCTAssertEqual(library.tracks.map(\.title), ["Voyager"])
            XCTAssertTrue(library.password.isEmpty)
            library.disconnect()
            for _ in 0..<100 where library.refreshing {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(library.connected)
            let saved = try await store.load()
            XCTAssertNil(saved)
            try await store.remove()
        } catch {
            try? await store.remove()
            throw error
        }
    }
}
