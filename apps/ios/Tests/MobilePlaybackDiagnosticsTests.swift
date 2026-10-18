import Foundation
import Testing
@testable import Syncstr

@MainActor
struct MobilePlaybackDiagnosticsTests {
    @Test func failedPlaybackAndRetryExportLinkedAttempts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = PlaybackDiagnostics(root: root.appendingPathComponent("diagnostics"))
        let library = Library(diagnostics: recorder, localStore: LocalMusicStore(root: root.appendingPathComponent("music")))
        defer { library.closeLibrary() }
        let track = Track(id: "missing", title: "Fixture", artist: "Artist", suffix: "wav", size: 44)
        try library.openLocal(LocalCatalog(id: "fixture", name: "Fixture", entries: [
            LocalEntry(track: track, sha256: String(repeating: "a", count: 64), artwork: nil)
        ]))
        library.play(track)
        for _ in 0..<200 where library.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!library.loading)
        let first = try #require(library.failedDiagnosticID)
        library.resumePlayback()
        for _ in 0..<200 where library.loading { try await Task.sleep(for: .milliseconds(10)) }
        let retry = try #require(library.failedDiagnosticID)
        #expect(first != retry)
        let attempts = await recorder.recent()
        #expect(attempts.first?.retryOf == first)
        #expect(attempts.first?.outcome == "failed")
        let jsonl = await recorder.export(retry)
        let rows = try jsonl.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
        #expect(!rows.isEmpty)
        #expect(jsonl.contains(first) && jsonl.contains(retry))
        #expect(jsonl.contains("legacy_candidate"))
        #expect(jsonl.contains("clusterUnavailable"))
    }
}
