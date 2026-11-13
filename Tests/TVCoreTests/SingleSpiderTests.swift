import Foundation
import Testing
@testable import TVCore

@Test func aLonePythonSpiderImportsAsOneSource() throws {
    let script = """
    # coding=utf-8
    import sys
    sys.path.append('..')
    from base.spider import Spider

    class Spider(Spider):
        def getName(self):
            return "蝴蝶影视"
    """
    let origin = URL(string: "https://example.com/py/%E8%9D%B4%E8%9D%B6.py")!
    let config = try Subscription.parse(Data(script.utf8), origin: origin)
    #expect(config.sites.count == 1 && config.lives.isEmpty)
    let site = try #require(config.sites.first)
    #expect(site.key == "蝴蝶" && site.name == "蝴蝶影视" && site.type == 3)
    #expect(site.api == origin.absoluteString && site.runtime == .python && site.detectedRuntime == nil)
    #expect(try site.scriptURL(origin: config.origin) == origin)
    // Saved and loaded again, it is the same source.
    let saved = try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(config))
    #expect(saved.sites.first?.runtime == .python && saved.raw["sites"]?.array?.count == 1)
}

@Test func aLoneJavaScriptSpiderImportsAsOneSource() throws {
    let script = "import { Crypto } from 'assets://js/lib/cat.js';\nexport default { init, home, category, detail, play, search };\n"
    let config = try Subscription.parse(Data(script.utf8), origin: URL(string: "https://example.com/spider?id=7")!)
    let site = try #require(config.sites.first)
    #expect(site.key == "spider" && site.runtime == .javascript && site.detectedRuntime == .javascript)
    #expect(Site.isJavaScriptSpider(Data("globalThis.__JS_SPIDER__ = { homeContent() {}, detailContent() {} }".utf8)))
}

@Test func onlyRunnableScriptsImportAsSpiders() {
    let origin = URL(string: "https://example.com/a.js")!
    // A drpy rule needs a drpy engine beside it; a web page or a JAR is not a script.
    for text in ["var rule = { title: 'x', url: '/fyclass', 推荐: '*', 一级: '*', 二级: '*', detail: 1 }",
                 "<html><script>export default { detail }</script></html>",
                 "PK\u{03}\u{04}export default { detail }",
                 "function helper() { return 1 }"] {
        #expect(Subscription.singleSpider(Data(text.utf8), origin: origin) == nil)
    }
    #expect(throws: (any Error).self) { try Subscription.parse(Data("var rule = {}".utf8), origin: origin) }
}

@Test func importedFilesLoadFromTheAppNotTheNetwork() async throws {
    let picked = FileManager.default.temporaryDirectory.appending(path: "spider-\(UUID().uuidString).py")
    try Data("from base.spider import Spider\n".utf8).write(to: picked)
    defer { try? FileManager.default.removeItem(at: picked) }
    let address = try ImportedFiles.add(picked)
    defer { ImportedFiles.remove(address.absoluteString) }
    #expect(address.host() == ImportedFiles.host && address.scheme == "https")
    #expect(try WebAddress.resolve(address.absoluteString) == address)
    #expect(SubscriptionEntry(address: address.absoluteString).title == picked.lastPathComponent)
    // Every loader reads the copy: subscription imports, plugin downloads and script modules.
    guard case .subscription(let config) = try await HTTPClient().subscriptionImport(address) else { Issue.record("not a subscription"); return }
    #expect(config.sites.first?.runtime == .python)
    #expect(try await PluginDownloads(lifetime: 0).data(at: address, http: HTTPClient()) == Data("from base.spider import Spider\n".utf8))
    #expect(!ImportedFiles.isMissing(address.absoluteString))
    ImportedFiles.remove(address.absoluteString)
    await #expect(throws: (any Error).self) { try await HTTPClient().get(address) }
    // A file's address without its copy, as on another device the subscription list synced to (#842): known as
    // missing without a fetch. Other addresses never are.
    #expect(ImportedFiles.isMissing(address.absoluteString))
    #expect(!ImportedFiles.isMissing("https://example.com/a.py"))
    // Nothing outside the folder is reachable through the reserved host.
    #expect(throws: (any Error).self) { try ImportedFiles.data(at: URL(string: "https://files.yingxia.invalid/../Preferences/x.plist")!) }
    #expect(throws: (any Error).self) { try ImportedFiles.data(at: URL(string: "https://files.yingxia.invalid/a/b.py")!) }
    // A file a config added as a file names beside itself was never added: it says so, not "another device".
    let configFile = ImportedFiles.address("tv.json")
    let beside = try #require(URL(string: "./js/ss/a.py", relativeTo: configFile)?.absoluteURL)
    do { _ = try ImportedFiles.data(at: beside); Issue.record("read a file that was never added") } catch {
        #expect(error.localizedDescription.contains("./js/ss/a.py"))
        #expect(error.localizedDescription != ImportedFiles.missingMessage)
    }
    #expect(try ImportedFiles.data(at: URL(string: "https://example.com/a.py")!) == nil)
}

/// #725: an M3U or TXT live playlist picked from Files imports as one live playlist, and its channels
/// load from the app's copy.
@Test func importedLivePlaylistFilesLoadTheirChannels() async throws {
    let playlists = [
        "m3u": "#EXTM3U\n#EXTINF:-1 group-title=\"央视\",CCTV-1\nhttps://example.com/cctv1.m3u8\n",
        "txt": "央视,#genre#\nCCTV-1,https://example.com/cctv1.m3u8\n",
    ]
    for (ext, text) in playlists {
        let picked = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString).\(ext)")
        try Data(text.utf8).write(to: picked)
        defer { try? FileManager.default.removeItem(at: picked) }
        let address = try ImportedFiles.add(picked)
        defer { ImportedFiles.remove(address.absoluteString) }
        guard case .subscription(let config) = try await HTTPClient().subscriptionImport(address) else { Issue.record("not a subscription"); continue }
        #expect(config.sites.isEmpty && config.lives.count == 1)
        let live = try #require(config.lives.first)
        let channels = try await HTTPClient().channels(live)
        #expect(channels.map(\.name) == ["CCTV-1"] && channels.first?.group == "央视", "\(ext)")
    }
}
