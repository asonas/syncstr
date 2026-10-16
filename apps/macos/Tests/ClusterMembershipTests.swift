import Foundation
import XCTest
import CryptoKit
import SQLite3
#if os(macOS)
import AudioTags
#endif
#if os(iOS)
@testable import Syncstr
#endif

final class ClusterMembershipTests: XCTestCase {
#if os(macOS)
    func testLocalEvidenceRecoveryKeepsConflictedObjectsAvailableForResolution() async throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMusicStore(root: root)
        try store.prepare()
        let database = try store.database()
        let grant = try fixture.membership.authorize(fixture.client)
        try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: fixture.membership, ownID: fixture.client, name: "Library")
        let source = root.appendingPathComponent("source.mp3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/untagged.mp3"), to: source)
        try AudioTags.writeFile(source, fields: ["ALBUM": "Collection", "COMPILATION": "1"], artwork: nil, mimeType: nil, changeArtwork: false)
        var entry = try await UploadedMusic.entry(file: source, original: source)
        entry.importedAlbum = nil
        var catalog = LocalCatalog(id: grant.cluster, name: "Library", entries: [entry])
        catalog.organize()
        let original = try ClusterSignedChange(id: fixture.change.id, signature: fixture.change.signature, payload: fixture.signingPayload).decode(membership: fixture.membership)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        func signed(_ entry: LocalEntry, previous: [String]) throws -> ClusterSignedChange {
            let action = ClusterChange.Action(kind: .import, entry: entry, organization: catalog.organization, selected: nil)
            let fields: [Any] = [1, original.cluster, original.author, original.grant, previous, entry.sha256, [String](),
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(action))]
            let payload = "syncstr-cluster-change-v1\n" + String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            let bytes = Data(payload.utf8)
            return ClusterSignedChange(id: LocalMusicStore.digest(bytes),
                signature: try key.signature(for: bytes).map { String(format: "%02x", $0) }.joined(), payload: payload)
        }
        let first = try signed(entry, previous: [])
        try database.receiveClusterPage(peer: fixture.host, sequence: 1, signed: first)
        try store.importFile(source, entry: entry)
        try store.save(database.clusterCatalog())
        var competing = entry
        competing.track = Track(id: entry.track.id, title: "Competing title", artist: entry.track.artist,
            album: entry.track.album, albumId: entry.track.albumId, coverArt: entry.track.coverArt,
            duration: entry.track.duration, track: entry.track.track, discNumber: entry.track.discNumber,
            suffix: entry.track.suffix, size: entry.track.size)
        try database.receiveClusterPage(peer: fixture.host, sequence: 2, signed: signed(competing, previous: [first.id]))
        XCTAssertTrue(try XCTUnwrap(database.clusterObjectStates().first).conflicted)
        let retained = try database.clusterCatalog()
        let recovered = try await UploadedMusic.recoverClusterEvidence(retained, store: store)
        XCTAssertEqual(recovered.organization, retained.organization)
        XCTAssertNoThrow(try store.save(recovered, clusterEdits: true))
        XCTAssertTrue(try database.clusterMetadataEdits().isEmpty)
    }
#endif
    func testClusterDeletionExcludesRetainedArtworkWithoutTreatingOfflineAsDeletion() throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try CatalogDatabase(root.appendingPathComponent("catalog.sqlite"))
        let grant = try fixture.membership.authorize(fixture.client)
        try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: fixture.membership, ownID: fixture.client, name: "Library")
        let original = ClusterSignedChange(id: fixture.change.id, signature: fixture.change.signature, payload: fixture.signingPayload)
        let record = try original.decode(membership: fixture.membership)
        try database.receiveClusterPage(peer: fixture.host, sequence: 1, signed: original)
        var catalog = try database.clusterCatalog()
        let images = try AlbumArtworkTests.fixture()
        let image = try XCTUnwrap(images.organization.artwork?.assets[images.blue])
        let album = try XCTUnwrap(catalog.organization?.albums.first?.id)
        try catalog.organization?.chooseArtwork(image, album: album)
        try database.save(catalog)
        XCTAssertNotNil(try CatalogDatabase(root.appendingPathComponent("catalog.sqlite")).clusterCatalog().organization?.coverAsset(for: album))
        let action = ClusterChange.Action(kind: .delete, entry: nil, organization: nil, selected: nil)
        let fields: [Any] = [1, record.cluster, record.author, record.grant, [record.id], record.object, [record.id],
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(action))]
        let payload = "syncstr-cluster-change-v1\n" + String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let data = Data(payload.utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let deletion = ClusterSignedChange(id: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            signature: try key.signature(for: data).map { String(format: "%02x", $0) }.joined(), payload: payload)
        try database.receiveClusterPage(peer: fixture.host, sequence: 2, signed: deletion)
        let deleted = try database.clusterCatalog()
        XCTAssertTrue(deleted.entries.isEmpty)
        XCTAssertTrue(try XCTUnwrap(deleted.organization).tracks.isEmpty)
        XCTAssertNil(deleted.organization?.coverAsset(for: album))
        XCTAssertTrue(deleted.organization?.artwork?.assets.isEmpty ?? true)
    }

    func testInvitationRelayPersistsWithoutSavingItsSecret() throws {
        let fixture = try fixture()
        let grant = try fixture.membership.authorize(fixture.client)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var payload: [String: Any] = ["version": 1, "cluster": grant.cluster, "host": grant.issuer,
            "secret": String(repeating: "a", count: 64), "expires": 1600, "relay": "https://relay.example.net/"]
        func parsed() throws -> ClusterInvitation {
            try ClusterInvitation.parse(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
        }
        let invitation = try parsed()
        try CatalogDatabase(url).enrollCluster(invitation: invitation, grantID: grant.id,
            membership: fixture.membership, ownID: fixture.client, name: "Fixture")
        let registration = try XCTUnwrap(CatalogDatabase(url).clusterRegistration())
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any]
        XCTAssertEqual(encoded?["relay"] as? String, "https://relay.example.net/")
        XCTAssertNil(encoded?["secret"])
        for invalid in ["https://user:password@relay.example.net/", "http://relay.example.net/", "https://relay.example.net/?secret=value",
                        "http://127.0.0.1.relay.example/", "http://127.0.0.1.example.2/"] {
            payload["relay"] = invalid
            XCTAssertThrowsError(try parsed())
        }
    }

    func testFreshInvitationRotatesAndDisablesRelayWithoutReplacingRegistration() throws {
        let fixture = try fixture()
        let grant = try fixture.membership.authorize(fixture.client)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try CatalogDatabase(url)
        for relay in ["https://relay.example.net/", "https://replacement.example.net/", nil] {
            let invitation = ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
                secret: String(repeating: "a", count: 64), expires: 1600, relay: relay)
            try database.enrollCluster(invitation: invitation, grantID: grant.id,
                membership: fixture.membership, ownID: fixture.client, name: "Fixture")
            let restored = try XCTUnwrap(CatalogDatabase(url).clusterRegistration())
            XCTAssertEqual(restored.relay, relay)
            XCTAssertEqual(restored.localGrant, grant.id)
            XCTAssertEqual(restored.membership, fixture.membership)
        }
    }
    func testAutomaticAudioRequiresWifiOrExplicitCellularOptInAndSettingsPersist() throws {
        XCTAssertTrue(ClusterTransferPolicy.permitsAutomaticAudio(online: true, cellular: false, optedIn: false))
        XCTAssertFalse(ClusterTransferPolicy.permitsAutomaticAudio(online: true, cellular: true, optedIn: false))
        XCTAssertTrue(ClusterTransferPolicy.permitsAutomaticAudio(online: true, cellular: true, optedIn: true))
        XCTAssertFalse(ClusterTransferPolicy.permitsAutomaticAudio(online: false, cellular: true, optedIn: true))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let database = try CatalogDatabase(url)
        XCTAssertFalse(try database.clusterAutomaticCellular())
        try database.setClusterAutomaticCellular(true)
        XCTAssertTrue(try CatalogDatabase(url).clusterAutomaticCellular())
    }
    struct Fixture: Decodable {
        let membership: ClusterMembership
        let revoked: ClusterMembership
        let conflict: ClusterMembership
        let host: String
        let client: String
        struct Signature: Decodable { let id: String; let signature: String }
        let change: Signature
        let signingPayload: String
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "cluster-signed", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testAlbumTitleConflictPreservesAffectedRowsWhileOtherObjectsAdvance() throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try CatalogDatabase(root.appendingPathComponent("catalog.sqlite"))
        let grant = try fixture.membership.authorize(fixture.client)
        try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: fixture.membership, ownID: fixture.client, name: "Library")
        let original = ClusterSignedChange(id: fixture.change.id, signature: fixture.change.signature, payload: fixture.signingPayload)
        let record = try original.decode(membership: fixture.membership)
        try database.receiveClusterPage(peer: fixture.host, sequence: 1, signed: original)
        XCTAssertNoThrow(try database.save(database.clusterCatalog()), "Initial signed catalog")
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        func signed(_ entry: LocalEntry, _ organization: AlbumOrganization, previous: String) throws -> ClusterSignedChange {
            let action = ClusterChange.Action(kind: .import, entry: entry, organization: organization, selected: nil)
            let fields: [Any] = [1, record.cluster, record.author, record.grant, [previous], entry.sha256, [String](),
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(action))]
            let payload = "syncstr-cluster-change-v1\n" + String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
            let data = Data(payload.utf8)
            return ClusterSignedChange(id: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                signature: try key.signature(for: data).map { String(format: "%02x", $0) }.joined(), payload: payload)
        }
        var competing = try XCTUnwrap(record.action.entry)
        competing.sha256 = String(repeating: "b", count: 64)
        competing.track.id = "second-track"
        competing.track.coverArt = competing.track.id
        var organization = try XCTUnwrap(record.action.organization)
        organization.tracks[0].sha256 = competing.sha256
        organization.tracks[0].id = competing.track.id
        organization.albums[0].title = "Alternative title"
        let second = try signed(competing, organization, previous: original.id)
        XCTAssertNoThrow(try database.receiveClusterPage(peer: fixture.host, sequence: 2, signed: second), "Competing album title")
        var independent = competing
        independent.sha256 = String(repeating: "c", count: 64)
        independent.track.id = "third-track"
        independent.track.coverArt = independent.track.id
        organization.albums[0].id = "independent-album"
        organization.tracks[0].importedAlbumID = "independent-album"
        organization.tracks[0].id = independent.track.id
        organization.tracks[0].sha256 = independent.sha256
        let third = try signed(independent, organization, previous: second.id)
        XCTAssertNoThrow(try database.receiveClusterPage(peer: fixture.host, sequence: 3, signed: third), "Independent album")
        XCTAssertEqual(Set(try database.clusterCatalog().entries.map(\.sha256)), Set([record.object, independent.sha256]))
        XCTAssertEqual(try database.clusterAlbumConflicts().first?.titles, ["Alternative title", "Fixture Album"])
        XCTAssertEqual(try database.clusterChanges().count, 3)
    }

    func testReceiptAndDownloadCompletionCommitTogether() throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite")
        let database = try CatalogDatabase(url)
        let grant = try fixture.membership.authorize(fixture.client)
        try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: fixture.membership, ownID: fixture.client, name: "Library")
        let signed = ClusterSignedChange(id: fixture.change.id, signature: fixture.change.signature, payload: fixture.signingPayload)
        try database.receiveClusterPage(peer: fixture.host, sequence: 1, signed: signed)
        let entry = try XCTUnwrap(signed.decode(membership: fixture.membership).action.entry)
        let store = LocalMusicStore(root: root)
        let file = store.fileURL(entry)
        try Data("abc".utf8).write(to: file)
        let job = ClusterTransferJob(id: UUID().uuidString, sha256: entry.sha256, source: fixture.host, destination: fixture.client, state: .queued)
        try database.enqueueClusterJob(job)
        try database.beginClusterJob(job.id)
        XCTAssertThrowsError(try database.finishClusterDownload(UUID().uuidString, entry: entry, file: file))
        try store.save(database.clusterCatalog())
        var sql: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &sql), SQLITE_OK)
        defer { sqlite3_close(sql) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(sql, "SELECT COUNT(*) FROM received_files", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_reset(statement)
        try database.finishClusterDownload(job.id, entry: entry, file: file)
        XCTAssertEqual(try CatalogDatabase(url).clusterJobs().first?.state, .complete)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testQueuedOrganizationEditsSurviveRestartAndRetainLaterLocalChanges() throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite")
        let database = try CatalogDatabase(url)
        let grant = try fixture.membership.authorize(fixture.client)
        try database.enrollCluster(invitation: ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer,
            secret: String(repeating: "a", count: 64), expires: 1600), grantID: grant.id,
            membership: fixture.membership, ownID: fixture.client, name: "Library")
        let signed = ClusterSignedChange(id: fixture.change.id, signature: fixture.change.signature, payload: fixture.signingPayload)
        try database.receiveClusterPage(peer: fixture.host, sequence: 1, signed: signed)
        var catalog = try database.clusterCatalog()
        try database.save(catalog)
        let album = try XCTUnwrap(catalog.organization?.albums.first?.id)
        catalog.organization?.set(subject: album, kind: "classification", value: "true")
        catalog.organization?.set(subject: album, kind: "visibility", value: "true")
        try database.save(catalog, clusterEdits: true)
        let sent = try XCTUnwrap(CatalogDatabase(url).clusterMetadataEdits().first)
        XCTAssertTrue(sent.organization.isHidden(album))
        XCTAssertTrue(try CatalogDatabase(url).clusterCatalog().organization?.isHidden(album) == true)
        catalog.organization?.set(subject: album, kind: "classification", value: "false")
        catalog.organization?.set(subject: album, kind: "visibility", value: "false")
        try database.save(catalog, clusterEdits: true)
        let acknowledgement = String(repeating: "d", count: 64)
        try database.finishClusterMetadataEdit(sent, revision: acknowledgement)
        let later = try XCTUnwrap(CatalogDatabase(url).clusterMetadataEdits().first)
        XCTAssertFalse(later.organization.isHidden(album))
        XCTAssertNotEqual(later.id, sent.id)
        XCTAssertEqual(later.parents, [acknowledgement])
        XCTAssertEqual(later.organization.choice(subject: album, kind: "classification")?.value, "false")
        try database.finishClusterMetadataEdit(later, revision: String(repeating: "e", count: 64))
        XCTAssertTrue(try CatalogDatabase(url).clusterMetadataEdits().isEmpty)
        let original = try signed.decode(membership: fixture.membership)
        let competing = try XCTUnwrap(original.action.entry)
        var conflictingOrganization = try XCTUnwrap(original.action.organization)
        conflictingOrganization.albums[0].title = "Concurrent alternative"
        let action = ClusterChange.Action(kind: .import, entry: competing, organization: conflictingOrganization, selected: nil)
        let fields: [Any] = [1, original.cluster, original.author, original.grant, [original.id], original.object, [String](),
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(action))]
        let payload = "syncstr-cluster-change-v1\n" + String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self)
        let bytes = Data(payload.utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let conflict = ClusterSignedChange(id: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            signature: try key.signature(for: bytes).map { String(format: "%02x", $0) }.joined(), payload: payload)
        try database.receiveClusterPage(peer: fixture.host, sequence: 2, signed: conflict)
        XCTAssertTrue(try XCTUnwrap(database.clusterObjectStates().first).conflicted)
        catalog.organization?.set(subject: album, kind: "classification", value: "true")
        XCTAssertThrowsError(try database.save(catalog, clusterEdits: true))
        XCTAssertEqual(try database.snapshot()?.catalog.organization?.choice(subject: album, kind: "classification")?.value, "false")
        XCTAssertTrue(try database.clusterMetadataEdits().isEmpty)
    }

    func testRustGrantsAuthorizeActualMembersAndPreserveRoles() throws {
        let fixture = try fixture()
        XCTAssertTrue(try fixture.membership.authorize(fixture.host, host: true).host)
        XCTAssertFalse(try fixture.membership.authorize(fixture.client).host)
        XCTAssertThrowsError(try fixture.membership.authorize(fixture.client, host: true))
        XCTAssertThrowsError(try fixture.membership.authorize(String(repeating: "1", count: 64)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.membership)) as? [String: Any])
        var grants = try XCTUnwrap(object["grants"] as? [[String: Any]])
        let index = try XCTUnwrap(grants.firstIndex(where: { $0["member"] as? String == fixture.client }))
        grants[index]["host"] = true
        object["grants"] = grants
        let forged = try JSONDecoder().decode(ClusterMembership.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try forged.authorize(fixture.client, host: true))
    }

    func testRustRevocationFreezesKnownGrantsAndDisputedMembersStayDenied() throws {
        let fixture = try fixture()
        XCTAssertThrowsError(try fixture.revoked.authorize(fixture.membership.root))
        XCTAssertEqual(try fixture.revoked.authorize(fixture.host, host: true).member, fixture.host)
        XCTAssertEqual(try fixture.revoked.authorize(fixture.client).member, fixture.client)
        XCTAssertEqual(try fixture.conflict.revocationState().disputed, Set([fixture.membership.root, fixture.host]))
        XCTAssertThrowsError(try fixture.conflict.authorize(fixture.membership.root))
        XCTAssertThrowsError(try fixture.conflict.authorize(fixture.host))
        let untrusted = ClusterMembership(root: String(repeating: "2", count: 64), grants: fixture.membership.grants, revocations: [])
        XCTAssertThrowsError(try untrusted.authorize(fixture.host))
    }

    func testRustChangeUsesExactSignedBytesIncludingFractionalNumberFormatting() throws {
        let fixture = try fixture()
        let signed = ClusterSignedChange(id: fixture.change.id, signature: fixture.change.signature, payload: fixture.signingPayload)
        let change = try signed.decode(membership: fixture.membership)
        XCTAssertEqual(change.action.entry?.track.title, "音楽 / \"fixture\"")
        XCTAssertEqual(change.action.entry?.track.duration, 1)
        XCTAssertTrue(try change.authorized(by: fixture.revoked, history: [change]))
        XCTAssertFalse(try change.authorized(by: fixture.conflict, history: [change]))
        let rewritten = fixture.signingPayload.replacingOccurrences(of: "\"duration\":1.0", with: "\"duration\":1")
        XCTAssertNotEqual(rewritten, fixture.signingPayload)
        XCTAssertThrowsError(try ClusterSignedChange(id: signed.id, signature: signed.signature, payload: rewritten).decode(membership: fixture.membership))
        let restored = try JSONDecoder().decode(ClusterSignedChange.self, from: JSONEncoder().encode(signed))
        XCTAssertEqual(try restored.decode(membership: fixture.membership).id, change.id)
    }

    func testEnrollmentAndSignedPagesSurviveRestartWithoutResettingRevocations() throws {
        let fixture = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("catalog.sqlite")
        let grant = try fixture.membership.authorize(fixture.client)
        let invitation = ClusterInvitation(version: 1, cluster: grant.cluster, host: grant.issuer, secret: String(repeating: "a", count: 64), expires: 1600)
        let signed = ClusterSignedChange(id: fixture.change.id, signature: fixture.change.signature, payload: fixture.signingPayload)
        do {
            let database = try CatalogDatabase(url)
            let entry = try XCTUnwrap(signed.decode(membership: fixture.membership).action.entry)
            try database.save(LocalCatalog(id: "original-local-library", name: "Saved music", entries: [entry]))
            try database.enrollCluster(invitation: invitation, grantID: grant.id, membership: fixture.membership, ownID: fixture.client, name: "My library")
            for _ in 0..<2 { try database.receiveClusterPage(peer: fixture.host, sequence: 1, signed: signed) }
            XCTAssertEqual(try database.snapshot()?.catalog.id, "original-local-library")
        }
        let database = try CatalogDatabase(url)
        XCTAssertEqual(try database.clusterRegistration()?.name, "My library")
        XCTAssertEqual(try database.clusterChanges().count, 1)
        XCTAssertEqual(try database.clusterCursor(fixture.host), 1)
        let damaged = ClusterSignedChange(id: signed.id, signature: String(repeating: "0", count: 128), payload: signed.payload)
        XCTAssertThrowsError(try database.receiveClusterPage(peer: fixture.host, sequence: 2, signed: damaged))
        XCTAssertEqual(try database.clusterCursor(fixture.host), 1)
        try database.authenticateClusterPeer(fixture.host, membership: fixture.revoked)
        XCTAssertEqual(try database.clusterObjectStates().first?.heads.first?.id, signed.id)
        XCTAssertThrowsError(try database.authenticateClusterPeer(fixture.membership.root, membership: fixture.membership))
        XCTAssertThrowsError(try database.enrollCluster(invitation: invitation, grantID: grant.id, membership: fixture.membership, ownID: fixture.client, name: "Stale invitation"))
        XCTAssertEqual(try CatalogDatabase(url).clusterRegistration()?.membership.revocations.count, 1)
    }
}
