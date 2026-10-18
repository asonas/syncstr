import Foundation

struct PlaybackDiagnosticEvent: Codable, Sendable {
    let timestamp: String
    let elapsedMS: Double
    let attemptID: String
    let sequence: Int
    let stage: String
    let event: String
    let outcome: String
    let fields: [String: String]
}

struct PlaybackDiagnosticTrace: Codable, Identifiable, Sendable {
    let id: String
    let retryOf: String?
    let title: String
    let started: String
    var outcome = "active"
    var lastStage = "request"
    var omitted = 0
    var omittedByStage: [String: Int] = [:]
    var events: [PlaybackDiagnosticEvent] = []
    var bytes = 0
}

struct ConnectionDiagnosticEvent: Codable, Sendable {
    let id: String
    let timestamp: String
    let event: String
    let outcome: String
    let fields: [String: String]
}

private struct PlaybackDiagnosticArchive: Codable {
    var traces: [PlaybackDiagnosticTrace]
    var connections: [ConnectionDiagnosticEvent]
    var connectionOmitted: Int
    var lastConnections: [String: ConnectionDiagnosticEvent]
}

/// The lock protects bounded memory only; the serial writer owns all disk access.
final class PlaybackDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "as.ason.syncstr.playback-diagnostics", qos: .utility)
    private let root: URL
    private let limit: Int
    private let attemptLimit: Int
    private var traces: [PlaybackDiagnosticTrace] = []
    private var connections: [ConnectionDiagnosticEvent] = []
    private var connectionOmitted = 0
    private var lastConnections: [String: ConnectionDiagnosticEvent] = [:]
    private var scheduled = false
    private var persistenceFailed = false

    init(root: URL, limit: Int = 5_000_000, attemptLimit: Int = 20) {
        self.root = root
        self.limit = limit
        self.attemptLimit = attemptLimit
        writer.async { [self] in
            do {
                let file = root.appendingPathComponent("attempts.json")
                if FileManager.default.fileExists(atPath: file.path) {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= limit else { throw CocoaError(.fileReadTooLarge) }
                    let data = try Data(contentsOf: file)
                    let decoder = JSONDecoder()
                    let archive: PlaybackDiagnosticArchive
                    if data.first == UInt8(ascii: "[") {
                        archive = PlaybackDiagnosticArchive(traces: try decoder.decode([PlaybackDiagnosticTrace].self, from: data),
                            connections: [], connectionOmitted: 0, lastConnections: [:])
                    } else { archive = try decoder.decode(PlaybackDiagnosticArchive.self, from: data) }
                    var previous = archive.traces
                    for index in previous.indices where previous[index].outcome == "active" {
                        previous[index].outcome = "interrupted"
                        previous[index].omitted += 1
                    }
                    lock.lock()
                    traces = previous + traces
                    connections = archive.connections + connections
                    connectionOmitted += archive.connectionOmitted
                    lastConnections = archive.lastConnections.merging(lastConnections) { _, new in new }
                    trimConnections()
                    trim()
                    lock.unlock()
                }
            } catch { lock.lock(); persistenceFailed = true; lock.unlock() }
        }
    }

    static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    func begin(title: String, track: String, sha256: String?, library: String?, retryOf: String? = nil) -> PlaybackDiagnosticContext {
        let id = UUID().uuidString
        let context = PlaybackDiagnosticContext(id: id, started: ProcessInfo.processInfo.systemUptime, recorder: self)
        lock.lock()
        traces.append(PlaybackDiagnosticTrace(id: id, retryOf: retryOf, title: String(title.prefix(512)), started: Self.timestamp()))
        trim()
        lock.unlock()
        context.record("request", "playback", fields: ["title": title, "track_id": track, "sha256": sha256 ?? "unknown",
            "library_id": library ?? "unknown", "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString])
        captureConnections(in: context)
        return context
    }

    fileprivate func append(_ context: PlaybackDiagnosticContext, stage: String, event: String, outcome: String, fields: [String: String], terminal: Bool) {
        lock.lock()
        if let index = traces.firstIndex(where: { $0.id == context.id }) {
            let row = PlaybackDiagnosticEvent(timestamp: Self.timestamp(), elapsedMS: max(0, (ProcessInfo.processInfo.systemUptime - context.started) * 1000),
                attemptID: context.id, sequence: traces[index].events.count + traces[index].omitted + 1,
                stage: stage, event: event, outcome: outcome, fields: fields.mapValues { String($0.prefix(512)) })
            let size = (try? JSONEncoder().encode(row).count) ?? 4096
            traces[index].lastStage = stage
            if terminal && traces[index].outcome == "active" { traces[index].outcome = outcome }
            // Reserve space for terminal metadata even for a single oversized attempt.
            if traces[index].bytes + size < min(200_000, limit / 2) {
                traces[index].events.append(row)
                traces[index].bytes += size
            } else {
                traces[index].omitted += 1
                traces[index].omittedByStage[stage, default: 0] += 1
            }
            trim()
        }
        if !scheduled {
            scheduled = true
            writer.async { [self] in persist() }
        }
        lock.unlock()
    }

    func connection(_ event: String, outcome: String = "observed", fields: [String: String] = [:], error: Error? = nil) {
        var fields = fields
        if let error { fields.merge(PlaybackDiagnosticContext.errorFields(error)) { _, new in new } }
        let row = ConnectionDiagnosticEvent(id: UUID().uuidString, timestamp: Self.timestamp(), event: event,
            outcome: outcome, fields: fields.mapValues { String($0.prefix(512)) })
        lock.lock()
        connections.append(row)
        if ["succeeded", "failed", "disconnected"].contains(outcome) { lastConnections[outcome] = row }
        trimConnections()
        trim()
        if !scheduled { scheduled = true; writer.async { [self] in persist() } }
        lock.unlock()
    }

    private func trimConnections() {
        let budget = min(128_000, limit / 8)
        while connections.count > 128 || ((try? JSONEncoder().encode(connections).count) ?? 0) > budget {
            guard !connections.isEmpty else { break }
            connections.removeFirst()
            connectionOmitted += 1
        }
    }

    func captureConnections(in context: PlaybackDiagnosticContext) {
        lock.lock()
        let snapshot = connections
        let last = lastConnections
        let omitted = connectionOmitted
        let copied = Set(traces.first(where: { $0.id == context.id })?.events.compactMap { $0.fields["connection_event_id"] } ?? [])
        lock.unlock()
        for row in snapshot where !copied.contains(row.id) {
            var fields = row.fields
            fields["connection_event_id"] = row.id
            fields["observed_at"] = row.timestamp
            fields["observation_scope"] = "preceding_connection_history"
            context.record("connection_history", row.event, outcome: row.outcome, fields: fields)
        }
        var summary = ["history_omitted": String(omitted)]
        summary["last_success_peer_id"] = last["succeeded"]?.fields["saved_peer_id"] ?? "not_observed"
        summary["last_success_catalog_id"] = last["succeeded"]?.fields["remote_catalog_id"] ?? "not_observed"
        for outcome in ["succeeded", "failed", "disconnected"] {
            summary["last_" + outcome + "_at"] = last[outcome]?.timestamp ?? "not_observed"
            summary["last_" + outcome + "_event"] = last[outcome]?.event ?? "not_observed"
            summary["last_" + outcome + "_reason"] = last[outcome]?.fields["reason"] ?? "not_observed"
        }
        context.record("connection_history", "snapshot", fields: summary)
    }

    private func trim() {
        let connectionBytes = ((try? JSONEncoder().encode(connections).count) ?? 0)
            + ((try? JSONEncoder().encode(lastConnections).count) ?? 0)
        while traces.count > attemptLimit || (traces.count > 1 && traces.reduce(0, { $0 + $1.bytes + 2048 }) > limit - 4096 - connectionBytes) {
            let index = traces.dropLast().firstIndex(where: { $0.outcome != "active" }) ?? 0
            traces.remove(at: index)
        }
    }

    private func persist() {
        lock.lock()
        let snapshot = PlaybackDiagnosticArchive(traces: traces, connections: connections, connectionOmitted: connectionOmitted, lastConnections: lastConnections)
        scheduled = false
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("attempts.json"), options: .atomic)
        } catch { lock.lock(); persistenceFailed = true; lock.unlock() }
    }

    func recent() async -> [PlaybackDiagnosticTrace] {
        await withCheckedContinuation { continuation in
            writer.async { [self] in
                lock.lock(); let snapshot = traces; lock.unlock()
                continuation.resume(returning: snapshot.reversed())
            }
        }
    }

    func hasPersistenceFailure() async -> Bool {
        await withCheckedContinuation { continuation in
            writer.async { [self] in
                lock.lock(); let failed = persistenceFailed; lock.unlock()
                continuation.resume(returning: failed)
            }
        }
    }

    func export(_ id: String) async -> String {
        await withCheckedContinuation { continuation in
            writer.async { [self] in
                lock.lock(); let snapshot = traces; let failed = persistenceFailed; lock.unlock()
                var chain: [PlaybackDiagnosticTrace] = []
                var missing: [String] = []
                var next: String? = id
                var visited = Set<String>()
                while let current = next, visited.insert(current).inserted {
                    guard let trace = snapshot.first(where: { $0.id == current }) else { missing.append(current); break }
                    chain.append(trace); next = trace.retryOf
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                func line<T: Encodable>(_ value: T) -> String {
                    (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? "{}"
                }
                var rows = [line(["schema_version": "2", "exported_at": Self.timestamp(), "selected_attempt": id,
                    "missing_ancestors": missing.joined(separator: ","), "persistence_failed": String(failed)])]
                for trace in chain.reversed() {
                    let historyIncomplete = trace.events.contains {
                        $0.stage == "connection_history" && (Int($0.fields["history_omitted"] ?? "0") ?? 0) > 0
                    }
                    rows.append(line(["attempt_id": trace.id, "retry_of": trace.retryOf ?? "", "title": trace.title,
                        "outcome": trace.outcome, "last_stage": trace.lastStage, "omitted_records": String(trace.omitted),
                        "omitted_by_stage": line(trace.omittedByStage),
                        "in_progress": String(trace.outcome == "active"), "complete": String(trace.omitted == 0 && !historyIncomplete && !failed && trace.outcome != "interrupted")]))
                    rows += trace.events.map(line)
                }
                continuation.resume(returning: rows.joined(separator: "\n") + "\n")
            }
        }
    }
}

struct PlaybackDiagnosticContext: Sendable {
    let id: String
    let started: TimeInterval
    let recorder: PlaybackDiagnostics
    var candidate: String? = nil

    func source(_ ordinal: Int, peer: String) -> Self {
        var result = self
        result.candidate = "\(id)/\(ordinal)"
        result.record("selection", "candidate", fields: ["ordinal": String(ordinal), "device_id": peer])
        return result
    }

    func record(_ stage: String, _ event: String, outcome: String = "observed", fields: [String: String] = [:], terminal: Bool = false) {
        var fields = fields
        if let candidate { fields["candidate_operation_id"] = candidate }
        recorder.append(self, stage: stage, event: event, outcome: outcome, fields: fields, terminal: terminal)
    }

    func failure(_ stage: String, _ error: Error, terminal: Bool = false) {
        record(stage, "error", outcome: error is CancellationError ? "cancelled" : "failed", fields: Self.errorFields(error), terminal: terminal)
    }

    static func errorFields(_ error: Error) -> [String: String] {
        var fields: [String: String] = [:]
        var current: NSError? = error as NSError
        var visited = Set<ObjectIdentifier>()
        var depth = 0
        while let value = current, depth < 5, visited.insert(ObjectIdentifier(value)).inserted {
            let prefix = depth == 0 ? "error" : "underlying_\(depth)"
            fields[prefix + "_type"] = depth == 0 ? String(describing: type(of: error)) : "NSError"
            let safeDomains = [NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, "AVFoundationErrorDomain", "NSOSStatusErrorDomain", "Syncstr.CatalogDatabase"]
            fields[prefix + "_domain"] = safeDomains.contains(value.domain) || value.domain == "IrohLib.IrohError" || (depth == 0 && error is LocalMusicError) ? value.domain : "omitted_untrusted_domain"
            fields[prefix + "_code"] = String(value.code)
            if value.domain == "Syncstr.CatalogDatabase" {
                if let operation = value.userInfo["database_operation"] as? String,
                   ["open", "BEGIN", "COMMIT", "ROLLBACK", "SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "PRAGMA", "other"].contains(operation) {
                    fields[prefix + "_database_operation"] = operation
                }
                if value.code == 5 { fields[prefix + "_category"] = "database_busy" }
                if value.code == 6 { fields[prefix + "_category"] = "database_locked" }
            }
            fields[prefix + "_description_omitted"] = "free_form_description_not_safe"
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        if let local = error as? LocalMusicError {
            fields["error_description"] = local.errorDescription
            fields.removeValue(forKey: "error_description_omitted")
            fields["error_category"] = String(describing: local)
        }
        if current != nil { fields["underlying_omitted"] = "cycle_or_depth_limit" }
        if let keychain = error as? KeychainError {
            fields["keychain_osstatus"] = String(keychain.status)
        }
        return fields
    }

    func file(_ url: URL, role: String, stage: String = "local") {
        var fields = ["role": role, "exists": String(FileManager.default.fileExists(atPath: url.path)),
            "readable": String(FileManager.default.isReadableFile(atPath: url.path))]
        do { fields["size"] = String((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0) }
        catch { failure(stage, error) }
        record(stage, "file", fields: fields)
    }
}

#if os(macOS)
import SwiftUI
import AppKit

struct PlaybackDiagnosticCopyButton: View {
    let attemptID: String
    let recorder: PlaybackDiagnostics
    @State private var result: String?
    @State private var copying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("診断ログをコピー") {
                copying = true
                let selected = attemptID
                Task {
                    let json = await recorder.export(selected)
                    NSPasteboard.general.clearContents()
                    result = NSPasteboard.general.setString(json, forType: .string) ? "コピーしました" : "コピーできませんでした"
                    copying = false
                }
            }.disabled(copying)
            if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct PlaybackDiagnosticSettings: View {
    let recorder: PlaybackDiagnostics
    @State private var traces: [PlaybackDiagnosticTrace] = []
    @State private var selected: String?
    @State private var persistenceFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("再生診断").font(.headline)
                Spacer()
                Button("更新") { Task {
                    traces = await recorder.recent()
                    persistenceFailed = await recorder.hasPersistenceFailure()
                } }
            }
            if persistenceFailed {
                Text("診断ログを保存できませんでした。コピーできる記録が一部に限られる場合があります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if traces.isEmpty {
                Text("再生の記録はまだありません。").foregroundStyle(.secondary)
            } else {
                Picker("再生の試行", selection: $selected) {
                    Text("試行を選択").tag(String?.none)
                    ForEach(traces) { trace in
                        Text("\(trace.started) — \(trace.title)").tag(Optional(trace.id))
                    }
                }
                if let trace = traces.first(where: { $0.id == selected }) {
                    Text("\(outcome(trace.outcome))・\(trace.lastStage)").font(.caption)
                    if trace.omitted > 0 { Text("一部の記録がありません（\(trace.omitted)件）。").font(.caption) }
                    PlaybackDiagnosticCopyButton(attemptID: trace.id, recorder: recorder).id(trace.id)
                }
            }
            Text("直近20試行・最大5 MBをこのMacに保存します。コピーには曲名と端末の識別情報が含まれます。")
                .font(.caption).foregroundStyle(.secondary)
        }.task {
            traces = await recorder.recent()
            selected = traces.first?.id
            persistenceFailed = await recorder.hasPersistenceFailure()
        }
    }

    private func outcome(_ value: String) -> String {
        switch value {
        case "active": "再生中・取得中"
        case "failed": "失敗"
        case "completed": "再生完了"
        case "interrupted": "アプリ終了により中断"
        case "cancelled": "キャンセル"
        default: "停止"
        }
    }
}
#endif
