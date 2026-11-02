import Foundation
import Testing
@testable import TVCore

private actor Hosts {
    var list: [String] = []
    func add(_ url: URL) { list.append(url.host() ?? "-") }
}

@Test func gitHubFilesMapToMirrorsAndKeepPrivateAddressesAway() throws {
    let file = URL(string: "https://raw.githubusercontent.com/o/r/refs/heads/main/lib/%E8%99%8E.js")!
    #expect(GitHubMirrors.mirrors(of: file).map(\.absoluteString) == [
        "https://gcore.jsdelivr.net/gh/o/r@main/lib/%E8%99%8E.js", "https://fastly.jsdelivr.net/gh/o/r@main/lib/%E8%99%8E.js",
        "https://gh-proxy.org/\(file.absoluteString)", "https://gh-proxy.com/\(file.absoluteString)",
        "https://ghfast.top/\(file.absoluteString)"])
    // A configuration's own GitHub proxy (饭太硬 uses git.yylx.win) still names the GitHub file.
    #expect(GitHubMirrors.gitHubFile(URL(string: "https://git.yylx.win/https://raw.githubusercontent.com/o/r/main/a.js")!)?.absoluteString
            == "https://raw.githubusercontent.com/o/r/main/a.js")
    #expect(GitHubMirrors.gitHubFile(URL(string: "https://raw.githubusercontent.com/o/r/main/a.json?token=secret")!) == nil)
    #expect(GitHubMirrors.gitHubFile(URL(string: "https://example.com/o/r/main/a.json")!) == nil)
}

@Test func unreachableGitHubFallsBackToAMirrorAndRemembersIt() async throws {
    let mirrors = GitHubMirrors(), hosts = Hosts()
    let load: @Sendable (URL, TimeInterval) async throws -> String = { url, timeout in
        await hosts.add(url)
        #expect(timeout == GitHubMirrors.patience)
        switch url.host() {
        case "raw.githubusercontent.com": throw URLError(.timedOut)
        case "gcore.jsdelivr.net": throw URLError(.cannotConnectToHost)
        default: return url.absoluteString
        }
    }
    #expect(try await mirrors.fetch(URL(string: "https://raw.githubusercontent.com/o/r/main/tv.json")!, timeout: 25, load)
            == "https://fastly.jsdelivr.net/gh/o/r@main/tv.json")
    // The next file skips GitHub for now and starts with the mirror that worked.
    #expect(try await mirrors.fetch(URL(string: "https://raw.githubusercontent.com/o/r/main/a.js")!, timeout: 25, load)
            == "https://fastly.jsdelivr.net/gh/o/r@main/a.js")
    #expect(await hosts.list == ["raw.githubusercontent.com", "gcore.jsdelivr.net", "fastly.jsdelivr.net", "fastly.jsdelivr.net"])
}

@Test func gitHubAnswersAndPrivateAddressesNeverReachMirrors() async throws {
    let hosts = Hosts()
    let load: @Sendable (URL, TimeInterval) async throws -> String = { url, _ in
        await hosts.add(url)
        if url.host() == "raw.githubusercontent.com" && url.query == nil { throw TVError.http(404) }
        throw URLError(.timedOut)
    }
    await #expect(throws: TVError.self) { try await GitHubMirrors().fetch(URL(string: "https://raw.githubusercontent.com/o/r/main/gone.json")!, timeout: 25, load) }
    await #expect(throws: URLError.self) { try await GitHubMirrors().fetch(URL(string: "https://raw.githubusercontent.com/o/r/main/a.json?token=x")!, timeout: 25, load) }
    #expect(await hosts.list == ["raw.githubusercontent.com", "raw.githubusercontent.com"])
}

@Test func aConfigurationsOwnGitHubProxyFallsBackToGitHub() async throws {
    let hosts = Hosts()
    let load: @Sendable (URL, TimeInterval) async throws -> String = { url, _ in
        await hosts.add(url)
        if url.host() == "git.example.net" { throw TVError.http(404) }
        return url.absoluteString
    }
    let wrapped = URL(string: "https://git.example.net/https://raw.githubusercontent.com/o/r/refs/heads/main/a.js")!
    #expect(try await GitHubMirrors().fetch(wrapped, timeout: 25, load) == "https://raw.githubusercontent.com/o/r/refs/heads/main/a.js")
    #expect(await hosts.list == ["git.example.net", "raw.githubusercontent.com"])
}

/// GitHub times out; gcore.jsdelivr.net answers.
private final class BlockedGitHubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host() == "gcore.jsdelivr.net" else { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let body = url.path.hasSuffix(".json") ? #"{"spider":"./jar/a.jar","sites":[{"key":"a","type":3,"api":"csp_A"}]}"# : "plugin bytes"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func subscriptionsAndPluginsFromAnUnreachableGitHubLoadThroughAMirror() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BlockedGitHubProtocol.self]
    let http = HTTPClient(session: URLSession(configuration: configuration), mirrors: GitHubMirrors())
    let url = URL(string: "https://raw.githubusercontent.com/o/r/main/tv.json")!
    let sub = try await http.subscription(url)
    #expect(sub.sites.map(\.key) == ["a"])
    #expect(sub.origin == url)
    let jar = try #require(sub.spiderURL)
    #expect(jar.absoluteString == "https://raw.githubusercontent.com/o/r/main/jar/a.jar")
    let plugin = try await PluginDownloads(directory: nil).data(at: jar, http: http)
    #expect(String(decoding: plugin, as: UTF8.self) == "plugin bytes")
}
