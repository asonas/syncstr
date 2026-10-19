import XCTest

final class AppearanceFlowTests: XCTestCase {
    @MainActor
    func testLightLibraryAndPlayerUnderSystemAppearance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--reset-appearance"]
        app.launch()
        openSettings(app)
        capture(app, "Initial system appearance")
        choose("ライト", app)
        showAlbum(app)
        let current = app.buttons["track-fixture-0"].firstMatch
        current.tap()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "選択中"), object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed)
        capture(app, "Light selected row after preparation")
        app.buttons["mini-player-open"].firstMatch.tap()
        capture(app, "Light full player")
        app.terminate()
    }

    @MainActor
    func testAppearanceChangesImmediatelyAndSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--reset-appearance"]
        app.launch()
        openSettings(app)
        let picker = app.buttons["appearance-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("システムに合わせる") || (picker.value as? String) == "システムに合わせる")
        choose("ライト", app)
        capture(app, "Light settings")
        showAlbum(app)
        capture(app, "Light album detail")
        let current = app.buttons["track-fixture-0"].firstMatch
        current.tap()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "選択中"), object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 15), .completed)
        capture(app, "Light current track")
        app.terminate()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        openSettings(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("ライト") || (picker.value as? String) == "ライト")
        choose("ダーク", app)
        capture(app, "Dark settings")
        showAlbum(app)
        capture(app, "Dark album detail")
        app.terminate()
        app.launch()
        openSettings(app)
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("ダーク") || (picker.value as? String) == "ダーク")
        choose("システムに合わせる", app)
        capture(app, "System settings")
        app.terminate()
    }

    @MainActor
    private func choose(_ title: String, _ app: XCUIApplication) {
        app.buttons["appearance-picker"].tap()
        app.buttons[title].firstMatch.tap()
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        if app.tabBars.buttons["設定"].exists { app.tabBars.buttons["設定"].tap() }
        else {
            if app.navigationBars.buttons["ライブラリ"].exists { app.navigationBars.buttons["ライブラリ"].tap() }
            let settings = app.staticTexts["設定"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }
    }

    @MainActor
    private func showAlbum(_ app: XCUIApplication) {
        app.buttons["ライブラリへ戻る"].tap()
        if !app.buttons["選択"].exists { app.buttons["アルバム"].firstMatch.tap() }
        let album = app.buttons.containing(.staticText, identifier: "Album 1").firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        XCTAssertTrue(app.staticTexts["V.A."].waitForExistence(timeout: 5))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
