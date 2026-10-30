import XCTest

final class SharedAudioFlowTests: XCTestCase {
    @MainActor
    func testIndependentSavesSurviveOfflineRelaunch() throws {
        continueAfterFailure = false
        guard let root = ProcessInfo.processInfo.environment["SYNCSTR_V5_FIXTURE_ROOT"] else {
            throw XCTSkip("Install an isolated v5 fixture and set TEST_RUNNER_SYNCSTR_V5_FIXTURE_ROOT")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--v5-fixture", root]
        app.launch()
        openSongs(app)
        let a = app.buttons["TRACK-Aの保存操作"]
        let b = app.buttons["TRACK-Bの保存操作"]
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        XCTAssertTrue(b.exists)
        XCTAssertEqual(a.value as? String, "保存済み")
        XCTAssertEqual(b.value as? String, "保存済み")
        a.tap()
        app.buttons["この端末の保存を解除"].tap()
        let confirmation = app.alerts.buttons["保存を解除"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        XCTAssertEqual(b.value as? String, "保存済み")
        XCTAssertNotEqual(a.value as? String, "保存済み")
        capture(app, "Only A is unsaved; B retains shared audio")
        app.terminate()
        app.launch()
        openSongs(app)
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertEqual(b.value as? String, "保存済み")
        XCTAssertNotEqual(a.value as? String, "保存済み")
        app.buttons.containing(.staticText, identifier: "TRACK-B").firstMatch.tap()
        XCTAssertTrue(app.buttons["player-toggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["再生できません"].exists)
        capture(app, "Offline playback of retained B after relaunch")
        app.terminate()
    }

    @MainActor
    private func openSongs(_ app: XCUIApplication) {
        let songs = app.buttons["曲"].firstMatch
        XCTAssertTrue(songs.waitForExistence(timeout: 10))
        songs.tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
