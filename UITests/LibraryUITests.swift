import XCTest

final class LibraryUITests: XCTestCase {
    #if os(iOS)
    @MainActor func testHardwareKeyboardPlaybackControls() {
        continueAfterFailure = false
        let app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1", "-qaStartAt", "90", "-qaPlayerControls", "0"])
        let position = app.staticTexts["player.qa.position"]
        let paused = app.staticTexts["player.qa.paused"]
        let muted = app.staticTexts["player.qa.muted"]
        wait(position, "value.doubleValue >= %@.doubleValue", "90")
        app.typeKey(.space, modifierFlags: [])
        wait(paused, "value == %@", "true")
        app.buttons["player.lock"].tap()
        app.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(paused.value as? String, "true")
        app.buttons["player.lock"].tap()
        let start = Double(position.value as? String ?? "") ?? 0
        app.typeKey(.rightArrow, modifierFlags: [])
        wait(position, "value.doubleValue >= %@.doubleValue", String(start + 9))
        app.typeKey(.leftArrow, modifierFlags: [.shift])
        wait(position, "value.doubleValue <= %@.doubleValue", String(start - 49))
        app.typeKey("m", modifierFlags: [])
        wait(muted, "value == %@", "true")
        app.typeKey("m", modifierFlags: [])
        wait(muted, "value == %@", "false")
        app.typeKey(.space, modifierFlags: [])
        wait(paused, "value == %@", "false")
    }

    @MainActor func testHardwareKeyboardLeavesSheetTextEntryAlone() {
        continueAfterFailure = false
        let app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1", "-qaStartAt", "90"])
        let paused = app.staticTexts["player.qa.paused"]
        let muted = app.staticTexts["player.qa.muted"]
        wait(app.staticTexts["player.qa.position"], "value.doubleValue >= %@.doubleValue", "90")
        app.typeKey(.space, modifierFlags: [])
        wait(paused, "value == %@", "true")
        app.buttons["player.options"].tap(); app.buttons["player.skip"].tap()
        let intro = app.textFields["player.skip.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        intro.tap()
        intro.typeText("01:30 m")
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertEqual(intro.value as? String, "01:30 m")
        app.buttons["取消"].tap()
        wait(paused, "value == %@", "true")
        wait(muted, "value == %@", "false")
        app.typeKey(.space, modifierFlags: [])
        wait(paused, "value == %@", "false")
    }
    #endif

    @MainActor private func launch(_ section: String = "history", page: String? = "play-source:qa-standard", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", section, "-qaSubscription", "http://127.0.0.1:8776/config.json", "-qaIsolatedData", "1",
            "-qaPlaybackProbe", "1", "-qaPlayerControls", "1", "-autoPlayNextEpisode", "0", "-danmakuOfficialLookup", "0",
            "-danmakuServer", "http://127.0.0.1:8776", "-danmakuDmkuServer", "http://127.0.0.1:8776/failure/",
            "-danmakuEnabled", "1", "-danmakuAutoMatch", "1", "-AppleLanguages", "(zh-Hans)"]
        if let page { app.launchArguments += ["-qaPage", page] }
        app.launchArguments += extra; app.launch(); return app
    }
    @MainActor private func wait(_ element: XCUIElement, _ format: String, _ value: String, timeout: Double = 30) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        expectation(for: NSPredicate(format: format, value), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }
    @MainActor private func options(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        app.buttons["player.catalogOptions"].tap()
    }
    @MainActor private func close(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).tap()
        app.buttons["player.close"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["player.close"])
        waitForExpectations(timeout: 10)
    }
    @MainActor func testAutomaticDanmakuAndSilentAbsenceOrFailure() {
        continueAfterFailure = false
        var app = launch(extra: ["-qaResetCache", "1"])
        wait(app.staticTexts["player.qa.danmaku"], "label == %@", "loaded")
        XCTAssertEqual(app.staticTexts["player.qa.danmaku"].value as? String, "3")
        XCTAssertEqual(app.alerts.count, 0); app.terminate()
        app = launch(extra: ["-qaResetCache", "1", "-qaEpisodeName", "第 3 集"])
        wait(app.staticTexts["player.qa.danmaku"], "label == %@", "unmatched")
        XCTAssertEqual(app.staticTexts["player.qa.danmaku"].value as? String, "0")
        XCTAssertEqual(app.alerts.count, 0); app.terminate()
        app = launch(extra: ["-qaResetCache", "1", "-danmakuServer", "http://127.0.0.1:8776/failure"])
        wait(app.staticTexts["player.qa.danmaku"], "label == %@", "unavailable")
        XCTAssertEqual(app.staticTexts["player.qa.danmaku"].value as? String, "0")
        wait(app.staticTexts["player.qa.position"], "value != %@", "0.0")
        XCTAssertEqual(app.alerts.count, 0)
    }
    @MainActor func testSeriesSkipHistoryDeletionAndCacheClearing() throws {
        continueAfterFailure = false
        var app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1", "-qaResetCache", "1", "-qaStartAt", "30"])
        wait(app.staticTexts["player.qa.danmaku"], "label == %@", "loaded")
        wait(app.staticTexts["player.qa.position"], "value != %@", "0.0")
        options(app); app.buttons["player.skip"].tap()
        XCTAssertTrue(app.buttons["player.skip.markIntro"].waitForExistence(timeout: 10))
        app.buttons["player.skip.markIntro"].tap(); app.buttons["player.skip.save"].tap()
        close(app)
        XCTAssertTrue(app.buttons["history.resume.1"].waitForExistence(timeout: 15)); app.terminate()
        app = launch(extra: ["-qaEpisodeName", "第 2 集"])
        wait(app.staticTexts["player.qa.danmaku"], "label == %@", "loaded")
        options(app); app.buttons["player.skip"].tap()
        let intro = app.textFields["player.skip.intro"]
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        XCTAssertFalse(try XCTUnwrap(intro.value as? String).isEmpty)
        app.buttons["取消"].tap(); close(app); app.terminate()
        app = launch(extra: ["-qaVideoID", "2"])
        wait(app.staticTexts["player.qa.position"], "value != %@", "0.0")
        options(app); app.buttons["player.skip"].tap()
        XCTAssertTrue(intro.waitForExistence(timeout: 10))
        XCTAssertEqual(intro.value as? String, intro.placeholderValue)
        app.buttons["取消"].tap(); close(app)
        XCTAssertTrue(app.buttons["history.resume.2"].waitForExistence(timeout: 15))
        app.buttons["history.manage"].tap(); app.buttons["history.select.1"].tap()
        app.buttons["history.deleteSelected"].tap()
        // A confirmation dialog: an action sheet on iPhone, a popover on iPad, so not under `alerts`.
        let confirm = app.buttons["history.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["history.resume.1"])
        waitForExpectations(timeout: 10)
        // Deleting keeps the page in manage mode, where the remaining title is a selection button.
        XCTAssertTrue(app.buttons["history.select.2"].exists || app.buttons["history.resume.2"].exists); app.terminate()
        app = launch("settings", page: "cache")
        XCTAssertTrue(app.buttons["cache.clear"].waitForExistence(timeout: 20))
        app.buttons["cache.clear"].tap(); app.buttons["cache.confirmClear"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["单集弹幕：0"].waitForExistence(timeout: 10))
    }
    @MainActor func testPinnedSourcesPersistOnHome() {
        continueAfterFailure = false
        var app = launch("sites", page: "site:qa-standard")
        let pin = app.buttons["source.pin.qa-standard"]
        XCTAssertTrue(pin.waitForExistence(timeout: 20))
        if pin.label == "取消置顶" { pin.tap() }
        pin.tap(); app.terminate()
        app = launch("home", page: nil)
        let source = app.buttons["home.pinned.qa-standard"]
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        source.tap()
        XCTAssertTrue(app.buttons["source.pin.qa-standard"].waitForExistence(timeout: 20))
        app.buttons["source.pin.qa-standard"].tap(); app.terminate()
        app = launch("home", page: nil)
        XCTAssertFalse(app.buttons["home.pinned.qa-standard"].waitForExistence(timeout: 5))
    }
    @MainActor func testHistoryResumesAtSavedPosition() {
        continueAfterFailure = false
        let app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1", "-qaStartAt", "35"])
        wait(app.staticTexts["player.qa.position"], "value.doubleValue >= %@.doubleValue", "35")
        close(app)
        XCTAssertTrue(app.buttons["history.resume.1"].waitForExistence(timeout: 15))
        app.buttons["history.resume.1"].tap()
        wait(app.staticTexts["player.qa.position"], "value.doubleValue >= %@.doubleValue", "35")
        XCTAssertEqual(app.alerts.count, 0)
    }
    @MainActor func testHoldingThePicturePlaysFasterAndSlidingDownKeepsIt() {
        continueAfterFailure = false
        let app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1"])
        let position = app.staticTexts["player.qa.position"]
        wait(position, "value.doubleValue >= %@.doubleValue", "1")
        let picture = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.55))
        let boost = app.buttons["player.boost"]
        // Letting go goes back to the chosen speed.
        picture.press(forDuration: 1)
        XCTAssertFalse(boost.waitForExistence(timeout: 1))
        // Sliding down keeps it.
        picture.press(forDuration: 1, thenDragTo: picture.withOffset(CGVector(dx: 0, dy: 120)))
        XCTAssertTrue(boost.waitForExistence(timeout: 5))
        XCTAssertEqual(boost.value as? String, "2×")
        let start = Double(position.value as? String ?? "") ?? 0
        sleep(4)
        let end = Double(position.value as? String ?? "") ?? 0
        XCTAssertGreaterThan(end - start, 6)
        boost.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: boost)
        waitForExpectations(timeout: 5)
    }
    @MainActor func testDoubleTappingASideSkipsAndSlidingAcrossSeeks() {
        continueAfterFailure = false
        let app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1", "-qaStartAt", "60"])
        let position = app.staticTexts["player.qa.position"]
        wait(position, "value.doubleValue >= %@.doubleValue", "60")
        func now() -> Double { Double(position.value as? String ?? "") ?? 0 }
        let before = now()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.55)).doubleTap()
        wait(position, "value.doubleValue <= %@.doubleValue", String(before - 5), timeout: 5)
        // Half the picture's width is 90 seconds of this five-minute video.
        let from = now()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55)))
        wait(position, "value.doubleValue >= %@.doubleValue", String(from + 80))
        XCTAssertFalse(app.descendants(matching: .any)["player.swipeSeek"].exists)
    }
    @MainActor func testSlidingUpOrDownSetsTheBrightnessOrTheVolume() {
        continueAfterFailure = false
        let app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1"])
        wait(app.staticTexts["player.qa.position"], "value.doubleValue >= %@.doubleValue", "1")
        // The level shows for under a second after the finger lifts, less than a query takes to arrive: read the
        // hierarchy captured at once instead.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45)))
        XCTAssertTrue(app.debugDescription.contains("identifier: 'player.level', label: '亮度'"))
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.7)))
        XCTAssertTrue(app.debugDescription.contains("identifier: 'player.level', label: '音量'"))
    }
    @MainActor func testNativePlayerAutomaticallyAdvancesToNextEpisode() {
        continueAfterFailure = false
        let app = launch(extra: ["-qaResetHistory", "1", "-qaResetPlayerSettings", "1", "-qaStartAt", "296", "-autoPlayNextEpisode", "1"])
        XCTAssertTrue(app.staticTexts["测试影片 1 · 第 2 集"].waitForExistence(timeout: 45))
        wait(app.staticTexts["player.qa.position"], "value != %@", "0.0")
        XCTAssertEqual(app.alerts.count, 0)
    }
}
