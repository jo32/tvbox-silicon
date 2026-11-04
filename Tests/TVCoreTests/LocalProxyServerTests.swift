import Foundation
import Testing
@testable import TVCore

/// LocalProxyServer 纯函数专项：`directURL` / `proxyURL` 的路由编码与 `parse` 的解码。
/// 只锁纯逻辑，不启动 NWListener、不真连网。
@Suite struct LocalProxyServerTests {

    private let base = URL(string: "http://127.0.0.1:8080/")!

    /// 拆出编码进 path 的段。`omittingEmptySubsequences` 与 `parse` 一致，
    /// 因此空 host 段会被折叠——这里只用于断言非空段。
    private func segments(_ url: URL) -> [String] {
        url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - directURL / proxyURL 编码

    @Test func directURLEncodesHTTPSRouteSymmetrically() {
        let url = URL(string: "https://example.com:8443/a/b?q=1&r=2")!
        let out = LocalProxyServer.directURL(base: base, url: url)

        // base 的 authority 保持不变。
        #expect(out.scheme == "http")
        #expect(out.host == "127.0.0.1")
        #expect(out.port == 8080)

        // 逆运算：拆回 scheme/host/port/path/query，验证对称。
        let seg = segments(out)
        #expect(seg[0] == "d")
        #expect(seg[1] == "https")
        #expect(seg[2] == "example.com")
        #expect(seg[3] == "8443")
        #expect("/" + seg[4...].joined(separator: "/") == "/a/b")
        #expect(out.query == "q=1&r=2")
    }

    @Test func httpURLWithoutPortDefaultsTo80() {
        let url = URL(string: "http://example.com/x")!
        let out = LocalProxyServer.directURL(base: base, url: url)
        let seg = segments(out)
        #expect(seg[1] == "http")
        #expect(seg[3] == "80")
    }

    @Test func httpsURLWithoutPortDefaultsTo443() {
        let url = URL(string: "https://example.com/x")!
        let out = LocalProxyServer.directURL(base: base, url: url)
        let seg = segments(out)
        #expect(seg[1] == "https")
        #expect(seg[3] == "443")
    }

    @Test func missingSchemeDefaultsToHttp() {
        // protocol-relative：有 host 无 scheme，隔离「缺 scheme」这一个决策点。
        let url = URL(string: "//example.com/x")!
        let out = LocalProxyServer.directURL(base: base, url: url)
        let seg = segments(out)
        #expect(seg[1] == "http")
        #expect(seg[2] == "example.com")
        #expect(seg[3] == "80")
    }

    @Test func emptyPathBecomesRootSlash() {
        let url = URL(string: "http://example.com")!
        let out = LocalProxyServer.directURL(base: base, url: url)
        // 空 path 编码为 "/"：绝对路径以 "/" 结尾（URL.path 会规范化掉末尾斜杠，所以这里断言
        // absoluteString 保留 "/" 而 path 为不含尾斜杠的规范形式）。
        #expect(out.absoluteString.hasSuffix("/d/http/example.com/80/"))
        #expect(out.path == "/d/http/example.com/80")
        #expect(segments(out).count == 4)
    }

    @Test func noQueryOmitsQuestionMark() {
        let url = URL(string: "http://example.com/x")!
        let out = LocalProxyServer.directURL(base: base, url: url)
        #expect(out.query == nil)
        #expect(!out.absoluteString.contains("?"))
    }

    @Test func proxyURLUsesPPrefixDirectURLUsesDPrefix() {
        let url = URL(string: "http://example.com/")!
        let p = LocalProxyServer.proxyURL(base: base, url: url, proxyID: "px-42")
        let d = LocalProxyServer.directURL(base: base, url: url)

        let ps = segments(p)
        let ds = segments(d)
        #expect(ds[0] == "d")
        #expect(ps[0] == "p")
        #expect(ps[1] == "px-42")
        // proxyID 段让 p 比 d 多一个段，且后面各段整体右移一位。
        #expect(ps.count == ds.count + 1)
        #expect(ps[2] == "http")
        #expect(ps[3] == "example.com")
        #expect(ps[4] == "80")
    }

    // MARK: - parse 解码（决策点）

    @Test func parseDirectRouteResolvesAllFields() {
        let t = LocalProxyServer.parse("/d/https/example.com/8443/foo/bar")
        #expect(t?.proxyID == nil)
        #expect(t?.scheme == "https")
        #expect(t?.host == "example.com")
        #expect(t?.port == 8443)
        #expect(t?.path == "/foo/bar")
    }

    @Test func parseProxyRouteResolvesProxyIDWithCorrectIndex() {
        let t = LocalProxyServer.parse("/p/px-7/https/example.com/443/foo")
        #expect(t?.proxyID == "px-7")
        #expect(t?.scheme == "https")      // 从 index=2 起读，跳过了 proxyID 段
        #expect(t?.host == "example.com")
        #expect(t?.port == 443)
        #expect(t?.path == "/foo")
    }

    @Test func parseReturnsNilWhenTooFewSegments() {
        // 通用下限：parts.count < 4。
        #expect(LocalProxyServer.parse("/d/http") == nil)
        #expect(LocalProxyServer.parse("/d/http/host") == nil)
        // p 分支更严格的下限：< 5。
        #expect(LocalProxyServer.parse("/p/px/http/host") == nil)
    }

    @Test func parseReturnsNilForNonNumericPort() {
        #expect(LocalProxyServer.parse("/d/http/host/abc/") == nil)
    }

    @Test func parseReturnsNilForPortOutOfRange() {
        // UInt16 上界 65535 合法，65536 溢出返回 nil。
        #expect(LocalProxyServer.parse("/d/http/host/65535")?.port == 65535)
        #expect(LocalProxyServer.parse("/d/http/host/65536") == nil)
        #expect(LocalProxyServer.parse("/d/http/host/70000") == nil)
    }

    @Test func parseJoinsMultiSegmentPath() {
        let t = LocalProxyServer.parse("/d/http/host/80/a/b/c")
        #expect(t?.path == "/a/b/c")
    }

    @Test func parseReturnsNilForUnknownPrefix() {
        #expect(LocalProxyServer.parse("/x/http/host/80/path") == nil)
    }

    // MARK: - 边界

    @Test func encodedOutputIsAlwaysAValidDerivedURL() {
        // 病态输入（相对路径、无 scheme/host）也不会走 `?? url` 兜底：
        // `base.absoluteString` 恒为合法绝对地址，追加的 scheme/host/port/path/query
        // 全部落在 path/query 区，空格等字符会被自动百分号编码，故 URL(string:) 不会返回 nil。
        let relative = URL(string: "/no/scheme")!
        let out = LocalProxyServer.directURL(base: base, url: relative)
        #expect(out != relative)            // 未原样返回输入，说明未命中兜底分支
        #expect(out.host == "127.0.0.1")    // 沿用 base 的 authority
    }
}
