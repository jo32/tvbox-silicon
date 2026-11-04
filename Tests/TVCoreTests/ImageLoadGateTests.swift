import Foundation
import Testing
@testable import TVCore

/// 图片并发闸门（ImageLoadGate）：滚动时只放少量解码、超出排队而非丢弃、队列满则跳过，
/// 以及 P2-15 修掉的 `cancelAll` 计数下溢（恢复 waiter 却没给 inFlight 记账 → 闸门被绕过）。
@Suite struct ImageLoadGateTests {

    @Test func idleAllowsManyAndScrollingRestricts() async {
        let gate = ImageLoadGate(policy: .init(idleLimit: 8, scrollingLimit: 2))
        #expect(gate.currentLimit == 8)
        gate.setScrolling(true)
        #expect(gate.currentLimit == 2)
        gate.setScrolling(false)
        #expect(gate.currentLimit == 8)
    }

    @Test func scrollingAllowsOnlyTheLimitAndQueuesTheRest() async {
        let gate = ImageLoadGate(policy: .init(idleLimit: 8, scrollingLimit: 2))
        gate.setScrolling(true)
        // 前两个立刻放行。
        #expect(await gate.begin())
        #expect(await gate.begin())
        // 第三个排队（不返回 false，而是等）。
        let third = Task { await gate.begin() }
        #expect(gate.running == 2)
        // 释放一个，第三个被唤醒。
        gate.finish()
        #expect(await third.value == true)
        gate.finish(); gate.finish()
        #expect(gate.running == 0)
    }

    @Test func aFullQueueRefusesInsteadOfGrowingUnbounded() async {
        let gate = ImageLoadGate(policy: .init(idleLimit: 1, scrollingLimit: 1))
        gate.setScrolling(true)
        gate.maxWaiters = 1
        #expect(await gate.begin())            // 占满唯一槽位
        let queued = Task { await gate.begin() } // 第一个 waiter 入队（会挂起等槽位）
        while gate.queued == 0 { await Task.yield() }
        #expect(!(await gate.begin()))         // 队列已满 → 拒绝，不排队
        #expect(gate.skipped == 1)
        // 释放槽位，把挂起的 waiter 唤醒，避免泄漏。
        gate.finish()
        _ = await queued.value
        gate.finish()
        #expect(gate.running == 0)
    }

    @Test func cancelAllOnAnEmptyGateIsANoOp() async {
        // cancelAll 把每个恢复的 waiter 都补一次 inFlight 记账；空队列时不该有任何副作用。
        let gate = ImageLoadGate(policy: .init(idleLimit: 2, scrollingLimit: 2))
        gate.setScrolling(true)
        gate.cancelAll()
        #expect(gate.running == 0)
        #expect(await gate.begin())
        gate.finish()
        #expect(gate.running == 0)
    }

    @Test func finishingWithoutABeginCannotGoNegative() {
        // P2-15 的底线：finish() 有 max(0, …) 兜底，即使被多调也不会把计数扣成负数，
        // 从而让「闸门被绕过」的 bug 无处藏身。
        let gate = ImageLoadGate(policy: .init(idleLimit: 1, scrollingLimit: 1))
        gate.finish()
        gate.finish()
        #expect(gate.running == 0)
    }
}

/// 源覆盖（SourceOverrides）：对订阅子源的改名与 API 覆盖，覆盖了文件内容但不改文件本身。
@Suite @MainActor struct SourceOverridesTests {

    private func clean(_ name: String) -> UserDefaults {
        let suite = "TVCoreTests.SourceOverrides." + name
        let box = UserDefaults(suiteName: suite)!
        box.removePersistentDomain(forName: suite)
        return box
    }

    private let origin = URL(string: "https://sub.example/list.json")!
    private let site = Site(key: "movie", name: "Movie", type: 1, api: "https://api.example/movie",
                            raw: ["key": .string("movie")])

    @Test func aRenameAndAPIOverrideApplyToTheSite() {
        let box = clean(#function)
        let store = SourceOverrides(defaults: box)
        store.rename(site, origin: origin, to: "  Renamed  ")
        store.setAPI(site, origin: origin, to: " https://api.example/v2 ")

        let applied = store.apply(to: site, origin: origin)
        #expect(applied.name == "Renamed")                 // 去掉首尾空白
        #expect(applied.api == "https://api.example/v2")
    }

    @Test func clearingBothEditsRemovesTheRecord() {
        let box = clean(#function)
        let store = SourceOverrides(defaults: box)
        store.rename(site, origin: origin, to: "Renamed")
        store.rename(site, origin: origin, to: "  ")       // 空名 → 清空 name
        #expect(store.override(for: site, origin: origin) == nil)
        #expect(store.savedValues.isEmpty)
    }

    @Test func overridesSurviveRelaunch() {
        let box = clean(#function)
        let first = SourceOverrides(defaults: box)
        first.rename(site, origin: origin, to: "Renamed")

        let second = SourceOverrides(defaults: box)
        #expect(second.apply(to: site, origin: origin).name == "Renamed")
    }
}
