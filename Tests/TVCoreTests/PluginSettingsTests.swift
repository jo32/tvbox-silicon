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

/// aowu's 哔哩配置 window as the JAR host describes it: the plugin's own views, drawn by the app.
@Test func pluginWindowsDecodeTheirViews() throws {
    let json = ##"{"msg":"bili","notices":["正在获取二维码..."],"ui":{"links":["bilibili://login"],"windows":[{"id":13,"cancelable":true,"root":{"id":11,"type":"stack","axis":"v","background":"#FFFFFFFF","children":[{"id":16,"type":"stack","axis":"h","tappable":true,"selected":true,"background":"#FFD6E9FF","fillWidth":true,"children":[{"id":18,"type":"text","text":"扫码登录","size":16,"bold":true,"color":"#FF222222","gravity":17}]},{"id":40,"type":"input","text":"","hint":"Cookie","secure":true},{"id":33,"type":"image","image":"AAEC","width":240,"height":240}]}}]}}"##
    let screen = PluginScreen(json: try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8)))
    #expect(screen.message == "bili")
    #expect(screen.notices == ["正在获取二维码..."])
    #expect(screen.links == [URL(string: "bilibili://login")!])
    let window = try #require(screen.windows.first)
    #expect(window.id == 13 && (window.surface?.luminance ?? 0) > 0.99)
    let root = try #require(window.root)
    #expect(root.children.map(\.kind) == [.stack, .input, .image])
    let row = root.children[0]
    #expect(row.tappable && row.selected && row.axis == .h && row.fillWidth)
    #expect(row.children[0].text == "扫码登录" && row.children[0].bold && row.children[0].centered && row.children[0].size == 16)
    #expect(root.children[1].secure && root.children[1].hint == "Cookie")
    #expect(root.children[2].image == Data([0, 1, 2]) && root.children[2].width == 240)
}

@Test func pluginEventsCarryTypedValues() throws {
    let event = PluginEvent(window: 13, kind: .click, view: 16, values: [40: .text("SESSDATA=1"), 41: .on(true)])
    let sent = try JSONSerialization.jsonObject(with: Data(event.json.utf8)) as? [String: Any]
    #expect(sent?["window"] as? Int == 13 && sent?["kind"] as? String == "click" && sent?["view"] as? Int == 16)
    let values = sent?["values"] as? [String: Any]
    #expect(values?["40"] as? String == "SESSDATA=1" && values?["41"] as? Bool == true)
}

/// aowu 弹幕颜色 draws a color wheel the viewer touches; lytvs copies cookies; a plugin that dies says why.
@Test func pluginScreensCarryTouchClipboardAndErrors() throws {
    let json = ##"{"error":"NoSuchMethodError: colorToHSV","ui":{"clipboard":"__puus=1","windows":[{"id":2,"root":{"id":5,"type":"image","image":"AAEC","touch":true}}]}}"##
    let screen = PluginScreen(json: try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8)))
    #expect(screen.clipboard == "__puus=1" && screen.error == "NoSuchMethodError: colorToHSV")
    #expect(screen.windows.first?.root?.touch == true)
    let event = PluginEvent(window: 2, kind: .touch, view: 5, x: 1.4, y: 0.25)
    let sent = try JSONSerialization.jsonObject(with: Data(event.json.utf8)) as? [String: Any]
    #expect(sent?["kind"] as? String == "touch" && sent?["x"] as? Double == 1 && sent?["y"] as? Double == 0.25)
}

/// lytvs 设置哔哩Cookie › APP授权 opens Bilibili's confirmation page, which needs the Bilibili app's account.
@Test func bilibiliConfirmationPagesOpenInTheApp() throws {
    let page = URL(string: "https://account.bilibili.com/h5/account-h5/auth/scan-web?navhide=1&callback=close&qrcode_key=abc&from=main-mini")!
    let target = try #require(DriveAppLink.app(opening: page))
    #expect(target.urls.first?.absoluteString == "bilibili://browser?url=https%3A%2F%2Faccount.bilibili.com%2Fh5%2Faccount-h5%2Fauth%2Fscan-web%3Fnavhide%3D1%26callback%3Dclose%26qrcode_key%3Dabc%26from%3Dmain-mini")
    #expect(DriveAppLink.app(opening: URL(string: "https://www.bilibili.com/video/BV1")!) == nil)
}
