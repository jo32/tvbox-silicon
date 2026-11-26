#if os(iOS)
import XCTest

final class CachedEpisodesUITests: XCTestCase {
    @MainActor func testResumeRotateDownloadMoreAndDeleteOnlySelectedEpisodes() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let phone = UIDevice.current.userInterfaceIdiom == .phone
        let app = XCUIApplication()
        let video = "qa-cache-ui-" + UUID().uuidString
        app.launchArguments = ["-qaSection", "downloads", "-qaVersion", "999.0", "-updates.announcedVersion", "999.0", "-qaIsolatedData", "1", "-qaDownload", "qa-standard:" + video + ":2",
                               "-qaSubscription", "http://127.0.0.1:8776/config.json", "-qaPlayerControls", "1",
                               "-danmakuEnabled", "0", "-autoPlayNextEpisode", "0", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if app.buttons["Not Now"].waitForExistence(timeout: 3) { app.buttons["Not Now"].tap() }
        let group = app.descendants(matching: .any)["downloads.show." + video].firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 60))
        group.tap()
        let wide = app.buttons["downloads.play.0-0"], portrait = app.buttons["downloads.play.0-1"]
        func open(_ episode: XCUIElement, landscape: Bool) {
            XCTAssertTrue(episode.waitForExistence(timeout: 30))
            episode.tap()
            let pause = app.buttons["player.playPause"]
            XCTAssertTrue(pause.waitForExistence(timeout: 45))
            if phone {
                let rotated = NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    return landscape ? frame.width > frame.height : frame.height > frame.width
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 15), .completed)
            }
            Thread.sleep(forTimeInterval: 3)
            app.buttons["player.close"].tap()
            XCTAssertTrue(episode.waitForExistence(timeout: 30))
            XCTAssertTrue((episode.value as? String)?.contains(" / ") == true, "Missing progress on \(episode)")
        }
        open(wide, landscape: true)
        open(portrait, landscape: false)
        XCTAssertTrue((wide.value as? String)?.contains(" / ") == true)

        app.buttons["downloads.more"].tap()
        // Buttons in the picker combine their episode title and cache state.
        let thirdRow = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Third'")).firstMatch
        XCTAssertTrue(thirdRow.waitForExistence(timeout: 30))
        thirdRow.tap()
        app.buttons["Cache 1"].tap()
        let thirdTile = app.buttons["downloads.play.0-2"]
        XCTAssertTrue(thirdTile.waitForExistence(timeout: 40))
        app.buttons["downloads.manage"].tap()
        app.buttons["downloads.select.0-1"].tap()
        app.buttons["downloads.select.0-2"].tap()
        app.buttons["downloads.deleteSelection"].tap()
        app.buttons["Delete from Cache"].tap()
        XCTAssertTrue(wide.waitForExistence(timeout: 10))
        XCTAssertFalse(portrait.exists)
        XCTAssertFalse(thirdTile.exists)
    }
}
#endif
