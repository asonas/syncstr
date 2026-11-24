import Foundation
import Testing
import SQLite3

private final class CyclicDiagnosticError: NSError, @unchecked Sendable {
    override var userInfo: [String: Any] { [NSUnderlyingErrorKey: self] }
}

struct PlaybackDiagnosticTests {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func copyingAnAttemptThatWasDroppedReportsNothingToCopy() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory.appendingPathComponent("diagnostics"))
        let attempt = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: nil)
        #expect(await recorder.exportRetained(attempt.id) != nil)
        #expect(await recorder.exportRetained("dropped-attempt") == nil)
    }

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
            _ = try store.database().snapshot()
            Issue.record("Expected the competing writer to block a database write")
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
        recorder.connection("refresh_host_called", fields: ["operation_id": "connection-one"])
        recorder.connection("refresh_host", outcome: "failed", fields: ["operation_id": "connection-one", "reason": "connection_refused"],
            error: NSError(domain: NSPOSIXErrorDomain, code: 61))
        let first = recorder.begin(title: "Fixture", track: "one", sha256: nil, library: "fixture-library")
        first.record("acquisition", "failed", outcome: "failed", terminal: true)
        _ = await recorder.export(first.id)
        let reopened = PlaybackDiagnostics(root: directory)
        _ = await reopened.recent()
        reopened.connection("refresh_host_called", fields: ["operation_id": "connection-two"])
        reopened.connection("refresh_host", outcome: "succeeded", fields: ["operation_id": "connection-two", "reason": "catalog_received"])
        let retry = reopened.begin(title: "Fixture", track: "one", sha256: nil, library: "fixture-library", retryOf: first.id)
        reopened.captureConnections(in: retry)
        let traces = await reopened.recent()
        let events = try #require(traces.first).events
        #expect(events.filter { $0.event == "refresh_host_called" }.count == 2)
        #expect(events.contains { $0.fields["last_failed_reason"] == "connection_refused" })
        #expect(events.contains { $0.fields["last_succeeded_reason"] == "catalog_received" })
        #expect(events.filter { $0.stage == "connection_history" && $0.event != "snapshot" }.allSatisfy { $0.fields["observed_at"] != nil })
        let json = await reopened.export(retry.id)
        #expect(json.contains("connection-one") && json.contains("connection-two"))
    }

    @Test func listAndExportAgreeOnIncompleteAttempts() async throws {
        var trace = PlaybackDiagnosticTrace(id: "attempt", retryOf: nil, title: "Track", started: "2026-01-01T00:00:00Z")
        trace.outcome = "completed"
        #expect(trace.isComplete(persistenceFailed: false))
        #expect(!trace.isComplete(persistenceFailed: true))
        var history = trace
        history.events = [PlaybackDiagnosticEvent(timestamp: "2026-01-01T00:00:00Z", elapsedMS: 0, attemptID: "attempt", sequence: 0,
            stage: "connection_history", event: "summary", outcome: "observed", fields: ["history_omitted": "3"])]
        #expect(!history.isComplete(persistenceFailed: false))
        var omitted = trace
        omitted.omitted = 1
        #expect(!omitted.isComplete(persistenceFailed: false))
        var interrupted = trace
        interrupted.outcome = "interrupted"
        #expect(!interrupted.isComplete(persistenceFailed: false))

        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode([history]).write(to: directory.appendingPathComponent("attempts.json"))
        let recorder = PlaybackDiagnostics(root: directory)
        let listed = try #require(await recorder.recent().first)
        let exported = await recorder.export("attempt")
        #expect(!listed.isComplete(persistenceFailed: await recorder.hasPersistenceFailure()))
        #expect(exported.contains("\"complete\":\"false\""))
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

    @MainActor @Test func libraryRetriesLinkAttemptsAndPreserveFailedCopyTarget() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = PlaybackDiagnostics(root: directory.appendingPathComponent("diagnostics"))
        let library = Library(diagnostics: recorder, localStore: LocalMusicStore(root: directory.appendingPathComponent("music")))
        let entry = LocalEntry(track: Track(id: "track-one", title: "Fixture", artist: "Artist", duration: 20, suffix: "wav", size: 4),
            sha256: String(repeating: "a", count: 64), artwork: nil)
        try showHostCatalog(LocalCatalog(id: "fixture-library", name: "Fixture", entries: [entry]), in: library)
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
        #expect(json.contains("disconnected"))
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
