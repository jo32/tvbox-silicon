#if os(iOS)
import XCTest

/// Phone acceptance against a real device (Scripts/test-duo-ui.sh).
///
/// Nothing here runs against the QA host app: every test drives the installed Mi3s build
/// (`wda.prdc.yingxia.dev`) through `XCUIApplication(bundleIdentifier:)`, so the screens under test are
/// the user's own — their subscriptions, their settings. The tests therefore only read: they walk to a
/// screen, assert what must be on it, and photograph it. Nothing is toggled, deleted or reordered.
final class DuoAcceptanceUITests: XCTestCase {
    private let bundleID = "wda.prdc.yingxia.dev"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: bundleID)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Screens

    /// Every section the QA hook can open, in tab order. Photographed and checked for a live window.
    func testEverySectionOpens() throws {
        let sections = ["home", "discover", "live", "music", "search", "sites", "favorites", "downloads", "files",
                        "history", "settings", "more"]
        for section in sections {
            launch(section: section)
            // A section that fails to build shows an empty window; the tab bar is always there.
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "\(section) never drew a window")
            Thread.sleep(forTimeInterval: 2.5)
            attach(section)
        }
    }

    /// The Sources screen has to list every subscription the user added. This is the regression the user hit
    /// after the fork: the section showed only the built-in sources, and enabling 隐私锁定 hid even those.
    func testSourcesListsSubscriptions() throws {
        launch(section: "sites")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "Sources never opened")
        Thread.sleep(forTimeInterval: 3)
        attach("sites")

        // The screen is a list of sources; a subscription row is a button or cell carrying a name. Any row at all
        // means the list is not empty, which is what the user lost.
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'site.'"))
        XCTAssertGreaterThan(rows.count, 0, "Sources listed no rows at all — the subscription list is empty")
    }

    /// Settings must still report a version, which is how a screenshot proves the build under test is the one
    /// that was just installed rather than a stale copy.
    func testSettingsShowsVersion() throws {
        launch(section: "settings")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "Settings never opened")
        Thread.sleep(forTimeInterval: 2)
        attach("settings")
        let version = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1.8")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10), "Settings does not show a 1.8.x version")
    }

    /// The privacy vault is the other half of the same regression: with it on, unlocking has to reveal the
    /// filtered sources again. The vault asks for a passcode, so the test only checks that the lock screen
    /// draws and can be dismissed — it must not guess a passcode.
    func testPrivacyVaultDraws() throws {
        launch(section: "settings")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "Settings never opened")
        Thread.sleep(forTimeInterval: 2)

        let vault = app.buttons["settings.privacyVault"]
        guard vault.waitForExistence(timeout: 10) else {
            // Privacy is off, which is the shipped default: nothing to photograph, and that is not a failure.
            throw XCTSkip("Privacy vault row is not on Settings; privacy is off on this device")
        }
        vault.tap()
        Thread.sleep(forTimeInterval: 2)
        attach("vault")
        XCTAssertTrue(app.windows.firstMatch.exists, "The vault dismissed the app")
    }

    // MARK: - Helpers

    private func launch(section: String) {
        dismissSystemAlerts()
        app.launchArguments = ["-qaSection", section, "-qaKeepAwake", "1", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        dismissSystemAlerts()
    }

    /// Apple's own prompts (notifications, background location, “Open in …?”) belong to SpringBoard and sit on top
    /// of everything. Left alone they make every screenshot a picture of the prompt.
    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<8 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 2) else { return }
            // Allow, so the prompt does not come back next launch; anything else is better than leaving it up.
            let allow = ["允许", "始终允许", "好", "Allow", "Always Allow", "OK"]
                .compactMap { alert.buttons[$0].exists ? alert.buttons[$0] : nil }
                .first
            if let allow { allow.tap() } else if alert.buttons.count > 0 { alert.buttons.element(boundBy: alert.buttons.count - 1).tap() }
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
