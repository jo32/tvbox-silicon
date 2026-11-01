#if os(tvOS)
import XCTest

/// Apple TV navigation with the Siri Remote against Scripts/qa-server.py (Scripts/test-tv-ui.sh).
final class TVNavigationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Back on a video page whose details are still loading returns to the source. With nothing
    /// focusable on the page, tvOS used to hand the press to the system, which left the app.
    func testBackWhileDetailsLoadReturnsToTheSource() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "sites", "-qaPage", "open-detail:qa-stall:1", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/stall-config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        let open = app.buttons["qa.open-detail"]
        XCTAssertTrue(open.waitForExistence(timeout: 60), "The QA page did not appear")
        // Focus starts in the tab sidebar on the left; move right into the page until Select opens the video.
        let loading = app.staticTexts["Loading video details…"]
        for _ in 0..<4 where !loading.exists {
            remote.press(.right); sleep(1)
            remote.press(.select)
            _ = loading.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(loading.exists, "The video page did not open")
        sleep(3)
        remote.press(.menu)
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "Back left the app")
        XCTAssertFalse(loading.exists, "Back did not leave the loading video page")
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Back did not return to the previous page")
    }

    /// Back once a video page has given up returns to the source. When the details failed, the error card's buttons
    /// sat below the full-screen hero, and with no episodes there was no Play: nothing on the page took focus, and
    /// Back did nothing.
    func testBackAfterDetailsFailReturnsToTheSource() throws { try backAfterTheVideoPageGivesUp(source: "qa-broken", focused: "detail.retry") }
    func testBackFromAVideoWithoutEpisodesReturnsToTheSource() throws { try backAfterTheVideoPageGivesUp(source: "qa-no-episodes", focused: "detail.goBack") }

    private func backAfterTheVideoPageGivesUp(source: String, focused identifier: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "sites", "-qaPage", "open-detail:\(source):1", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/stall-config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        let open = app.buttons["qa.open-detail"]
        XCTAssertTrue(open.waitForExistence(timeout: 60), "The QA page did not appear")
        let action = app.buttons[identifier]
        for _ in 0..<4 where !action.exists {
            remote.press(.right); sleep(1)
            remote.press(.select)
            _ = action.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(action.exists, "The video page did not offer \(identifier)")
        sleep(2)
        XCTAssertTrue(action.hasFocus, "\(identifier) did not take focus")
        remote.press(.menu)
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "Back left the app")
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Back did not return to the previous page")
    }

    /// Back while a live stream is still loading closes the player. AVKit's player kept the press to itself
    /// until the picture started, so a stream that never loaded could only be left by quitting the app (#22).
    func testBackWhileLiveLoadsClosesThePlayer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "live", "-qaPage", "player-stall", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/stall-config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let waiting = app.descendants(matching: .any)["player.waiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 60), "The player did not open")
        sleep(3)
        XCUIRemote.shared.press(.menu)
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "Back left the app")
        XCTAssertFalse(waiting.exists, "Back did not close the loading player")
        XCTAssertFalse(app.staticTexts["Can't play this right now"].exists, "The stream failed before Back was pressed")
    }

    /// Back still closes a loading episode once the transport bar has taken focus: it shows the episode
    /// buttons, focus moves onto one, and AVKit then kept the press to itself until the picture started.
    func testBackWhileAnEpisodeLoadsClosesThePlayerFromTheTransportBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "sites", "-qaPage", "play-source:qa-stream-stall", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/stall-config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let waiting = app.descendants(matching: .any)["player.waiting"]
        XCTAssertTrue(waiting.waitForExistence(timeout: 60), "The player did not open")
        sleep(3)
        let remote = XCUIRemote.shared
        remote.press(.select)
        sleep(2)
        remote.press(.down)
        sleep(2)
        remote.press(.menu)
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "Back left the app")
        XCTAssertFalse(waiting.exists, "Back did not close the loading player")
        XCTAssertFalse(app.staticTexts["Can't play this right now"].exists, "The stream failed before Back was pressed")
    }

    /// A source page searches from the remote: the search keyboard has no return key, so a Search
    /// button below it runs the query that was typed, and typing alone does not search.
    func testSourcePageSearchesWithTheSearchButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "sites", "-qaPage", "site:qa-standard", "-qaSearchDraft", "hello", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        XCTAssertTrue(shown("测试影片 01", in: app).waitForExistence(timeout: 60), "The source page did not load")
        // `-qaSearchDraft` stands in for typing (UI tests cannot type into the tvOS search keyboard).
        let submit = app.buttons["site.search.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10), "A typed query did not show the Search button")
        // Focus starts in the tab sidebar; right moves it into the search keyboard.
        remote.press(.right); sleep(1)
        XCTAssertFalse(shown("hello 01", in: app).exists, "The search ran before it was submitted")
        // Down from the keyboard lands on the Search button.
        remote.press(.down); sleep(1)
        remote.press(.select)
        XCTAssertTrue(shown("hello 01", in: app).waitForExistence(timeout: 20), "Pressing Search did not show results")
        XCTAssertFalse(submit.exists, "The Search button stayed after its query ran")
    }
    /// A video with several sources and one file each: the rail ends above Play, so Right from the
    /// Play row once found nothing and the source chips were unreachable with the remote.
    func testRemoteReachesTheSourceChips() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "sites", "-qaPage", "open-detail:qa-standard:drive", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        let open = app.buttons["qa.open-detail"]
        XCTAssertTrue(open.waitForExistence(timeout: 60), "The QA page did not appear")
        let chips = ["夸父原1", "夸父智1", "嘟嘟无限2"].map { app.buttons[$0] }
        let second = chips[1]
        for _ in 0..<4 where !second.exists {
            remote.press(.right); sleep(1); remote.press(.select)
            _ = second.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(second.exists, "The video page did not open")
        sleep(2)
        // Play takes focus once the details load; Right passes Download and enters the rail.
        XCTAssertTrue(app.buttons["Play"].hasFocus, "Play did not take focus when the details loaded")
        let file = app.buttons["[18.35GB] 玩-居-宗 01.mkv"]
        remote.press(.right); sleep(1)
        XCTAssertTrue(app.buttons["Download"].hasFocus, "Right from Play did not reach Download")
        remote.press(.right); sleep(1)
        XCTAssertTrue(file.hasFocus || chips.contains { $0.hasFocus }, "Right from Download did not reach the episode rail")
        if file.hasFocus { remote.press(.up); sleep(1) }
        XCTAssertTrue(chips.contains { $0.hasFocus }, "Up from the file did not reach the source chips")
        for _ in 0..<3 where !second.hasFocus {
            remote.press(chips[0].hasFocus ? .right : .left); sleep(1)
        }
        remote.press(.select); sleep(1)
        XCTAssertTrue(second.isSelected, "Select did not switch the source")
        // Left from the chips goes back to the left column.
        for _ in 0..<3 where chips.contains(where: { $0.hasFocus }) { remote.press(.left); sleep(1) }
        XCTAssertFalse(chips.contains { $0.hasFocus } || file.hasFocus, "Left did not leave the episode rail")
    }
    /// The address row on Add Subscription opens its alert and the app keeps answering the remote. On tvOS 27 any
    /// alert or sheet over a page pushed in a tab froze the app: `openRoute` was a new closure on every update, so
    /// the stack never settled (#272).
    func testAddSubscriptionAddressOpensWithoutFreezing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "settings", "-qaIsolatedData", "1",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        let add = app.buttons["Add Subscription"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 60), "Settings did not appear")
        sleep(3)
        // A notice about a newer version can cover the page at launch, with its OK in focus.
        if app.buttons["OK"].exists { remote.press(.select); sleep(2) }
        remote.press(.right); sleep(1)
        for _ in 0..<20 where !add.hasFocus { remote.press(.down); usleep(600_000) }
        XCTAssertTrue(add.hasFocus, "Add Subscription did not take focus")
        remote.press(.select)
        let address = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Subscription URL'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "Add Subscription did not open")
        sleep(2)
        for _ in 0..<4 where !address.hasFocus { remote.press(.up); usleep(600_000) }
        remote.press(.select)
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10), "The address alert did not appear")
        remote.press(.menu); sleep(2)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Back did not close the address alert")
        XCTAssertTrue(address.exists, "Back from the alert left Add Subscription")
        remote.press(.menu); sleep(2)
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Back did not return to Settings")
        XCTAssertEqual(app.state, .runningForeground)
    }
    /// A typed address stays when the alert closes by anything but Cancel. tvOS 18 also shows the alert's text field
    /// as a button under it, the first one Down reaches; selecting it closed the alert and dropped the address (#291).
    func testAddSubscriptionKeepsTheTypedAddress() throws {
        let typed = "http://127.0.0.1:8776/config.json"
        let app = XCUIApplication()
        // On tvOS 18, XCTest's runtime-issue hook crashed the app on a UIKit log fault when the text field took focus.
        app.launchEnvironment = ["OS_ACTIVITY_MODE": "disable"]
        app.launchArguments = ["-qaSection", "settings", "-qaIsolatedData", "1",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        let add = app.buttons["Add Subscription"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 60), "Settings did not appear")
        sleep(3)
        if app.buttons["OK"].exists { remote.press(.select); sleep(2) }
        remote.press(.right); sleep(1)
        for _ in 0..<20 where !add.hasFocus { remote.press(.down); usleep(600_000) }
        remote.press(.select)
        let address = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Subscription URL'")).firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), "Add Subscription did not open")
        sleep(2)
        for _ in 0..<4 where !address.hasFocus { remote.press(.up); usleep(600_000) }
        remote.press(.select)
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "The address alert did not appear")
        sleep(1)
        // Select opens the keyboard on the focused text field; Menu returns to the alert with the text kept.
        remote.press(.select); sleep(3)
        app.typeText(typed); sleep(1)
        remote.press(.menu); sleep(2)
        XCTAssertTrue(alert.exists, "Leaving the keyboard closed the alert")
        let fieldButton = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Subscription URL'")).firstMatch
        let close = fieldButton.exists ? fieldButton : alert.buttons["Done"].firstMatch
        for _ in 0..<3 where !close.hasFocus { remote.press(.down); usleep(700_000) }
        for _ in 0..<2 where !close.hasFocus { remote.press(.right); usleep(700_000) }
        XCTAssertTrue(close.hasFocus, "\(close.label) did not take focus")
        remote.press(.select); sleep(2)
        XCTAssertFalse(alert.exists, "\(close.label) did not close the alert")
        XCTAssertTrue(address.label.hasSuffix(typed), "The typed address was not kept: \(address.label)")
    }
    /// Poster titles are part of their card's label, so look for the text anywhere in a label.
    private func shown(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
#endif
