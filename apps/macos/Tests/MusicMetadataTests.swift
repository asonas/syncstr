import AudioTags
import AVFoundation
import CryptoKit
import XCTest

final class MusicMetadataTests: XCTestCase {
    func testMP3FLACAndM4AEditFieldsAndCoverWithoutTouchingSource() throws {
        for ext in ["mp3", "flac", "m4a"] {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "untagged", withExtension: ext))
            let bytes = try Data(contentsOf: source)
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            defer { try? FileManager.default.removeItem(at: copy) }
            try bytes.write(to: copy)
            let original = try MusicMetadata.read(copy)
            var edited = original
            edited.title = "夜の音楽"; edited.artist = "Artist"; edited.album = "Album"; edited.track = "3"
            edited.artwork = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
            edited.artworkMIME = "image/png"
            try edited.writeChanges(from: original, to: copy)
            let reopened = try MusicMetadata.read(copy)
            XCTAssertEqual(reopened.title, edited.title, ext)
            XCTAssertEqual(reopened.artist, edited.artist, ext)
            XCTAssertEqual(reopened.album, edited.album, ext)
            XCTAssertEqual(reopened.track, "3", ext)
            XCTAssertEqual(reopened.artwork, edited.artwork, ext)
            XCTAssertEqual(try Data(contentsOf: source), bytes, ext)
        }
    }
    func testUntaggedWAVGetsUnicodeFieldsAndArtworkWithoutChangingAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("untagged.wav")
        let copy = directory.appendingPathComponent("copy.wav")
        let bytes = wavFixture()
        try bytes.write(to: source)
        try FileManager.default.copyItem(at: source, to: copy)
        let original = try MusicMetadata.read(source)
        XCTAssertEqual(original.title, "")
        var edited = original
        edited.title = "夜の音楽"
        edited.artist = "音楽家"
        edited.album = "Album"
        edited.track = "2/12"
        let picture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1sAAAAASUVORK5CYII=")!
        edited.artwork = picture
        edited.artworkMIME = "image/png"
        try edited.writeChanges(from: original, to: copy)
        let reopened = try MusicMetadata.read(copy)
        XCTAssertEqual(reopened.title, edited.title)
        XCTAssertEqual(reopened.artist, edited.artist)
        XCTAssertEqual(reopened.album, edited.album)
        XCTAssertEqual(reopened.track, "2/12")
        XCTAssertEqual(reopened.artwork, picture)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forReading: copy)
        XCTAssertEqual(input.length, output.length)
        let a = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: UInt32(input.length))!
        let b = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: UInt32(output.length))!
        try input.read(into: a); try output.read(into: b)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: a.floatChannelData![0], count: Int(a.frameLength))),
                       Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))))

        var removed = reopened
        removed.artwork = nil
        try removed.writeChanges(from: reopened, to: copy)
        XCTAssertNil(try MusicMetadata.read(copy).artwork)
    }

    func testEditingOneFieldPreservesUnrelatedTagsAndNoOpKeepsBytes() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try wavFixture().write(to: file)
        try AudioTags.writeFile(file, fields: ["TITLE": "Before", "GENRE": "Electronic", "COMMENT": "Keep this", "ALBUMARTIST": "Various Artists"],
                                artwork: nil, mimeType: nil, changeArtwork: false)
        let original = try MusicMetadata.read(file)
        let before = try Data(contentsOf: file)
        try original.writeChanges(from: original, to: file)
        XCTAssertEqual(try Data(contentsOf: file), before)
        var edited = original; edited.title = "After"
        try edited.writeChanges(from: original, to: file)
        let fields = try AudioTags.readFile(file)
        XCTAssertEqual(fields["GENRE"] as? [String], ["Electronic"])
        XCTAssertEqual(fields["COMMENT"] as? [String], ["Keep this"])
        XCTAssertEqual(fields["ALBUMARTIST"] as? [String], ["Various Artists"])
        XCTAssertEqual(try MusicMetadata.read(file).title, "After")
        edited.track = "-1"
        XCTAssertThrowsError(try edited.writeChanges(from: original, to: file))
    }

    func testUploadHashesTheEditedCopyAndPreservesOriginal() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = wavFixture()
        try bytes.write(to: file)
        let original = try MusicMetadata.read(file)
        var edited = original; edited.title = "Upload title"
        let update = edited
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MetadataUploadFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = try UploadClient(server: "https://example.test", token: "fixture-upload-token-0123456789abcdef")
        let receipt = try await client.upload(file, session: session, prepareCopy: { copy in
            try update.writeChanges(from: original, to: copy)
            XCTAssertEqual(try MusicMetadata.read(copy).title, "Upload title")
            let data = try Data(contentsOf: copy)
            MetadataUploadFixture.expectedBytes = UInt64(data.count)
            MetadataUploadFixture.expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        })
        XCTAssertGreaterThan(receipt.bytes, UInt64(bytes.count))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}

private final class MetadataUploadFixture: URLProtocol {
    static var expectedBytes: UInt64 = 0
    static var expectedHash = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), String(Self.expectedBytes))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Content-SHA256"), Self.expectedHash)
        let receipt: [String: Any] = ["filename": request.url!.lastPathComponent, "bytes": Self.expectedBytes, "sha256": Self.expectedHash]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: receipt))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func wavFixture() -> Data {
    var data = Data()
    func text(_ value: String) { data.append(contentsOf: value.utf8) }
    func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    text("RIFF"); u32(68); text("WAVEfmt "); u32(16); u16(1); u16(1)
    u32(44100); u32(88200); u16(2); u16(16); text("data"); u32(32)
    for value: UInt16 in [0, 100, 200, 100, 0, 65000, 64000, 65000, 0, 100, 200, 100, 0, 65000, 64000, 65000] { u16(value) }
    return data
}
