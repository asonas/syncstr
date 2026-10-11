import Foundation
import XCTest
import IrohLib

#if os(macOS)
@MainActor
final class ClusterRemoteTests: XCTestCase {
    func testSavedRegistrationDownloadsThroughRelayAndKeepsLanWorkingAfterRelayStops() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = repository.appendingPathComponent("headless/target/debug/syncstr-headless")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build headless with p2p first") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ arguments: [String]) throws -> Data {
            let process = Process(); process.executableURL = binary; process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw LocalMusicError.invalidData }
            return output
        }
        var processes: [Process] = []
        defer { for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() } }
        func start(_ arguments: [String]) throws -> (Process, Data) {
            let process = Process(); process.executableURL = binary; process.arguments = arguments
            let pipe = Pipe(); process.standardOutput = pipe
            try process.run(); processes.append(process)
            let output = pipe.fileHandleForReading.availableData
            guard !output.isEmpty else { throw LocalMusicError.invalidData }
            return (process, output)
        }
        let secrets = CredentialStore(service: "syncstr-relay-test-" + UUID().uuidString)
        let own = try await PeerMusicConnection.publicID(secrets: secrets)
        let state = root.appendingPathComponent("identity"); let data = root.appendingPathComponent("data")
        let host = String(decoding: try run(["peer-init", "--state", state.path]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments = ["--data", data.path, "--peer-state", state.path]
        _ = try run(["cluster-init"] + arguments)
        let allowed = root.appendingPathComponent("allowed.json")
        try JSONEncoder().encode([host, own]).write(to: allowed)
        let (relay, output) = try start(["relay-serve", "--listen", "127.0.0.1:0", "--allowed-ids", allowed.path])
        let details = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let relayURL = "http://" + (try XCTUnwrap(details["listen"] as? String)) + "/"
        _ = try run(["cluster-relay", "--data", data.path, "--url", relayURL])
        let invite = root.appendingPathComponent("invitation.json")
        _ = try run(["cluster-invite"] + arguments + ["--output", invite.path])
        let invitation = try ClusterInvitation.parse(String(decoding: Data(contentsOf: invite), as: UTF8.self))
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.mp3")
        let entry = try await UploadedMusic.entry(file: source, original: source)
        let metadata = root.appendingPathComponent("entry.json")
        try JSONEncoder().encode(entry).write(to: metadata)
        _ = try run(["cluster-import"] + arguments + ["--entry", metadata.path, "--file", source.path])
        let (lan, _) = try start(["cluster-serve"] + arguments)
        let discovery = ClusterDiscovery(); defer { discovery.stop() }
        let address = try await discovery.find(host)
        let store = LocalMusicStore(root: root.appendingPathComponent("received")); try store.prepare()
        try await ClusterSession.enroll(invitation: invitation, address: address, secrets: secrets, database: store.database(), name: "Fixture")
        lan.terminate(); lan.waitUntilExit(); discovery.stop()
        let (remote, _) = try start(["cluster-serve"] + arguments + ["--relay-only"])
        let target = IrohLib.EndpointAddr(id: try IrohLib.EndpointId.fromString(s: host), relayUrl: relayURL, addresses: [])
        let database = try store.database()
        let session = try await ClusterSession.connect(address: target, secrets: secrets, database: database)
        defer { session.close() }
        try await session.reconcile(database: database)
        let selected = try XCTUnwrap(database.clusterCatalog().entries.first)
        try await session.download(selected, store: store, database: database) { _ in }
        XCTAssertEqual(session.selectedPath, "relay")
        XCTAssertEqual(try LocalMusicStore.digest(file: store.fileURL(selected)), entry.sha256)
        XCTAssertEqual(try CatalogDatabase(store.root.appendingPathComponent("catalog.sqlite")).clusterRegistration()?.relay, relayURL)
        session.close(); remote.terminate(); remote.waitUntilExit(); relay.terminate(); relay.waitUntilExit()
        _ = try start(["cluster-serve"] + arguments)
        let network = ClusterNetwork(store: store, secrets: secrets); defer { network.stop() }
        let catalog = try await network.refresh()
        XCTAssertEqual(network.lastPath, "direct")
        XCTAssertEqual(catalog.entries.map(\.sha256), [entry.sha256])
        XCTAssertTrue(store.hasFile(selected))
        try await secrets.remove()
    }
}
#endif
