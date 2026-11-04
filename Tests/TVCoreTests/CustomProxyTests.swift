import Foundation
import Testing
@testable import TVCore

/// 自定义代理：凭据混淆编解码、路由的按源解析与持久化。
/// 隧道握手（HTTP CONNECT / SOCKS5）本身要真网络，不在这里测；这里锁定的是纯逻辑：
/// 凭据别明文落盘、旧版无标记值能读回、按源路由的读写与删除联动。
@Suite struct CustomProxyTests {

    private func clean(_ name: String) -> UserDefaults {
        let suite = "TVCoreTests.CustomProxy." + name
        let box = UserDefaults(suiteName: suite)!
        box.removePersistentDomain(forName: suite)
        return box
    }

    private let origin = URL(string: "https://sub.example/list.json")!
    private let sourceKey = "source-a"

    // MARK: - 凭据混淆

    @Test func credentialsRoundTripThroughTheObfuscationLayer() throws {
        let endpoint = CustomProxyEndpoint(name: "my proxy", scheme: .socks5, host: "1.2.3.4", port: 1080,
                                           username: "alice", password: "s3cret")
        let data = try JSONEncoder().encode([endpoint])
        let raw = String(decoding: data, as: UTF8.self)
        // 明文口令绝不落盘。
        #expect(!raw.contains("alice"))
        #expect(!raw.contains("s3cret"))

        let decoded = try JSONDecoder().decode([CustomProxyEndpoint].self, from: data)
        #expect(decoded.first?.username == "alice")
        #expect(decoded.first?.password == "s3cret")
    }

    @Test func legacyPlaintextCredentialsStillDecode() throws {
        // 旧版无 "v1:" 标记的值是明文，反混淆要原样返回而不是解出乱码。
        let json = #"[{"id":"x","name":"p","scheme":"http","host":"1.2.3.4","port":8080,"username":"bob","password":"pw"}]"#
        let decoded = try JSONDecoder().decode([CustomProxyEndpoint].self, from: Data(json.utf8))
        #expect(decoded.first?.username == "bob")
        #expect(decoded.first?.password == "pw")
    }

    @Test func anInvalidHostOrPortHasNoAddress() {
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "", port: 80).address == nil)
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "1.2.3.4", port: 0).address == nil)
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "1.2.3.4", port: 70000).address == nil)
        #expect(CustomProxyEndpoint(name: "e", scheme: .http, host: "1.2.3.4", port: 8080).address == "1.2.3.4")
    }

    // MARK: - 路由的按源读写

    @Test func aRouteIsReadBackPerOriginAndSource() {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .http, host: "1.2.3.4", port: 8080)
        store.upsert(proxy)
        store.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)
        #expect(store.route(origin: origin, sourceKey: sourceKey).proxyID == proxy.id)
        // 不同 origin 或 source 不受影响。
        #expect(store.route(origin: URL(string: "https://other.example/x.json")!, sourceKey: sourceKey) == .direct)
        #expect(store.route(origin: origin, sourceKey: "source-b") == .direct)
    }

    @Test func removingAnEndpointResetsRoutesThatUsedIt() {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .http, host: "1.2.3.4", port: 8080)
        store.upsert(proxy)
        store.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)
        store.removeEndpoint(id: proxy.id)
        #expect(store.route(origin: origin, sourceKey: sourceKey) == .direct)
    }

    @Test func endpointsAndRoutesSurviveRelaunch() {
        let box = clean(#function)
        let proxy = CustomProxyEndpoint(name: "p", scheme: .http, host: "1.2.3.4", port: 8080)
        let first = CustomProxyStore(defaults: box)
        first.upsert(proxy)
        first.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey)

        let second = CustomProxyStore(defaults: box)
        #expect(second.endpoints.count == 1)
        #expect(second.route(origin: origin, sourceKey: sourceKey).proxyID == proxy.id)
    }

    // MARK: - 隧道目标（纯构造，不连网）

    @Test func tunnelReturnsNilForDirectOrMissingProxy() throws {
        let box = clean(#function)
        let store = CustomProxyStore(defaults: box)
        #expect(try store.tunnel(origin: origin, sourceKey: sourceKey, targetHost: "x.com", targetPort: 443) == nil)
        // 指到不存在的 proxy id 也返回 nil（路由失效回落到直连）。
        store.setRoute(.proxy("missing"), origin: origin, sourceKey: sourceKey)
        #expect(try store.tunnel(origin: origin, sourceKey: sourceKey, targetHost: "x.com", targetPort: 443) == nil)
    }
}
