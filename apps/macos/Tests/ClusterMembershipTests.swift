import Foundation
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

final class ClusterMembershipTests: XCTestCase {
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
