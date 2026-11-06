import Foundation
import Testing
@testable import TVCore

private let origin = URL(string: "https://one.example/fty.json")!

/// FTY 我的云盘┃配置: its category lists plugin settings as titles; opening one as details crashed the plugin.
@Test func listedPluginSettingsKeepTheirAction() throws {
    let page = CatalogPage(json: ["list": .array([
        .object(["vod_id": .string("0000"), "vod_name": .string("登入自己网盘"), "action": .string("LoginShow")]),
        .object(["vod_id": .string("42"), "vod_name": .string("A Film")]),
    ])], origin: origin)
    #expect(page.videos.map(\.action) == ["LoginShow", nil])
    let blank = try #require(Video(json: ["vod_id": .string("1"), "action": .string(" ")], origin: origin))
    #expect(blank.action == nil)
    // History and favorites decode videos saved before the field existed.
    let saved = try JSONDecoder().decode(Video.self, from: Data(#"{"id":"1","name":"x","posterHeaders":{},"remarks":"","synopsis":"","episodes":[]}"#.utf8))
    #expect(saved.action == nil)
}

@Test func pluginActionsMapToDriveSettings() {
    #expect(PluginAction("LoginShow") == .signIn)
    #expect(PluginAction("pushCkShow") == .signIn)
    #expect(PluginAction("quarkClean") == .signOut(drive: "quark"))
    #expect(PluginAction("ucClean") == .signOut(drive: "uc"))
    #expect(PluginAction("BdClean") == .signOut(drive: "baidu"))
    #expect(PluginAction("aliClean") == .signOut(drive: "aliyun"))
    #expect(PluginAction("panSortShow") == .run)
    #expect(PluginAction("panSourceSortShow") == .run)
    #expect(PluginAction("cacheClean") == .run)
}
