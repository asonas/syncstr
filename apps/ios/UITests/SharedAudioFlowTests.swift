import XCTest

final class SharedAudioFlowTests: XCTestCase {
    @MainActor
    func testIndependentSavesSurviveOfflineRelaunch() throws {
        continueAfterFailure = false
        guard let root = ProcessInfo.processInfo.environment["SYNCSTR_V5_FIXTURE_ROOT"] else {
            XCTFail("Install an isolated v5 fixture and set TEST_RUNNER_SYNCSTR_V5_FIXTURE_ROOT")
            return
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
        searchForB(app)
        capture(app, "Only A is unsaved; B retains shared audio")
        app.terminate()
        app.launch()
        openSongs(app)
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        XCTAssertEqual(b.value as? String, "保存済み")
        XCTAssertNotEqual(a.value as? String, "保存済み")
        searchForB(app)
        app.buttons.containing(.staticText, identifier: "TRACK-B").firstMatch.tap()
        openPlayer(app)
        capture(app, "Offline playback of retained B after relaunch")
        app.terminate()
    }

    @MainActor
    func testConflictAndIncompleteNoticesSurviveRelaunch() throws {
        continueAfterFailure = false
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["SYNCSTR_V5_FIXTURE_ROOT"], "Required isolated v5 fixture is missing")
        for state in ["conflict", "incomplete"] {
            let app = XCUIApplication()
            app.launchArguments = ["--v5-fixture", root, "--v5-fixture-state", state]
            app.launch()
            let notice = app.staticTexts["library-status-notice"]
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            XCTAssertTrue(notice.label.contains(state == "conflict" ? "競合" : "未完了"))
            searchForB(app)
            app.buttons.containing(.staticText, identifier: "TRACK-B").firstMatch.tap()
            openPlayer(app)
            capture(app, state + ": unrelated B remains playable")
            app.terminate()
            app.launch()
            XCTAssertTrue(notice.waitForExistence(timeout: 10))
            capture(app, state + ": notice survives relaunch")
            app.terminate()
        }
    }

    @MainActor
    private func openPlayer(_ app: XCUIApplication) {
        let mini = app.buttons["mini-player-open"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        mini.tap()
        XCTAssertTrue(app.buttons["player-toggle"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "再生できません")).firstMatch.exists)
    }

    @MainActor
    private func searchForB(_ app: XCUIApplication) {
        let searchTab = app.buttons["検索"].firstMatch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
        searchTab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("TRACK-B")
        XCTAssertTrue(app.staticTexts["TRACK-B"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["TRACK-A"].exists)
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
