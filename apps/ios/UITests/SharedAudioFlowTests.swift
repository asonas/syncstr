import XCTest
import UIKit

final class SharedAudioFlowTests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        XCTContext.runActivity(named: "Establish portrait before SharedAudio test") { _ in
            XCUIDevice.shared.orientation = .portrait
            XCTAssertEqual(XCUIDevice.shared.orientation, .portrait)
        }
    }

    @MainActor
    override func tearDown() async throws {
        XCUIApplication().terminate()
        XCTContext.runActivity(named: "Restore portrait after SharedAudio test") { _ in
            XCUIDevice.shared.orientation = .portrait
            XCTAssertEqual(XCUIDevice.shared.orientation, .portrait)
        }
        try await super.tearDown()
    }

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
        let alert = app.alerts["この端末の保存を解除しますか？"]
        let confirmation = alert.buttons["保存を解除"]
        let confirmationExists = confirmation.waitForExistence(timeout: 5)
        let confirmationDetails = alert.exists ? alert.debugDescription : "Confirmation alert missing"
        if !confirmationExists {
            captureSaveRemovalFailure(app, confirmation: confirmationDetails, stage: "Before confirmation")
        }
        XCTAssertTrue(confirmationExists)
        confirmation.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "未保存"), object: a)
        let removalCompleted = XCTWaiter.wait(for: [dismissed, removed], timeout: 5)
        if removalCompleted != .completed || !b.exists || b.value as? String != "保存済み" {
            captureSaveRemovalFailure(app, confirmation: confirmationDetails, stage: "After confirmation")
        }
        XCTAssertEqual(removalCompleted, .completed, "The alert must close and TRACK-A must become unsaved")
        XCTAssertEqual(b.value as? String, "保存済み")
        searchForB(app)
        capture(app, "Only A is unsaved; B retains shared audio")
        app.terminate()
        app.launch()
        openSongs(app)
        let aRestored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "未保存"), object: a)
        let bRestored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", "保存済み"), object: b)
        let restored = XCTWaiter.wait(for: [aRestored, bRestored], timeout: 5)
        if restored != .completed {
            captureSaveRemovalFailure(app, confirmation: confirmationDetails, stage: "After offline relaunch")
        }
        XCTAssertEqual(restored, .completed, "TRACK-A must remain unsaved and TRACK-B must remain saved after relaunch")
        searchForB(app)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track-"))
            .containing(.staticText, identifier: "TRACK-B").firstMatch.tap()
        openPlayer(app)
        capture(app, "Offline playback of retained B after relaunch")
        app.terminate()
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCUIDevice.shared.orientation = .landscapeLeft
            app.launch()
            searchForB(app)
            captureSearchPresentation(app, "Landscape search without a notice")
            XCTAssertFalse(app.staticTexts["library-status-notice"].exists)
            app.terminate()
        }
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
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track-"))
                .containing(.staticText, identifier: "TRACK-B").firstMatch.tap()
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
    func testLongNoticePreservesControlsAcrossAppearanceAndOrientation() throws {
        continueAfterFailure = false
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["SYNCSTR_V5_FIXTURE_ROOT"])
        let app = XCUIApplication()
        app.launchArguments = ["--v5-fixture", root, "--v5-fixture-state", "incomplete"]
        for appearance in ["ライト", "ダーク"] {
            app.launch()
            chooseAppearance(appearance, app)
            app.terminate()
            for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
                XCUIDevice.shared.orientation = orientation
                app.launch()
                let notice = app.staticTexts["library-status-notice"]
                XCTAssertTrue(notice.waitForExistence(timeout: 10))
                XCTAssertTrue(notice.label.contains("前回の情報と保存済みの曲を保持"))
                searchForB(app)
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "track-"))
                    .containing(.staticText, identifier: "TRACK-B").firstMatch.tap()
                let mini = app.buttons["mini-player-open"].firstMatch
                XCTAssertTrue(mini.waitForExistence(timeout: 5))
                XCTAssertTrue(mini.isHittable)
                XCTAssertFalse(notice.frame.intersects(mini.frame))
                if UIDevice.current.userInterfaceIdiom == .phone {
                    XCTAssertTrue(app.tabBars.buttons["ライブラリ"].isHittable)
                    XCTAssertTrue(app.tabBars.buttons["設定"].isHittable)
                }
                capture(app, "Long notice \(appearance) \(orientation.rawValue): navigation and playback")
                let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                screen.name = "Full screen \(appearance) \(orientation.rawValue)"
                screen.lifetime = .keepAlways
                add(screen)
                openPlayer(app)
                app.terminate()
            }
        }
        app.launch()
        chooseAppearance("システムに合わせる", app)
    }

    @available(iOS 27.0, *)
    @MainActor
    func testVoiceOverReadsPersistentNotice() throws {
        continueAfterFailure = false
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["SYNCSTR_V5_FIXTURE_ROOT"])
        let app = XCUIApplication()
        app.launchArguments = ["--v5-fixture", root, "--v5-fixture-state", "incomplete"]
        app.launch()
        let notice = app.staticTexts["library-status-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let expectedNotice = notice.label
        XCTAssertFalse(expectedNotice.isEmpty)
        let voiceOver = XCUIDevice.shared.voiceOverService
        let wasEnabled = voiceOver.isEnabled
        addTeardownBlock { @MainActor in
            if !wasEnabled { try voiceOver.disable() }
            XCTAssertEqual(voiceOver.isEnabled, wasEnabled)
        }
        try voiceOver.enable()
        XCTAssertTrue(voiceOver.isEnabled)
        var focus = [String]()
        var utterances = [String]()
        if let speech = try? voiceOver.currentSpeech() {
            focus.append("Before touch: " + speech.utterance)
            utterances.append(speech.utterance)
        } else { focus.append("Before touch: no speech available") }
        notice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if let speech = try? voiceOver.currentSpeech() {
            focus.append("After touch: " + speech.utterance)
            utterances.append(speech.utterance)
        } else { focus.append("After touch: no speech available") }
        let focusRecord = XCTAttachment(string: focus.joined(separator: "\n"))
        focusRecord.name = "VoiceOver speech before and after notice touch"
        focusRecord.lifetime = .keepAlways
        add(focusRecord)
        capture(app, "VoiceOver focus after notice touch")
        for _ in 0..<60 {
            if utterances.contains(where: { $0.contains(expectedNotice) }) { break }
            utterances.append(try voiceOver.moveForward().utterance)
        }
        let speech = XCTAttachment(string: utterances.joined(separator: "\n"))
        speech.name = "VoiceOver spoken notice"
        speech.lifetime = .keepAlways
        add(speech)
        XCTAssertTrue(utterances.contains { $0.contains(expectedNotice) })
        capture(app, "VoiceOver reads the persistent notice")
    }

    @MainActor
    private func chooseAppearance(_ title: String, _ app: XCUIApplication) {
        let button = app.buttons["設定"].firstMatch
        let sidebar = app.cells.containing(.staticText, identifier: "設定").firstMatch
        let settings = button.exists ? button : sidebar
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        app.buttons["appearance-picker"].tap()
        app.buttons[title].tap()
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
        let searchButton = app.buttons["検索"].firstMatch
        let sidebarSearch = app.cells.containing(.staticText, identifier: "検索").firstMatch
        if !searchButton.exists, !sidebarSearch.exists, app.navigationBars.buttons["ライブラリ"].exists {
            app.navigationBars.buttons["ライブラリ"].tap()
        }
        let searchTab = searchButton.exists ? searchButton : sidebarSearch
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
        searchTab.tap()
        let field = app.searchFields.firstMatch
        let initiallyPresent = field.waitForExistence(timeout: 5)
        if !initiallyPresent {
            captureSearchPresentation(app, "Search missing before reveal")
            app.swipeDown()
            let revealedByPull = field.waitForExistence(timeout: 5)
            captureSearchPresentation(app, "Search after pull down")
            if !revealedByPull || !field.isHittable {
                searchTab.tap()
                _ = field.waitForExistence(timeout: 5)
                captureSearchPresentation(app, "Search after reselecting Search")
            }
        }
        // Reveal attempts diagnose the failure; they do not satisfy the original assertion.
        XCTAssertTrue(initiallyPresent, "Search field must appear before diagnostic reveal actions")
        guard initiallyPresent else { return }
        capture(app, "Search field before interaction")
        let notice = app.staticTexts["library-status-notice"]
        if notice.exists {
            XCTAssertFalse(notice.frame.intersects(field.frame))
        }
        XCTAssertTrue(field.isHittable)
        field.tap()
        capture(app, "Search field before typing B")
        field.typeText("TRACK-B")
        XCTAssertTrue(app.staticTexts["TRACK-B"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["TRACK-A"].exists)
    }

    @MainActor
    private func captureSearchPresentation(_ app: XCUIApplication, _ name: String) {
        let field = app.searchFields.firstMatch
        let exists = field.exists
        let state = "SearchField exists: \(exists)\nSearchField hittable: \(exists && field.isHittable)\n"
        XCTContext.runActivity(named: name) { activity in
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = name
            screen.lifetime = .keepAlways
            activity.add(screen)
            let hierarchy = XCTAttachment(string: state + app.debugDescription)
            hierarchy.name = name + " hierarchy and state"
            hierarchy.lifetime = .keepAlways
            activity.add(hierarchy)
        }
    }

    @MainActor
    private func openSongs(_ app: XCUIApplication) {
        let songs = app.descendants(matching: .any)["曲"].firstMatch
        if !songs.exists, app.navigationBars.buttons["ライブラリ"].exists {
            app.navigationBars.buttons["ライブラリ"].tap()
        }
        XCTAssertTrue(songs.waitForExistence(timeout: 10))
        songs.tap()
    }

    @MainActor
    private func captureSaveRemovalFailure(_ app: XCUIApplication, confirmation: String, stage: String) {
        capture(app, "Save removal failure: " + stage)
        let a = app.buttons["TRACK-Aの保存操作"]
        let b = app.buttons["TRACK-Bの保存操作"]
        let aValue = a.exists ? String(describing: a.value) : "missing"
        let bValue = b.exists ? String(describing: b.value) : "missing"
        let state = XCTAttachment(string: """
            Expected removal target: TRACK-A (TRACK-Aの保存操作), expected value: 未保存
            Expected retained track: TRACK-B (TRACK-Bの保存操作), expected value: 保存済み
            Actual TRACK-A value: \(aValue)
            Actual TRACK-B value: \(bValue)
            Presented confirmation:
            \(confirmation)
            Current hierarchy:
            \(app.debugDescription)
            """)
        state.name = "Save removal target and state: " + stage
        state.lifetime = .keepAlways
        add(state)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
