import Foundation
import XCTest
import SQLite3
import AudioTags

@MainActor
final class ClusterTransferTests: XCTestCase {
    func testNativeEnrollmentReconciliationAndVerifiedDownloadSurviveRestart() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let binary = ProcessInfo.processInfo.environment["SYNCSTR_HEADLESS_TEST_BINARY"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent("headless/target/debug/syncstr-headless")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build headless with --features p2p before running interoperability tests")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = binary; process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                XCTFail(String(decoding: output, as: UTF8.self))
                throw LocalMusicError.invalidData
            }
        }
        let peer = root.appendingPathComponent("peer")
        let data = root.appendingPathComponent("data")
        let invitationURL = root.appendingPathComponent("invitation.json")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.mp3")
        let entry = try await UploadedMusic.entry(file: source, original: source)
        let images = try AlbumArtworkTests.fixture()
        let blue = try XCTUnwrap(images.organization.artwork?.assets[images.blue])
        let red = try XCTUnwrap(images.organization.artwork?.assets[images.red])
        let metadata = root.appendingPathComponent("entry.json")
        try JSONEncoder().encode(entry).write(to: metadata)
        try run(["peer-init", "--state", peer.path])
        let arguments = ["--data", data.path, "--peer-state", peer.path]
        try run(["cluster-init"] + arguments)
        try run(["cluster-invite"] + arguments + ["--output", invitationURL.path])
        let hostInvitation = root.appendingPathComponent("host-invitation.json")
        try run(["cluster-invite"] + arguments + ["--library-host", "--output", hostInvitation.path])
        let invitation = try ClusterInvitation.parse(String(decoding: Data(contentsOf: invitationURL), as: UTF8.self))
        let process = Process()
        process.executableURL = binary; process.arguments = ["cluster-serve"] + arguments
        process.standardOutput = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let discovery = ClusterDiscovery()
        defer { discovery.stop() }
        let address = try await discovery.find(invitation.host)
        let secondPeer = root.appendingPathComponent("second-peer")
        let secondData = root.appendingPathComponent("second-data")
        let secondArguments = ["--data", secondData.path, "--peer-state", secondPeer.path]
        try run(["peer-init", "--state", secondPeer.path])
        try run(["cluster-join"] + secondArguments + ["--invitation", hostInvitation.path])
        let second = Process()
        second.executableURL = binary; second.arguments = ["cluster-serve"] + secondArguments
        second.standardOutput = Pipe()
        try second.run()
        defer { if second.isRunning { second.terminate(); second.waitUntilExit() } }
        let secrets = CredentialStore(service: "syncstr-cluster-test-" + UUID().uuidString)
        let store = LocalMusicStore(root: root.appendingPathComponent("received"))
        try store.prepare()
        let databaseURL = store.root.appendingPathComponent("catalog.sqlite")
        do {
            let database = try CatalogDatabase(databaseURL)
            try await ClusterSession.enroll(invitation: invitation, address: address, secrets: secrets, database: database, name: "Fixture library")
            let session = try await ClusterSession.connect(address: address, secrets: secrets, database: database)
            defer { session.close() }
            var imported = LocalCatalog(id: invitation.cluster, name: "Fixture", entries: [entry])
            imported.organize()
            try imported.organization?.captureArtwork(blue, track: entry.track.id, source: "music", context: "exact-file")
            for _ in 0..<2 {
                try await session.upload(entry: entry, organization: XCTUnwrap(imported.organization), parents: [], file: source) { _ in }
            }
            try await session.reconcile(database: database)
            let metadataOnly = try database.clusterCatalog()
            let coverAlbum = try XCTUnwrap(metadataOnly.organization?.albumID(for: entry.track.id))
            XCTAssertEqual(metadataOnly.organization?.coverAsset(for: coverAlbum), images.blue)
            XCTAssertEqual(metadataOnly.organization?.artwork?.assets[images.blue], blue)
            XCTAssertFalse(store.hasFile(entry))
            try store.save(metadataOnly)
            XCTAssertEqual(try LocalMusicStore(root: store.root).load()?.organization?.coverAsset(for: coverAlbum), images.blue)
            let states = try database.clusterObjectStates()
            XCTAssertEqual(states.map(\.object), [entry.sha256])
            let selected = try XCTUnwrap(states.first?.selected(in: database.clusterChanges())?.action.entry)
            let cache = LocalMusicStore(root: root.appendingPathComponent("playback-cache"))
            try await session.download(selected, store: cache, database: database, cacheOnly: true) { _ in }
            XCTAssertEqual(try LocalMusicStore.digest(file: cache.fileURL(selected)), entry.sha256)
            XCTAssertFalse(store.hasFile(selected))
            XCTAssertTrue(try database.clusterJobs().isEmpty)
            try await session.download(selected, store: store, database: database) { _ in }
            XCTAssertEqual(try database.clusterJobs().map(\.state), [.complete])
            XCTAssertEqual(try LocalMusicStore.digest(file: store.fileURL(selected)), entry.sha256)
            try store.save(database.clusterCatalog())
        }
        let restored = try CatalogDatabase(databaseURL)
        XCTAssertEqual(try restored.clusterRegistration()?.name, "Fixture library")
        XCTAssertEqual(try restored.clusterCursor(invitation.host), 1)
        let session = try await ClusterSession.connect(address: address, secrets: secrets, database: restored)
        defer { session.close() }
        try await session.reconcile(database: restored)
        XCTAssertEqual(try restored.clusterChanges().count, 1)
        XCTAssertTrue(store.hasFile(entry))
        session.close()
        var editedCatalog = try XCTUnwrap(store.load())
        let album = try XCTUnwrap(editedCatalog.organization?.albumID(for: entry.track.id))
        editedCatalog.organization?.set(subject: album, kind: "classification", value: "true")
        editedCatalog.organization?.set(subject: album, kind: "visibility", value: "true")
        try store.save(editedCatalog, clusterEdits: true)
        XCTAssertEqual(try CatalogDatabase(databaseURL).clusterMetadataEdits().count, 1)
        let metadataNetwork = ClusterNetwork(store: store, secrets: secrets)
        try await metadataNetwork.syncMetadata()
        let edited = try await metadataNetwork.refresh()
        metadataNetwork.stop()
        XCTAssertTrue(try CatalogDatabase(databaseURL).clusterMetadataEdits().isEmpty)
        XCTAssertEqual(edited.organization?.choice(subject: album, kind: "classification")?.value, "true")
        XCTAssertTrue(edited.organization?.isHidden(album) == true)
        let storedBytes = try Data(contentsOf: store.fileURL(entry))
        let storedDate = try store.fileURL(entry).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let jobs = try restored.clusterJobs().count
        var chosen = edited
        try chosen.organization?.chooseArtwork(red, album: album)
        try store.save(chosen, clusterEdits: true)
        let covers = ClusterNetwork(store: store, secrets: secrets)
        defer { covers.stop() }
        try await covers.syncMetadata()
        let manual = try await covers.refresh()
        XCTAssertEqual(manual.organization?.coverAsset(for: album), images.red)
        var cleared = manual
        cleared.organization?.set(subject: album, kind: "artwork", value: nil)
        try store.save(cleared, clusterEdits: true)
        try await covers.syncMetadata()
        let automatic = try await covers.refresh()
        XCTAssertEqual(automatic.organization?.coverAsset(for: album), images.blue)
        var higherPriority = automatic
        try higherPriority.organization?.captureArtwork(red, track: entry.track.id, source: "embedded", context: entry.sha256)
        try store.save(higherPriority, clusterEdits: true)
        try await covers.syncMetadata()
        let higherPriorityCatalog = try await covers.refresh()
        XCTAssertEqual(higherPriorityCatalog.organization?.coverAsset(for: album), images.red)
        XCTAssertEqual(try restored.clusterJobs().count, jobs)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(entry)), storedBytes)
        XCTAssertEqual(try store.fileURL(entry).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, storedDate)
        try FileManager.default.removeItem(at: store.fileURL(entry))
        let invalid = root.appendingPathComponent("invalid.mp3")
        try Data("not audio".utf8).write(to: invalid)
        let transfer = LocalTransfer(store: store, peerSecrets: secrets,
            peerPairing: CredentialStore(service: "syncstr-cluster-test-pair-" + UUID().uuidString))
        defer { transfer.cancel() }
        await transfer.restorePeer()
        transfer.importCluster([source, invalid])
        for _ in 0..<600 {
            if !transfer.busy { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(transfer.busy, transfer.status ?? "")
        let batch = try XCTUnwrap(transfer.clusterBatches.first)
        XCTAssertEqual(batch.items.map(\.state), [.stored, .failed])
        XCTAssertEqual(batch.awaitingDecision.count, 1)
        XCTAssertEqual(try CatalogDatabase(databaseURL).clusterBatches().first?.awaitingDecision.count, 1)
        XCTAssertTrue(store.hasFile(entry))
        transfer.decideClusterCopies(batchID: batch.id, keep: false)
        XCTAssertFalse(store.hasFile(entry))
        XCTAssertEqual(try LocalMusicStore.digest(file: source), entry.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        let pendingCopy = root.appendingPathComponent("pending.mp3")
        try FileManager.default.copyItem(at: source, to: pendingCopy)
        try store.importFile(pendingCopy, entry: entry)
        var queued = try XCTUnwrap(batch.items.first)
        queued.state = .queued
        queued.createdCopy = false
        queued.localCopy = .keep
        let resumedIDs = [UUID().uuidString, UUID().uuidString]
        for id in resumedIDs {
            try restored.saveClusterBatch(ClusterImportBatch(id: id, host: batch.host, items: [queued]))
        }
        let rejectedEdit = ClusterMetadataEdit(id: UUID().uuidString, entry: entry,
            organization: try XCTUnwrap(store.load()?.organization).forClusterObject(entry.sha256),
            parents: [String(repeating: "f", count: 64)])
        var sql: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &sql), SQLITE_OK)
        let payload = String(decoding: try JSONEncoder().encode(rejectedEdit), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(sqlite3_exec(sql, "INSERT INTO cluster_metadata_queue VALUES ('\(entry.sha256)', '\(payload)')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(sql)
        transfer.connectCluster()
        for _ in 0..<600 {
            if !transfer.busy { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(transfer.busy, transfer.status ?? "")
        let resumed = try CatalogDatabase(databaseURL).clusterBatches().filter { resumedIDs.contains($0.id) }
        XCTAssertEqual(resumed.count, 2)
        XCTAssertTrue(resumed.allSatisfy { $0.items.allSatisfy { $0.state == .stored } }, transfer.status ?? "")
        XCTAssertTrue(transfer.connected, transfer.status ?? "")
        XCTAssertEqual(try restored.clusterMetadataEdits().map(\.id), [rejectedEdit.id])
        transfer.cancel()
        try FileManager.default.removeItem(at: store.fileURL(entry))
        let replica = secondData.appendingPathComponent("objects").appendingPathComponent(entry.sha256 + ".mp3")
        for _ in 0..<120 {
            if FileManager.default.fileExists(atPath: replica.path) { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: replica.path), "The second host must have a verified replica before the first stops")
        process.terminate(); process.waitUntilExit()
        let network = ClusterNetwork(store: store, secrets: secrets)
        defer { network.stop() }
        let catalog = try await network.refresh()
        XCTAssertEqual(catalog.entries.map(\.sha256), [entry.sha256])
        XCTAssertEqual(catalog.organization?.coverAsset(for: album), images.red)
        XCTAssertEqual(catalog.organization?.artwork?.assets[images.red], red)
        try await network.download(object: entry.sha256) { _ in }
        let additionalFile = root.appendingPathComponent("another.mp3")
        let additionalBytes = Data("additional audio fixture".utf8)
        try additionalBytes.write(to: additionalFile)
        let additional = LocalEntry(track: Track(id: "additional", title: "Additional", artist: "Fixture", suffix: "mp3", size: UInt64(additionalBytes.count)),
            sha256: LocalMusicStore.digest(additionalBytes), artwork: nil)
        var additionalCatalog = LocalCatalog(id: invitation.cluster, name: "Fixture", entries: [additional])
        additionalCatalog.organize()
        let recipient = try await network.upload(entry: additional, organization: XCTUnwrap(additionalCatalog.organization), parents: [],
            host: invitation.host, file: additionalFile) { _ in }
        XCTAssertNotEqual(recipient, invitation.host)
        var laterCatalog = try XCTUnwrap(store.load())
        let additionalAlbum = try XCTUnwrap(laterCatalog.organization?.albumID(for: additional.track.id))
        laterCatalog.organization?.set(subject: additionalAlbum, kind: "classification", value: "true")
        try store.save(laterCatalog, clusterEdits: true)
        XCTAssertEqual(try restored.clusterMetadataEdits().count, 2)
        do {
            try await network.syncMetadata()
            XCTFail("The rejected edit must remain pending")
        } catch LocalMusicError.clusterNeedsAttention {}
        XCTAssertEqual(try restored.clusterMetadataEdits().map(\.id), [rejectedEdit.id], "An unrelated edit must be acknowledged despite the first rejection")
        let reconciled = try await network.refresh()
        XCTAssertEqual(reconciled.organization?.choice(subject: additionalAlbum, kind: "classification")?.value, "true")
        // Only the surviving host has these bytes; the client requests tags.
        let legacyFile = root.appendingPathComponent("legacy.mp3")
        try FileManager.default.copyItem(at: source, to: legacyFile)
        try AudioTags.writeFile(legacyFile, fields: ["ALBUM": "Replica compilation", "COMPILATION": "1"],
            artwork: nil, mimeType: nil, changeArtwork: false)
        XCTAssertEqual(try AudioTags.readFile(legacyFile)["COMPILATION"] as? [String], ["1"])
        var legacy = try await UploadedMusic.entry(file: legacyFile, original: legacyFile)
        legacy.importedAlbum = nil
        let otherFile = root.appendingPathComponent("legacy-other.mp3")
        try FileManager.default.copyItem(at: legacyFile, to: otherFile)
        try AudioTags.writeFile(otherFile, fields: ["ARTIST": "Another artist"], artwork: nil, mimeType: nil, changeArtwork: false)
        var other = try await UploadedMusic.entry(file: otherFile, original: otherFile)
        other.importedAlbum = nil
        var legacyCatalog = LocalCatalog(id: invitation.cluster, name: "Fixture", entries: [legacy, other])
        legacyCatalog.organize(folders: [legacy.track.id: "Collection", other.track.id: "Collection"])
        try legacyCatalog.organization?.captureArtwork(blue, track: legacy.track.id, source: "music", context: legacy.sha256)
        let context = legacyCatalog.organization?.tracks.first?.importContext
        _ = try await network.upload(entry: legacy, organization: XCTUnwrap(legacyCatalog.organization), parents: [],
            host: recipient, file: legacyFile) { _ in }
        _ = try await network.upload(entry: other, organization: XCTUnwrap(legacyCatalog.organization), parents: [],
            host: recipient, file: otherFile) { _ in }
        XCTAssertNil(try restored.clusterCatalog().organization?.tracks.first { $0.sha256 == legacy.sha256 }?.imported.tagValues)
        XCTAssertFalse(try XCTUnwrap(restored.clusterObjectStates().first { $0.object == legacy.sha256 }).conflicted)
        let recovered = try await network.refresh()
        let evidence = try XCTUnwrap(recovered.organization?.tracks.first { $0.sha256 == legacy.sha256 })
        XCTAssertEqual(evidence.imported.compilationValues, ["1"], String(describing: evidence.imported.tagValues))
        XCTAssertEqual(evidence.importContext, context)
        XCTAssertFalse(store.hasFile(legacy))
        XCTAssertFalse(store.hasFile(other))
        let recoveredAlbum = try XCTUnwrap(recovered.organization?.albumID(for: legacy.track.id))
        XCTAssertEqual(recovered.organization?.albumID(for: other.track.id), recoveredAlbum)
        XCTAssertEqual(recovered.organization?.coverAsset(for: recoveredAlbum), images.blue)
        XCTAssertEqual(recovered.organization?.tracks.filter { recovered.organization?.albumID(for: $0.id) == recoveredAlbum }.count, 2)
        second.terminate(); second.waitUntilExit()
        XCTAssertEqual(try LocalMusicStore.digest(file: store.fileURL(entry)), entry.sha256)
        XCTAssertEqual(try store.load()?.entries.count, 4)
        XCTAssertEqual(try LocalMusicStore.digest(file: source), entry.sha256)
        try await secrets.remove()
    }
}
