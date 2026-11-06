import Foundation
import Testing
@testable import TVCore

private func notice(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

/// A Wex plugin's own sign-in (OwnDriveSignIn.java) arrives as `wexPreferences` in the sign-in notice. The app
/// keeps it with its accounts so every Wex source gets it, without touching the app's own drive accounts.
@Test func pluginWexSignInsAreKept() throws {
    var accounts = CloudDriveAccounts()
    accounts.quarkCookie = "__pus=app"
    let pan115 = try notice(#"{"drive":"pan115","signedIn":true,"wexPreferences":{"Wex_pan115_cookie":"UID=115"}}"#)
    let first = accounts.take(pan115), again = accounts.take(pan115)
    #expect(first && !again)
    let quark = accounts.take(try notice(#"{"drive":"quark","signedIn":true,"wexPreferences":{"Wex_quark_cookie":"__pus=plugin","yingxia.replaced.Wex_quark_cookie":"digest"}}"#))
    #expect(quark)
    #expect(accounts.wexPreferences == ["Wex_pan115_cookie": "UID=115", "Wex_quark_cookie": "__pus=plugin", "yingxia.replaced.Wex_quark_cookie": "digest"])
    #expect(accounts.quarkCookie == "__pus=app")
    let saved = try JSONDecoder().decode(CloudDriveAccounts.self, from: JSONEncoder().encode(accounts))
    #expect(saved.wexPreferences == accounts.wexPreferences)
    // Saves from before the field still load.
    let old = try JSONDecoder().decode(CloudDriveAccounts.self, from: Data(#"{"quarkCookie":"","ucCookie":"","ucToken":"","token":""}"#.utf8))
    #expect(old.wexPreferences == nil)
}

/// A plugin's own Quark or UC sign-in (LoginPrompt.collectedAccount) becomes the app's account, as one made in
/// Settings would: Quark only with both its cookie and mobile ticket, which FTY needs together.
@Test func pluginQuarkAndUCSignInsBecomeTheAppsAccounts() throws {
    var accounts = CloudDriveAccounts()
    accounts.quarkCookie = "__pus=old"; accounts.quarkServiceTicket = "old"
    #expect(!accounts.take(try notice(#"{"drive":"quark","signedIn":true}"#)))
    #expect(!accounts.take(try notice(#"{"drive":"quark","signedIn":true,"quarkCookie":"__pus=new"}"#)))
    #expect(accounts.quarkCookie == "__pus=old")
    #expect(accounts.take(try notice(#"{"drive":"quark","signedIn":true,"quarkCookie":"__kp=k; __pus=new","quarkServiceTicket":"mobile"}"#)))
    #expect(accounts.quarkCookie == "__kp=k; __pus=new" && accounts.quarkServiceTicket == "mobile")
    #expect(!accounts.take(try notice(#"{"drive":"uc","signedIn":true,"ucCookie":"ignored=1"}"#)))
    #expect(accounts.take(try notice(#"{"drive":"uc","signedIn":true,"ucCookie":"__pus=uc"}"#)))
    #expect(accounts.ucCookie == "__pus=uc")
}
