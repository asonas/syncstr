import XCTest

// Temporary pre-merge acceptance probe; removed before review.
final class WeeklyAcceptanceTests: XCTestCase {
    func testFailsOnceThenPasses() throws {
        let marker = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("weekly-acceptance-retried")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try Data().write(to: marker)
            XCTFail("Temporary ASO-93 flaky acceptance probe")
        }
    }
}
