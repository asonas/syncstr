import XCTest

final class LibraryExperienceTests: XCTestCase {
    @MainActor
    func testAlbumActionsAndCenteredArtistNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["最近追加した項目"].firstMatch.waitForExistence(timeout: 5))
        let albums = app.descendants(matching: .any)["アルバム"].firstMatch
        if albums.exists { albums.tap() }
        let album = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Album 2、", "Album 2,")).firstMatch
        for _ in 0..<12 where !album.isHittable { app.swipeUp() }
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        let play = app.buttons["再生"].firstMatch
        let shuffle = app.buttons["アルバムをシャッフル再生"].firstMatch
        let save = app.buttons["アルバムの保存操作"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertLessThan(shuffle.frame.midX, play.frame.midX)
        XCTAssertGreaterThan(save.frame.midX, play.frame.midX)
        if app.tabBars.firstMatch.exists {
            XCTAssertEqual(play.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 3)
        }
        capture(app, "Album actions before saving")
        save.tap()
        XCTAssertTrue(app.buttons["この端末に保存"].waitForExistence(timeout: 5))
        app.tap()
        app.buttons["Fixture Ensemble"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Fixture Ensemble"].waitForExistence(timeout: 5))
        let origin = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Album 2")).firstMatch
        XCTAssertTrue(origin.waitForExistence(timeout: 5))
        let viewport = app.scrollViews.firstMatch.frame
        let visibleTop = max(viewport.minY, app.navigationBars["Fixture Ensemble"].frame.maxY)
        XCTAssertEqual(origin.frame.midY, (visibleTop + viewport.maxY) / 2, accuracy: 20)
        capture(app, "Artist origin album centered")
        app.navigationBars["Fixture Ensemble"].buttons.firstMatch.tap()
        play.tap()
        let mini = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "の再生中画面を開く")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 5))
        if app.buttons["閉じる"].exists { app.buttons["閉じる"].tap() }
        let expanded = mini.frame.midY
        capture(app, "Expanded mini-player")
        app.swipeUp()
        if app.tabBars.firstMatch.exists {
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                mini.frame.midY > expanded + 10
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        }
        capture(app, "Mini-player after scrolling")
        if app.tabBars.firstMatch.exists {
            let compact = mini.frame.midY
            app.swipeDown()
            let expandedAgain = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                mini.frame.midY < compact - 10
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expandedAgain], timeout: 5), .completed)
        }
        app.terminate()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
