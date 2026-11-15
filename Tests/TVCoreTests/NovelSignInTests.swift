import Foundation
import Testing
@testable import TVCore

/// A Legado source with a sign-in form (#970): its form, a button's script, a wrong and a right password, the token
/// login() keeps for the source's requests, and signing out. Everything stays in the engine; no network.
@Test func novelSourceSignsInWithItsForm() async throws {
    prepareNovelSignInTests()
    let form = #"[{"name":"账号","type":"text"},{"name":"密码","type":"password"},{"name":"线路","type":"select","chars":["A","B"]},"#
        + #"{"name":"发送验证码","type":"button","action":"java.toast('code for ' + result.get('账号')); java.upLoginData({'线路': 'B'})"},{"name":"说明","type":"label"}]"#
    let login = """
    function login() {
        var info = source.getLoginInfoMap();
        if (info['密码'] !== 'secret') throw '密码错误';
        source.putLoginHeader(JSON.stringify({ Authorization: 'Bearer ' + info.get('账号') }));
        java.toast('登录成功');
    }
    """
    let key = "https://signin-\(UUID().uuidString.prefix(8)).example"
    let source = try #require(NovelSource(object: ["bookSourceUrl": key, "bookSourceName": "Sign-in test", "loginUi": form, "loginUrl": login]))
    #expect(source.signsIn)
    let runtime = NovelRuntime.shared

    var shown = try await runtime.signInForm(source)
    #expect(shown.rows.map(\.type) == ["text", "password", "select", "button", "label"])
    #expect(shown.values == ["账号": "", "密码": "", "线路": "A"])
    #expect(!shown.signedIn && shown.web == nil)

    var values = shown.values
    values["账号"] = "me"
    let pressed = try await runtime.signInAction(source, values: values, action: try #require(shown.rows[3].action))
    #expect(pressed.said == ["code for me"])
    #expect(pressed.values?["线路"] == "B")

    values["密码"] = "wrong"
    await #expect { try await runtime.signIn(source, values: values) } throws: { "\($0.localizedDescription)".contains("密码错误") }
    values["密码"] = "secret"
    #expect(try await runtime.signIn(source, values: values).said == ["登录成功"])
    shown = try await runtime.signInForm(source)
    #expect(shown.signedIn && shown.values["账号"] == "me")
    #expect(NovelStore.logins.values(for: key)["info"]?.contains("secret") == true)
    try await Task.sleep(for: .milliseconds(300))
    let profiles = try FileManager.default.contentsOfDirectory(at: NovelRuntime.profiles, includingPropertiesForKeys: nil)
    #expect(try profiles.allSatisfy { !String(decoding: try Data(contentsOf: $0), as: UTF8.self).contains("secret") })
    // The token goes with the source's requests.
    let header = try await runtime.signInAction(source, values: shown.values, action: "java.toast(source.getHeaderMap(true).Authorization)")
    #expect(header.said == ["Bearer me"])

    try await runtime.signOut(source)
    shown = try await runtime.signInForm(source)
    #expect(!shown.signedIn && shown.values["账号"] == "")
    #expect(NovelStore.logins.values(for: key).isEmpty)
}

/// A source whose `loginUrl` is a web page signs in there; the page's cookies then go with its requests.
@Test func novelSourceSignsInOnItsWebsite() async throws {
    prepareNovelSignInTests()
    let host = "web-\(UUID().uuidString.prefix(8).lowercased()).example"
    let source = try #require(NovelSource(object: ["bookSourceUrl": "https://\(host)", "bookSourceName": "Web sign-in", "loginUrl": "https://\(host)/login.php"]))
    #expect(source.signsIn)
    let runtime = NovelRuntime.shared
    var shown = try await runtime.signInForm(source)
    #expect(shown.rows.isEmpty && shown.web == "https://\(host)/login.php" && !shown.signedIn)
    try await runtime.keepSignInCookies(source, page: "https://\(host)/login.php", cookies: "sid=1; user=me")
    shown = try await runtime.signInForm(source)
    #expect(shown.signedIn)
    let sent = try await runtime.signInAction(source, values: [:], action: "java.toast(cookie.getCookie('https://www.\(host)/book/1'))")
    #expect(sent.said.first?.contains("sid=1") == true)
    try await runtime.signOut(source)
    shown = try await runtime.signInForm(source)
    #expect(!shown.signedIn)
    let after = try await runtime.signInAction(source, values: [:], action: "java.toast(cookie.getCookie('https://\(host)/') || 'none')")
    #expect(after.said == ["none"])
}

/// Profiles in a temporary folder, logins in memory rather than the Keychain.
private func prepareNovelSignInTests() {
    if NovelRuntime.profilesRoot == nil {
        NovelRuntime.profilesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("novel-signin-tests-\(UUID().uuidString)")
    }
    if !(NovelStore.logins is MemorySubtitleCredentials) { NovelStore.logins = MemorySubtitleCredentials() }
}

/// A source without a form or a sign-in page has nothing to ask (a login script alone, as in Legado).
@Test func novelSourceWithoutSignIn() throws {
    let plain = try #require(NovelSource(object: ["bookSourceUrl": "https://plain.example", "loginUi": "[ ]", "loginUrl": ""]))
    #expect(!plain.signsIn)
    let script = try #require(NovelSource(object: ["bookSourceUrl": "https://script.example", "loginUrl": "function login() { }"]))
    #expect(!script.signsIn)
}
