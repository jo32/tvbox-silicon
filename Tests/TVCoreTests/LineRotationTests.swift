import Foundation
import Testing
@testable import TVCore

/// 线路退避/冷却状态机（HostRotation）与「学习到能用的 host」（HostLearning）。
/// 这是「批量切换线路」和「线路生效态」的核心：一个刚失败的线路要进冷却、不能再被立即重试，
/// 一个反复成功的线路要排到前面；全部线路都在冷却时要能被识别出来，而不是当成「没有可播地址」。
@Suite struct LineRotationTests {

    private func hosts(_ names: [String]) -> [String] { names }

    // MARK: - 退避

    @Test func aFailedHostCoolsDownAndTheBackoffDoubles() {
        var rotation = HostRotation(hosts: hosts(["a", "b"]), backoff: HostRotation.Backoff(base: 5, cap: 300, jitter: 0))
        let now = Date()
        let first = rotation.fail("a", now: now)!
        #expect(first == now.addingTimeInterval(5))           // 首次失败：5s
        let second = rotation.fail("a", now: first)!
        #expect(second == first.addingTimeInterval(10))       // 第二次：翻倍到 10s
        let third = rotation.fail("a", now: second)!
        #expect(third == second.addingTimeInterval(20))       // 第三次：20s
        #expect(rotation.states["a"]?.consecutiveFailures == 3)
    }

    @Test func backoffIsCappedAndTheExponentIsBounded() {
        var rotation = HostRotation(hosts: hosts(["a"]), backoff: HostRotation.Backoff(base: 5, cap: 300, jitter: 0))
        var now = Date()
        for _ in 0..<20 { now = rotation.fail("a", now: now)! }
        let avoid = rotation.states["a"]?.avoidUntil
        // 20 次失败后 delay 早到 cap，avoidUntil 距 now 不会超过 300s（jitter=0）。
        #expect(avoid != nil)
        #expect(abs(avoid!.timeIntervalSince(now)) <= 300)
    }

    @Test func aHostInCooldownCannotBeClaimed() {
        var rotation = HostRotation(hosts: hosts(["a", "b"]))
        let now = Date()
        _ = rotation.fail("a", now: now)
        let aClaimed = rotation.begin("a", now: now)
        let bClaimed = rotation.begin("b", now: now)
        #expect(!aClaimed)                                  // 冷却中，跳过这一轮
        #expect(bClaimed)                                   // 另一条线路还能用
    }

    @Test func aSuccessfulHostIsPreferredAndClearsItsBackoff() {
        var rotation = HostRotation(hosts: hosts(["a", "b"]))
        let now = Date()
        _ = rotation.fail("a", now: now)
        rotation.succeed("a", now: now.addingTimeInterval(1))
        #expect(rotation.states["a"]?.consecutiveFailures == 0)
        #expect(rotation.states["a"]?.avoidUntil == nil)
        #expect(rotation.preferred == "a")
        #expect(rotation.available(now: now.addingTimeInterval(1)) == ["a", "b"])
    }

    // MARK: - 并发上限（避免慢线路被当死线路）

    @Test func aHostAtItsConcurrencyCapIsSkippedNotFailed() {
        var rotation = HostRotation(hosts: hosts(["a"]), maxConcurrent: 2)
        let first = rotation.begin("a")
        let second = rotation.begin("a")
        let third = rotation.begin("a")
        #expect(first)
        #expect(second)
        #expect(!third)                                     // 第 3 个探针：跳过，不是「死」
        #expect(rotation.states["a"]?.inflight == 2)
        rotation.cancel("a")
        #expect(rotation.states["a"]?.inflight == 1)
    }

    // MARK: - 排序

    @Test func rankedPutsHealthyFirstAndFailedLast() {
        var rotation = HostRotation(hosts: hosts(["bad", "good", "untried"]))
        let now = Date()
        _ = rotation.fail("bad", now: now)
        rotation.succeed("good", now: now)
        // good 无失败且成功过 → 最前；untried 无失败但没成功 → 次之；bad 失败 → 最后。
        let ranked = rotation.ranked(now: now)
        #expect(ranked.first == "good")
        #expect(ranked.last == "bad")
    }

    @Test func allCoolingDownIsDistinctFromNothingToPlay() {
        var rotation = HostRotation(hosts: hosts(["a", "b"]))
        let now = Date()
        _ = rotation.fail("a", now: now)
        #expect(!rotation.allCoolingDown(now: now))           // b 还能用
        _ = rotation.fail("b", now: now)
        #expect(rotation.allCoolingDown(now: now))            // 全在冷却
        #expect(rotation.available(now: now).isEmpty)
    }

    // MARK: - replace 保留幸存状态 + 重复 host 不崩

    @Test func replaceKeepsStateForSurvivingHostsAndDropsTheRest() {
        var rotation = HostRotation(hosts: hosts(["a", "b"]))
        let now = Date()
        _ = rotation.fail("a", now: now)
        rotation.succeed("b", now: now)
        rotation.replace(hosts: hosts(["b", "c"]))
        #expect(rotation.states["b"]?.successes == 1)         // b 的状态保留
        #expect(rotation.states["c"] != nil)                  // 新 host 有空状态
        #expect(rotation.states["a"] == nil)                  // 被移除的 a 状态丢弃
    }

    @Test func duplicateHostsDoNotCrash() {
        // P2-7：Dictionary(uniqueKeysWithValues:) 遇重复 host 直接 fatalError；已改为逐个写入。
        // hosts 数组保留原始顺序（不去重），但 states 字典不 crash、重复 key 后写覆盖。
        let rotation = HostRotation(hosts: hosts(["a", "a", "b"]))
        #expect(rotation.hosts.count == 3)          // 原始列表不去重
        #expect(rotation.states.count == 2)         // 状态按 host 去重：a、b 各一条
        #expect(rotation.states["a"] != nil)
        #expect(rotation.states["b"] != nil)
    }

    // MARK: - HostLearning

    @Test func aLearnedHostIsTriedFirstInsideItsTrustWindow() {
        var learning = HostLearning()
        let now = Date()
        learning.learn("a", at: now)
        #expect(learning.firstChoice(now: now.addingTimeInterval(10)) == "a")
        // 信任窗口（默认 1h）过期后不再优先。
        #expect(learning.firstChoice(now: now.addingTimeInterval(3601)) == nil)
    }

    @Test func rejectedHostsSortLastAndLearningIsForgotten() {
        var learning = HostLearning()
        let now = Date()
        learning.learn("good", at: now)
        learning.reject("bad", reason: "timeout", at: now)
        let ordered = learning.prefer(["untried", "bad", "good"], now: now)
        #expect(ordered.first == "good")
        #expect(ordered.last == "bad")
    }
}
