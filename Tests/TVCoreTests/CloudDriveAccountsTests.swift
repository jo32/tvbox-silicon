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
