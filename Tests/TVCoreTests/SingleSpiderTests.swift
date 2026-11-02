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
    ImportedFiles.remove(address.absoluteString)
    await #expect(throws: (any Error).self) { try await HTTPClient().get(address) }
    // Nothing outside the folder is reachable through the reserved host.
    #expect(throws: (any Error).self) { try ImportedFiles.data(at: URL(string: "https://files.yingxia.invalid/../Preferences/x.plist")!) }
    #expect(throws: (any Error).self) { try ImportedFiles.data(at: URL(string: "https://files.yingxia.invalid/a/b.py")!) }
    #expect(try ImportedFiles.data(at: URL(string: "https://example.com/a.py")!) == nil)
}
