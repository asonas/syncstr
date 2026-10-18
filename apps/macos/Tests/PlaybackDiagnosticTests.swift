import Foundation
import Testing
import SQLite3

private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}

struct PlaybackDiagnosticTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func databaseContentionExportsOperationWithoutSQLOrPaths() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalMusicStore(root: directory)
        _ = try store.database()
        var writer: OpaquePointer?
        #expect(sqlite3_open(directory.appendingPathComponent("catalog.sqlite").path, &writer) == SQLITE_OK)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }
        let recorder = PlaybackDiagnostics(root: directory.appendingPathComponent("diagnostics"))
        let attempt = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: nil)
        do {
            _ = try store.database()
            Issue.record("Expected the competing writer to block database initialization")
        } catch {
            attempt.failure("resolution", error, terminal: true)
        }
        let exported = await recorder.export(attempt.id)
        #expect(exported.contains("Syncstr.CatalogDatabase"))
        #expect(exported.contains("database_busy"))
        #expect(exported.contains("\"error_database_operation\":\"BEGIN\""))
        #expect(!exported.contains(directory.path))
        #expect(!exported.contains("BEGIN IMMEDIATE"))
    }

    @Test func connectionHistorySurvivesRestartAndPrecedesRetryWithoutDuplicateEvents() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory)
        recorder.connection("connect_peer_called", fields: ["operation_id": "connection-one"])
        recorder.connection("connect_peer", outcome: "failed", fields: ["operation_id": "connection-one", "reason": "connection_refused"],
            error: NSError(domain: NSPOSIXErrorDomain, code: 61))
        let first = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: "fixture-library")
        first.record("acquisition", "failed", outcome: "failed", terminal: true)
        _ = await recorder.export(first.id)
        let reopened = PlaybackDiagnostics(root: directory)
        _ = await reopened.recent()
        reopened.connection("connect_peer_called", fields: ["operation_id": "connection-two"])
        reopened.connection("connect_peer", outcome: "succeeded", fields: ["operation_id": "connection-two", "reason": "catalog_received"])
        let retry = reopened.begin(title: "Fixture", track: "one", sha256: nil, library: "fixture-library", retryOf: first.id)
        reopened.captureConnections(in: retry)
        let traces = await reopened.recent()
        let events = try #require(traces.first).events
        #expect(events.filter { $0.event == "connect_peer_called" }.count == 2)
        #expect(events.contains { $0.fields["last_failed_reason"] == "connection_refused" })
        #expect(events.contains { $0.fields["last_succeeded_reason"] == "catalog_received" })
        #expect(events.filter { $0.stage == "connection_history" && $0.event != "snapshot" }.allSatisfy { $0.fields["observed_at"] != nil })
        let json = await reopened.export(retry.id)
        #expect(json.contains("connection-one") && json.contains("connection-two"))
    }

    @Test func readsPreviousArchiveWithoutDroppingPlaybackEvidence() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var previous = PlaybackDiagnosticTrace(id: "old-attempt", retryOf: nil, title: "Original", started: "2026-01-01T00:00:00Z")
        previous.outcome = "failed"
        try JSONEncoder().encode([previous]).write(to: directory.appendingPathComponent("attempts.json"))
        let recorder = PlaybackDiagnostics(root: directory)
        let traces = await recorder.recent()
        #expect(traces.first?.id == "old-attempt")
        #expect(!(await recorder.hasPersistenceFailure()))
    }

    @Test func connectionHistoryIsBoundedAndDisclosesOmissions() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory, limit: 32_000)
        for index in 0..<200 {
            recorder.connection("connect", fields: ["operation_id": String(index), "reason": "fixture"])
        }
        let context = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: nil)
        let exported = await recorder.export(context.id)
        let trace = try #require(await recorder.recent().first)
        let summary = try #require(trace.events.last(where: { $0.event == "snapshot" }))
        #expect(Int(summary.fields["history_omitted"] ?? "0") ?? 0 > 0)
        #expect(!exported.contains("\"persistence_failed\":\"true\""))
        #expect(exported.contains("\"complete\":\"false\""))
        #expect(try Data(contentsOf: directory.appendingPathComponent("attempts.json")).count <= 32_000)
    }

    @MainActor @Test func reloadWithoutRestoredPeerRecordsSkipAndPlaybackDecision() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory.appendingPathComponent("diagnostics"))
        let library = Library(diagnostics: recorder, localStore: LocalMusicStore(root: directory.appendingPathComponent("music")))
        let entry = LocalEntry(track: Track(id: "track-one", title: "Fixture", artist: "Artist", suffix: "wav", size: 4),
            sha256: String(repeating: "a", count: 64), artwork: nil)
        try library.openLocal(LocalCatalog(id: "fixture-library", name: "Fixture", entries: [entry]))
        library.reload()
        library.play(entry.track)
        for _ in 0..<1000 where library.loading { await Task.yield() }
        let trace = try #require(await recorder.recent().first)
        #expect(trace.events.contains { $0.event == "reload_connect_skipped" && $0.fields["reason"] == "peer_name_unavailable" })
        #expect(trace.events.contains { $0.event == "playback_connection_decision" && $0.fields["cluster_registration_read"] == "not_read" })
        #expect(trace.events.contains { $0.event == "playback_connection_decision" && $0.fields["connection_start"] == "reconnect_if_saved_endpoint" })
        #expect(trace.events.contains { $0.event == "runtime" && $0.fields["settings_root"] == library.localStore.root.path })
        library.closeLibrary()
    }

    @MainActor @Test(arguments: [false, true]) func absentAndUnreadableRegistrationStayDistinct(corrupt: Bool) async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory.appendingPathComponent("diagnostics"))
        let store = LocalMusicStore(root: directory.appendingPathComponent("music"))
        let library = Library(diagnostics: recorder, localStore: store)
        let entry = LocalEntry(track: Track(id: "track-one", title: "Fixture", artist: "Artist", suffix: "wav", size: 4),
            sha256: String(repeating: "a", count: 64), artwork: nil)
        try library.openLocal(LocalCatalog(id: "fixture-library", name: "Fixture", entries: [entry]))
        if corrupt {
            var database: OpaquePointer?
            #expect(sqlite3_open(store.root.appendingPathComponent("catalog.sqlite").path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            #expect(sqlite3_exec(database, "INSERT INTO cluster_registration VALUES (1, 'invalid-json')", nil, nil, nil) == SQLITE_OK)
        }
        library.transfer.connectCluster()
        for _ in 0..<1000 where library.transfer.busy { await Task.yield() }
        #expect(!library.transfer.busy)
        library.play(entry.track)
        for _ in 0..<1000 where library.loading { await Task.yield() }
        let trace = try #require(await recorder.recent().first)
        #expect(trace.events.contains { $0.event == "cluster_registration_read" && $0.fields["cluster_registration_read"] == (corrupt ? "failed" : "absent") })
        library.closeLibrary()
    }

    @MainActor @Test func libraryRetriesLinkAttemptsAndPreserveFailedCopyTarget() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory.appendingPathComponent("diagnostics"))
        let library = Library(diagnostics: recorder, localStore: LocalMusicStore(root: directory.appendingPathComponent("music")))
        let entry = LocalEntry(track: Track(id: "track-one", title: "Fixture", artist: "Artist", duration: 20, suffix: "wav", size: 4),
            sha256: String(repeating: "a", count: 64), artwork: nil)
        try library.openLocal(LocalCatalog(id: "fixture-library", name: "Fixture", entries: [entry]))
        library.play(entry.track)
        for _ in 0..<1000 where library.loading { await Task.yield() }
        #expect(!library.loading)
        let first = try #require(library.failedDiagnosticID)
        library.resumePlayback()
        for _ in 0..<1000 where library.loading { await Task.yield() }
        let second = try #require(library.failedDiagnosticID)
        #expect(first != second)
        let recent = await recorder.recent()
        #expect(recent.first?.retryOf == first)
        #expect(recent.first?.outcome == "failed")
        let json = await recorder.export(second)
        #expect(json.contains("legacy_candidate"))
        #expect(json.contains("clusterUnavailable"))
        library.pause()
        #expect(library.failedDiagnosticID == second)
        library.closeLibrary()
    }

    @MainActor @Test func cacheHashMismatchAndSaveFailuresHaveDistinctStages() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory.appendingPathComponent("diagnostics"))
        let context = recorder.begin(title: "Fixture", track: "track-one", sha256: nil, library: nil)
        let cache = PlaybackCache(root: directory.appendingPathComponent("cache"))
        let expected = Data([1, 2, 3, 4])
        let entry = LocalEntry(track: Track(id: "track-one", title: "Fixture", artist: "Artist", suffix: "wav", size: 4),
            sha256: LocalMusicStore.digest(expected), artwork: nil)
        try cache.store.prepare()
        try Data([4, 3, 2, 1]).write(to: cache.store.fileURL(entry))
        #expect(try cache.file(entry, diagnostic: context) == nil)
        #expect(!FileManager.default.fileExists(atPath: cache.store.fileURL(entry).path))
        let input = directory.appendingPathComponent("input.wav")
        try expected.write(to: input)
        let blocked = directory.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        #expect(throws: (any Error).self) {
            try LocalMusicStore(root: blocked).importFile(input, entry: entry, diagnostic: context)
        }
        let traces = await recorder.recent()
        #expect(traces[0].events.contains { $0.stage == "cache" && $0.outcome == "mismatch" })
        #expect(traces[0].events.contains { $0.stage == "verification" && $0.event == "hash" && $0.outcome == "matched" })
        #expect(traces[0].events.contains { $0.stage == "save" && $0.event == "error" })
    }

    @Test func candidateFailuresSurviveSuccessAndRetryExport() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory)
        let first = recorder.begin(title: "Fixture", track: "track-1", sha256: "abc", library: "library-1")
        first.source(1, peer: "peer-a").failure("connection", NSError(domain: NSPOSIXErrorDomain, code: 61))
        first.source(2, peer: "peer-b").failure("resolution", LocalMusicError.noMusic)
        first.record("acquisition", "failed", outcome: "failed", terminal: true)
        let retry = recorder.begin(title: "Fixture", track: "track-1", sha256: "abc", library: "library-1", retryOf: first.id)
        retry.source(1, peer: "peer-c").record("transfer", "finished", outcome: "succeeded")
        let exported = await recorder.export(retry.id)
        let rows = try exported.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(rows.filter { $0["event"] as? String == "error" }.count == 2)
        #expect(exported.contains("peer-a") && exported.contains("peer-b") && exported.contains("peer-c"))
        #expect(exported.range(of: first.id)!.lowerBound < exported.range(of: "peer-c")!.lowerBound)
        #expect(exported.contains("\"in_progress\":\"true\""))
        #expect((await recorder.recent()).first?.outcome == "active")
    }

    @Test func restartMarksInterruptedAndPreservesTerminalOutcome() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory)
        let finished = recorder.begin(title: "Done", track: "one", sha256: nil, library: nil)
        finished.record("player", "end", outcome: "completed", terminal: true)
        let active = recorder.begin(title: "Interrupted", track: "two", sha256: nil, library: nil)
        _ = await recorder.export(active.id)
        let reopened = PlaybackDiagnostics(root: directory)
        let traces = await reopened.recent()
        #expect(traces.first?.outcome == "interrupted")
        #expect(traces.first?.omitted == 1)
        #expect(traces.last?.outcome == "completed")
    }

    @Test func retentionBoundsAndMissingAncestorsAreExplicit() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory, limit: 32_000, attemptLimit: 2)
        let parent = recorder.begin(title: "Old", track: "old", sha256: nil, library: nil)
        parent.record("player", "end", outcome: "failed", terminal: true)
        let retry = recorder.begin(title: "Retry", track: "retry", sha256: nil, library: nil, retryOf: parent.id)
        for _ in 0..<500 { retry.record("transfer", "progress", fields: ["received_bytes": "123"]) }
        retry.record("save", "failed", outcome: "failed", terminal: true)
        let newest = recorder.begin(title: "New", track: "new", sha256: nil, library: nil, retryOf: retry.id)
        let export = await recorder.export(newest.id)
        let recent = await recorder.recent()
        #expect(recent.count <= 2)
        #expect(recent.last?.omitted ?? 0 > 0)
        #expect(recent.last?.outcome == "failed")
        #expect(export.contains("\"missing_ancestors\":\"\(parent.id)\""))
        #expect(try Data(contentsOf: directory.appendingPathComponent("attempts.json")).count <= 32_000)
    }

    @Test func errorsNeverExportUntrustedDescriptionsOrUserInfo() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory)
        let context = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: nil)
        let secret = "Bearer forbidden-secret https://user:password@example.invalid/path?token=secret /Users/private/music.wav 192.0.2.1"
        let nested = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: secret])
        context.failure("connection", NSError(domain: secret, code: 5, userInfo: [NSLocalizedDescriptionKey: secret, "Authorization": secret, NSUnderlyingErrorKey: nested]))
        let exported = await recorder.export(context.id)
        for forbidden in ["forbidden-secret", "https://", "/Users/", "192.0.2.1", "password", "Authorization"] {
            #expect(!exported.contains(forbidden))
        }
        #expect(exported.contains("NSURLErrorDomain"))
        #expect(exported.contains("-1001"))
        #expect(exported.contains("description_omitted"))
    }

    @Test func persistenceFailureKeepsBoundedCopyableEvidence() async throws {
        let directory = root()
        try Data("not a directory".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory)
        let context = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: nil)
        context.failure("player", NSError(domain: "AVFoundationErrorDomain", code: -11800), terminal: true)
        let exported = await recorder.export(context.id)
        #expect(exported.contains("\"persistence_failed\":\"true\""))
        #expect(exported.contains("-11800"))
    }

    @Test func cyclicUnderlyingErrorsAreBounded() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory)
        let context = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: nil)
        context.failure("connection", CyclicDiagnosticError(domain: NSPOSIXErrorDomain, code: 61))
        let exported = await recorder.export(context.id)
        #expect(exported.contains("cycle_or_depth_limit"))
        #expect(exported.utf8.count < 10_000)
    }
}
