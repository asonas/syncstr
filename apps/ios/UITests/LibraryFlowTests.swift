import XCTest

final class LibraryFlowTests: XCTestCase {
    @MainActor
    func testAccessibilityTextUsesOneAlbumColumn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        openAlbums(app)
        let first = album(app, 1).frame
        let second = album(app, 2)
        for _ in 0..<5 where !second.isHittable { app.swipeUp() }
        XCTAssertTrue(second.isHittable)
        XCTAssertEqual(first.minX, second.frame.minX, accuracy: 2)
        XCTAssertEqual(first.width, second.frame.width, accuracy: 2)
        attach(app, "Accessibility album column")
        app.terminate()
    }

    @MainActor
    func testAlbumContextMenuRemainsAvailable() {
        let app = launchFixture()
        openAlbums(app)
        album(app, 1).press(forDuration: 1)
        XCTAssertTrue(app.buttons["非表示にする"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testArtistListScrollPerformance() {
        let app = launchFixture()
        if app.buttons["選択"].waitForExistence(timeout: 3), app.navigationBars.buttons["ライブラリ"].exists {
            app.navigationBars.buttons["ライブラリ"].tap()
        }
        app.descendants(matching: .any)["アーティスト"].firstMatch.tap()
        app.buttons["Fixture Ensemble"].tap()
        XCTAssertTrue(app.buttons["track-fixture-0"].waitForExistence(timeout: 5))
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            app.swipeUp()
            app.swipeDown()
        }
        attach(app, "Artist tracks")
    }

    @MainActor
    func testReturningToAlbumsRestoresOpenedAlbum() {
        let app = launchFixture()
        openAlbums(app)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let target = album(app, 15)
        for _ in 0..<10 where !target.isHittable { app.swipeUp() }
        XCTAssertTrue(target.isHittable)
        target.tap()
        XCTAssertTrue(app.staticTexts["11曲"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["アルバム"].tap()
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isHittable)
        let viewport = app.scrollViews.firstMatch.frame
        XCTAssertLessThan(abs(target.frame.midY - viewport.midY), target.frame.height / 2 + 80)
        attach(app, "Restored album position")
    }

    @MainActor
    func testCommandClickSelectsAlbumsAndSearchEndsAfterOpeningResult() {
        let app = launchFixture()
        openAlbums(app)
        XCUIElement.perform(withKeyModifiers: .command) {
            album(app, 1).tap()
            album(app, 2).tap()
        }
        XCTAssertTrue(app.staticTexts["2枚を選択"].waitForExistence(timeout: 3))
        app.buttons["完了"].tap()
        let field = searchField(app)
        field.tap()
        field.typeText("Album 2")
        album(app, 2).tap()
        XCTAssertTrue(app.staticTexts["11曲"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        attach(app, "Album detail")
        app.buttons["再生"].firstMatch.tap()
        app.navigationBars.buttons["アルバム"].tap()
        let restored = searchField(app)
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(restored.value as? String, "Album 2")
        app.terminate()
    }

    @MainActor
    func testSearchAcceptsSpaceWhileEditing() {
        let app = launchFixture()
        openAlbums(app)
        let field = searchField(app)
        field.tap()
        field.typeText("Album 2")
        app.typeKey(" ", modifierFlags: [])
        XCTAssertEqual(field.value as? String, "Album 2 ")
        app.terminate()
    }

    @MainActor
    func testAlbumsCanBeSortedHiddenTogetherAndRestored() throws {
        let app = launchFixture()
        openAlbums(app)
        app.buttons["並び替え"].tap()
        XCTAssertTrue(app.buttons["アーティスト"].waitForExistence(timeout: 3))
        app.buttons["アーティスト"].tap()
        app.buttons["並び替え"].tap()
        app.buttons["タイトル"].tap()
        app.buttons["選択"].tap()
        album(app, 1).tap()
        album(app, 2).tap()
        XCTAssertTrue(app.staticTexts["2枚を選択"].exists)
        app.buttons["非表示にする"].tap()
        XCTAssertTrue(app.staticTexts["0枚を選択"].waitForExistence(timeout: 5))
        XCTAssertFalse(album(app, 1).exists)
        app.buttons["完了"].tap()
        if app.navigationBars.buttons["ライブラリ"].exists { app.navigationBars.buttons["ライブラリ"].tap() }
        app.descendants(matching: .any)["非表示にしたアルバム"].firstMatch.tap()
        XCTAssertTrue(album(app, 1).waitForExistence(timeout: 5))
        app.buttons["選択"].tap()
        album(app, 1).tap()
        album(app, 2).tap()
        app.buttons["非表示を解除"].tap()
        XCTAssertTrue(app.staticTexts["非表示にしたアルバムはありません"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAlbumPlaybackFailureOffersCopyAndReturningPreservesAlbum() throws {
        let app = launchFixture()
        openAlbums(app)
        let first = album(app, 1)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(app.staticTexts["V.A."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["非表示にする"].exists)
        XCTAssertTrue(app.buttons["この端末に保存"].firstMatch.exists)
        app.buttons["再生"].firstMatch.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "の再生中画面を開く")).firstMatch.tap()
        let copy = app.buttons["診断ログをコピー"]
        if !copy.isHittable { app.swipeUp() }
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        copy.tap()
        XCTAssertTrue(app.staticTexts["コピーしました"].waitForExistence(timeout: 5))
        attach(app, "Playback diagnostics")
    }

    @MainActor
    private func launchFixture() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        return app
    }

    @MainActor
    private func openAlbums(_ app: XCUIApplication) {
        if !app.buttons["選択"].waitForExistence(timeout: 3) {
            app.buttons["アルバム"].firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["選択"].waitForExistence(timeout: 5))
        attach(app, "Album browser")
    }

    @MainActor
    private func album(_ app: XCUIApplication, _ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Album \(number)、")).firstMatch
    }

    @MainActor
    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        let field = app.searchFields.firstMatch
        if !field.isHittable { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
