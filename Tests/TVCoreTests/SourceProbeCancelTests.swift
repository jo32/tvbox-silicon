import Foundation
import Testing
@testable import TVCore

// MARK: - Mock

/// 用 URLProtocol 拦截 `SourceProbeRunner.probe` 的 `session.data(for:)`，按请求路径返回
/// 取消 / 超时 / 404 / 200 四种结果，不真联网。
///
/// `probe` 的真实网络方式（SourceProbe.swift:392）是 `try await session.data(for: request)`；
/// URLProtocol 是 URLSession 的官方注入点，`data(for:)` 会照常走 protocol 栈，所以四种结果都能
/// 精确构造，不需要子类化 URLSession（其 async API 也不是 open，无法 override）。
private final class ProbeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch request.url?.path {
        case "/cancel":
            // P1-3：取消是一个「非结论」。data(for:) 应抛出 URLError(.cancelled)，
            // 让 probe 走进 `(error as? URLError)?.code == .cancelled` 分支。
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        case "/timeout":
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        case "/notfound":
            respond(status: 404, body: Data())
        default:
            // 64KB 的 200：elapsed 极小、kBps 远大于 64，判为 .reachable（而非 .slow）。
            respond(status: 200, body: Data(repeating: 0x41, count: 64 * 1024))
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, body: Data) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func probingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ProbeProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Tests

@Suite struct SourceProbeCancelTests {

    // MARK: P1-3 核心：取消不能污染 5 分钟缓存

    @Test func cancelledProbeIsUnknownAndWritesNoTimestamp() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/cancel")!,
            session: probingSession()
        )

        #expect(result.reachability == .unknown)
        // 不写 measuredAt → 落到构造器默认值 .distantPast，缓存里永远过期、下次必重试。
        #expect(result.measuredAt == .distantPast)
    }

    @Test func timedOutProbeIsUnreachableAndWritesTimestamp() async {
        let before = Date()
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/timeout")!,
            session: probingSession()
        )

        #expect(result.reachability == .unreachable)
        // 真实失败写「现在」：5 分钟内不重试。
        #expect(result.measuredAt >= before)
        #expect(abs(result.measuredAt.timeIntervalSinceNow) < 5)
    }

    // MARK: 缓存新鲜度语义：未知 → 重试，不可达 → 不重试

    @Test func cancelledReadingIsStaleAndWillBeRetried() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/cancel")!,
            session: probingSession()
        )
        #expect(result.reachability == .unknown)
        // .distantPast 使 now - measuredAt > 300 恒真 → 缓存视为过期，下次会重试。
        #expect(result.isStale(now: Date(), tolerance: 300))
    }

    @Test func unreachableReadingIsFreshAndWillNotBeRetried() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/timeout")!,
            session: probingSession()
        )
        #expect(result.reachability == .unreachable)
        // measuredAt 是「现在」→ 5 分钟内不重试。
        #expect(!result.isStale(now: Date(), tolerance: 300))
    }

    // MARK: 成功与状态码路径

    @Test func okResponseIsReachableWithMetrics() async {
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/ok")!,
            session: probingSession()
        )

        #expect(result.reachability == .reachable)
        #expect(result.latencyMilliseconds != nil)
        #expect((result.kilobytesPerSecond ?? 0) > 0)
        #expect(abs(result.measuredAt.timeIntervalSinceNow) < 5)
    }

    @Test func notFoundResponseIsUnreachable() async {
        // 404 不抛错：走 do 分支，状态码不在 200..<400 → .unreachable。
        let result = await SourceProbeRunner.probe(
            url: URL(string: "https://example.com/notfound")!,
            session: probingSession()
        )

        #expect(result.reachability == .unreachable)
        #expect(abs(result.measuredAt.timeIntervalSinceNow) < 5)
    }

    // MARK: isStale 严格大于边界

    @Test func staleUsesStrictlyGreaterThanTolerance() {
        let now = Date()

        let exactlyTolerance = SourceProbeResult(
            reachability: .reachable, measuredAt: now.addingTimeInterval(-300)
        )
        #expect(!exactlyTolerance.isStale(now: now, tolerance: 300))

        let justPastTolerance = SourceProbeResult(
            reachability: .reachable, measuredAt: now.addingTimeInterval(-301)
        )
        #expect(justPastTolerance.isStale(now: now, tolerance: 300))
    }
}
