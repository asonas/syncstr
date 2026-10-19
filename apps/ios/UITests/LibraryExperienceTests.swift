import XCTest

final class LibraryExperienceTests: XCTestCase {
    @MainActor
    func testAlbumActionsAndCenteredArtistNavigation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["最近追加した項目"].firstMatch.waitForExistence(timeout: 5))
        let albums = app.descendants(matching: .any)["アルバム"].firstMatch
        if albums.exists { albums.tap() }
        let album = app.buttons.containing(.staticText, identifier: "Album 2").firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: album)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        let albumID = album.identifier
        XCTAssertTrue(albumID.hasPrefix("album-"))
        album.tap()
        let play = app.buttons["album-play"].firstMatch
        let shuffle = app.buttons["album-shuffle"].firstMatch
        let save = app.buttons["album-save"].firstMatch
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
        let origin = app.buttons[albumID].firstMatch
        XCTAssertTrue(origin.waitForExistence(timeout: 5))
        let viewport = app.scrollViews.firstMatch.frame
        let visibleTop = max(viewport.minY, app.navigationBars["Fixture Ensemble"].frame.maxY)
        let tabBar = app.tabBars.firstMatch
        let visibleBottom = tabBar.exists ? min(viewport.maxY, tabBar.frame.minY) : viewport.maxY
        capture(app, "Artist origin album centered")
        XCTAssertEqual(origin.frame.midY, (visibleTop + visibleBottom) / 2, accuracy: 20)
        app.navigationBars["Fixture Ensemble"].buttons.firstMatch.tap()
        play.tap()
        let mini = app.buttons["mini-player-open"].firstMatch
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
