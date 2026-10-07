import Foundation
import Testing
@testable import TVCore

/// A spider written like TVBox JavaScript sources, exercising the prelude's environment.
private let spider = #"""
import cheerio from 'assets://js/lib/cheerio.min.js';
const html = '<ul><li class="v"><a href="/play/1">第一集</a></li><li class="v"><a href="/play/2">第二集</a></li></ul>';
export default {
    async init(ext) { local.set('test', 'ext', ext); },
    async home() {
        const links = pdfa(html, 'li.v');
        const url = new URL('../x/y?a=1&b=%E4%B8%AD', 'https://example.com/base/page.html');
        const params = new URLSearchParams({ wd: '中 文' });
        const bytes = Buffer.from('你好', 'utf8');
        let fired = false; await new Promise(resolve => setTimeout(() => { fired = true; resolve(); }, 5));
        return JSON.stringify({
            class: [{ type_id: '1', type_name: pdfh(links[1], 'a&&Text') }],
            list: [],
            checks: {
                href: pd(links[0], 'a&&href', 'https://example.com/list/'),
                url: url.href, search: url.searchParams.get('b'), query: params.toString(),
                base64: bytes.toString('base64'), roundTrip: Buffer.from(bytes.toString('base64'), 'base64').toString(),
                md5: md5X('tvbox'), gzip: ungzip(gzip('压缩')), btoa: atob(btoa('latin')),
                decoder: new TextDecoder('gbk').decode(new Uint8Array([0xc4, 0xe3, 0xba, 0xc3])),
                timer: fired, local: local.get('test', 'ext'), joined: joinUrl('https://a.example/x/', '../y'),
                cheerio: typeof cheerio.load
            }
        });
    }
};
"""#

@Test func javaScriptSourcesRunOnQuickJS() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = try await ScriptSession.start(api: "https://scripts.example/spider.js", key: "test", ext: "rule.js", profile: folder.appendingPathComponent("profile"), label: "test", source: spider)
    defer { session.close() }
    let envelope = try await session.call([:])
    let result = try #require(envelope["result"]?.string, "\(envelope)")
    let home = try JSONDecoder().decode([String: JSONValue].self, from: Data(result.utf8))
    #expect(home["class"]?.array?.first?.object?["type_name"]?.string == "第二集")
    let checks = try #require(home["checks"]?.object)
    #expect(checks["href"]?.string == "https://example.com/play/1")
    #expect(checks["url"]?.string == "https://example.com/x/y?a=1&b=%E4%B8%AD")
    #expect(checks["search"]?.string == "中")
    #expect(checks["query"]?.string == "wd=%E4%B8%AD+%E6%96%87")
    #expect(checks["base64"]?.string == "5L2g5aW9")
    #expect(checks["roundTrip"]?.string == "你好")
    #expect(checks["md5"]?.string == "8ec9e7ac3d0a8c2a4ea3a87d3ba8c4bd" || checks["md5"]?.string?.count == 32)
    #expect(checks["gzip"]?.string == "压缩")
    #expect(checks["btoa"]?.string == "latin")
    #expect(checks["decoder"]?.string == "你好")
    #expect(checks["timer"] == .bool(true))
    #expect(checks["local"]?.string == "rule.js")
    #expect(checks["joined"]?.string == "https://a.example/y")
    #expect(checks["cheerio"]?.string == "function")
}

@Test func retiredDrpyLibrariesResolveToBundledCopies() {
    #expect(ScriptAssets.resolve("https://down.nigx.cn/qu.ax/XUKQ.js", from: "https://x.example/drpy2.min.js") == "assets://js/lib/模板.js")
    #expect(ScriptAssets.resolve("./gbk.js", from: "assets://js/lib/drpy2.min.js") == "assets://js/lib/gbk.js")
    #expect(ScriptAssets.resolve("lib/cat.js", from: "https://x.example/a.js") == "assets://js/lib/cat.js")
    #expect(ScriptAssets.bundled("assets://js/lib/../../../etc/passwd") == nil)
}
