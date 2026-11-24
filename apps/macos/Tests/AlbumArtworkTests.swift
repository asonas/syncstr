import Foundation
import XCTest
#if os(iOS)
@testable import Syncstr
#endif

final class AlbumArtworkTests: XCTestCase {
    struct Fixture: Decodable {
        var organization: AlbumOrganization
        var blue: String
        var red: String
    }

    static func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "album-artwork", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testConcurrentManualChoicesClearAndReorderedDeliveryRetainImages() throws {
        let fixture = try Self.fixture()
        var local = fixture.organization
        var peer = local
        local.set(subject: "album-a", kind: "artwork", value: fixture.blue)
        peer.set(subject: "album-a", kind: "artwork", value: fixture.red)
        let before = local
        try local.merge(peer)
        XCTAssertTrue(local.hasArtworkConflict("album-a"))
        XCTAssertEqual(local.coverAsset(for: "album-a"), fixture.blue)
        local.set(subject: "album-a", kind: "artwork", value: nil)
        try local.merge(before)
        try local.merge(peer)
        XCTAssertFalse(local.hasArtworkConflict("album-a"))
        XCTAssertEqual(local.coverAsset(for: "album-a"), fixture.blue)
        XCTAssertEqual(local.artwork?.assets.count, 2)
        try local.validate()
    }

    func testConcurrentAcquisitionKeepsLocalCoverUntilManualResolution() throws {
        let fixture = try Self.fixture()
        var local = fixture.organization
        var peer = local
        let red = try XCTUnwrap(local.artwork?.assets[fixture.red])
        try local.captureArtwork(red, track: "track-a", source: "folder", context: "source-context")
        try peer.captureArtwork(try XCTUnwrap(local.artwork?.assets[fixture.blue]), track: "track-a", source: "folder", context: "independent-import")
        try local.merge(peer)
        XCTAssertTrue(local.hasArtworkConflict("album-a"))
        XCTAssertEqual(local.coverAsset(for: "album-a"), fixture.red)
        try local.chooseArtwork(red, album: "album-a")
        XCTAssertFalse(local.hasArtworkConflict("album-a"))
    }
}
