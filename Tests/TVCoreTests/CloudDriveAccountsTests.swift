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

/// Sign-in codes open in the drive's own app on this phone: Quark and UC on the code's page, Baidu Netdisk at its start.
@Test func signInCodesOpenTheDrivesApp() throws {
    let page = "https://su.quark.cn/4_eMHBJ?token=a+b&client_id=532&uc_biz_str=S%3Acustom"
    let quark = try #require(DriveAppLink.target(drive: "quark", page: page, pad: false))
    #expect(quark.opensPage && quark.urls.count == 2)
    #expect(quark.urls[0].absoluteString == "qklink://www.uc.cn/656bdcddd4758b39206a8181c91a7d14?src_ch=yingxia&action=open_url&url=https%3A%2F%2Fsu.quark.cn%2F4_eMHBJ%3Ftoken%3Da%2Bb%26client_id%3D532%26uc_biz_str%3DS%253Acustom")
    #expect(quark.urls[1].scheme == "qkcloudlink")
    #expect(DriveAppLink.target(drive: "quark", page: page, pad: true)?.urls[0].absoluteString.contains("/e7d506280d7f0140e2ee4ba5b030d82d?") == true)
    let uc = try #require(DriveAppLink.target(drive: "ucToken", page: "https://su.uc.cn/x?token=1", pad: false))
    #expect(uc.urls.map(\.scheme) == ["uclink", "ucbrowser"] && uc.urls[1].absoluteString == "ucbrowser://https://su.uc.cn/x?token=1")
    // Baidu's code is an image: its app only opens.
    let baidu = try #require(DriveAppLink.target(drive: "baidu", page: nil, pad: false))
    #expect(!baidu.opensPage && baidu.urls.first?.scheme == "bdnetdisk")
    #expect(DriveAppLink.target(drive: "quark", page: nil, pad: false) == nil)
    #expect(DriveAppLink.target(drive: "pan115", page: "https://115.com/scan/x", pad: false) == nil)
}
