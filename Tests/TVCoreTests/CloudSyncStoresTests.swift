import Foundation
import Testing
@testable import TVCore

/// P2-9 的四个 store 与 CloudSync 的对接契约。
///
/// 契约形态（经 `CloudSync.swift` 与 `App/Store.swift:847-881` 核对）是**结构性约定**，而非某个
/// `CloudSyncValue`/`CloudSyncStore` 协议：
/// - `CloudSync.register(key:current:apply:)` 要求 `current: () -> [String: Value]` 与
///   `apply: ([CloudSyncItem<Value>]) -> Void`，其中 `Value: Codable & Equatable & Sendable`。
/// - 每个 store 以 `savedValues: [String: Value]` 充当 `current`，以 `adopt([String: Value])` 充当
///   `apply`（`Store.dictionary(_:)` 把 `[CloudSyncItem<Value>]` 折回字典再交给 `adopt`）。
/// - `onChange: (@MainActor () -> Void)?` 被接成 `sync.changed(key)`，触发一次延迟上云。
///
/// 因此本文件的独特价值是测「savedValues 序列化 → adopt 反序列化 → 状态往返一致」与「onChange
/// 触发同步」这层对接，而非四个 store 各自的内部逻辑（已被 SourceRelayTests / ImageLoadGateTests /
/// LineSettingsTests / SourceReassignmentTests 覆盖）。
private func clean(_ name: String) -> UserDefaults {
    let suite = "TVCoreTests.CloudSyncStores." + name
    let box = UserDefaults(suiteName: suite)!
    box.removePersistentDomain(forName: suite)
    return box
}

private let origin = URL(string: "https://sub.example/list.json")!
private let site = Site(key: "movie", name: "Movie", type: 1, api: "https://api.example/movie",
                        raw: ["key": .string("movie")])
private let sourceKey = "source-a"
private let flag = "线路1"

/// 跨订阅拖动（SourceReassignment）用到的一处订阅地址与两个源。
private let address = "https://short.example/moved"
private let firstOrigin = URL(string: "https://cdn.example/a.json")!
private let target = "https://two.example/b.json"
private func moved(_ key: String = "movie") -> Site {
    Site(key: key, name: key.capitalized, type: 1, api: "https://api.example/" + key,
         raw: ["key": .string(key)])
}

// MARK: - SourceRouting（relay 路由表）

@Suite @MainActor struct SourceRoutingCloudSyncTests {

    @Test func routingChoicesRoundTripThroughSavedValuesAndAdopt() {
        let a = SourceRouting(defaults: clean(#function + ".a"))
        let b = SourceRouting(defaults: clean(#function + ".b"))
        let show = Site(key: "show", name: "Show", type: 1, api: "https://api.example/show",
                        raw: ["key": .string("show")])
        a.set(.proxy, for: site, origin: origin)
        a.set(.direct, for: show, origin: origin)

        let snapshot = a.savedValues
        #expect(snapshot.count == 2)

        b.adopt(snapshot)
        #expect(b.savedValues == snapshot)                         // 往返后字典一致
        #expect(b.route(site, origin: origin) == .proxy)
        #expect(b.route(show, origin: origin) == .direct)
        #expect(b.effectiveRoute(site, origin: origin, subscription: nil) == .proxy)
    }

    @Test func adoptDropsRawValuesFromANewerBuildInsteadOfCrashing() {
        let store = SourceRouting(defaults: clean(#function))
        // 跨版本同步：新版本若引入未知 case，旧版本不得崩溃或把脏值写回。
        store.adopt(["known": "proxy", "future": "some-future-mode"])
        #expect(store.savedValues == ["known": "proxy"])
        #expect(store.route(site, origin: origin) == nil)          // 未知 key 对应的源不受影响
    }

    @Test func aLocalRoutingEditNotifiesSync() {
        let store = SourceRouting(defaults: clean(#function))
        var notes = 0
        store.onChange = { notes += 1 }
        store.set(.proxy, for: site, origin: origin)
        #expect(notes == 1)
        store.clear(site, origin: origin)
        #expect(notes == 2)
    }
}

// MARK: - SourceOverrides（改名 + API 覆盖）

@Suite @MainActor struct SourceOverridesCloudSyncTests {

    @Test func renameAndAPIOverrideRoundTripThroughSavedValuesAndAdopt() {
        let a = SourceOverrides(defaults: clean(#function + ".a"))
        a.rename(site, origin: origin, to: "Renamed")
        a.setAPI(site, origin: origin, to: "https://api.example/v2")

        let snapshot = a.savedValues
        #expect(snapshot.count == 1)

        let b = SourceOverrides(defaults: clean(#function + ".b"))
        b.adopt(snapshot)
        #expect(b.savedValues == snapshot)
        let applied = b.apply(to: site, origin: origin)
        #expect(applied.name == "Renamed")
        #expect(applied.api == "https://api.example/v2")
    }

    @Test func aLocalRenameNotifiesButAnAdoptDoesNot() {
        let store = SourceOverrides(defaults: clean(#function))
        var notes = 0
        store.onChange = { notes += 1 }
        store.rename(site, origin: origin, to: "Renamed")
        #expect(notes == 1)

        let before = notes
        store.adopt(store.savedValues)   // 相等 → guard 直接返回，无副作用
        store.adopt([:])                 // 不等 → 应用，但按契约不得再触发上云
        #expect(notes == before)
    }
}

// MARK: - LineSettings（线路隐藏 / 强制路由）

@Suite @MainActor struct LineSettingsCloudSyncTests {

    @Test func hiddenAndForcedRouteRoundTripThroughSavedValuesAndAdopt() {
        let a = LineSettings(defaults: clean(#function + ".a"))
        a.setRoute(.proxy("p1"), origin: origin, sourceKey: sourceKey, flag: flag)
        a.setHidden(true, origin: origin, sourceKey: sourceKey, flag: flag)

        let snapshot = a.savedValues
        #expect(snapshot.count == 1)

        let b = LineSettings(defaults: clean(#function + ".b"))
        b.adopt(snapshot)
        #expect(b.savedValues == snapshot)
        #expect(b.route(origin: origin, sourceKey: sourceKey, flag: flag)?.proxyID == "p1")
        #expect(b.isHidden(origin: origin, sourceKey: sourceKey, flag: flag))
    }

    @Test func aLocalLineEditNotifiesSync() {
        let store = LineSettings(defaults: clean(#function))
        var notes = 0
        store.onChange = { notes += 1 }
        store.setHidden(true, origin: origin, sourceKey: sourceKey, flag: flag)
        #expect(notes == 1)
        store.toggleHidden(origin: origin, sourceKey: sourceKey, flag: flag)
        #expect(notes == 2)
    }
}

// MARK: - SourceReassignment（跨订阅拖动，origin→source 映射）

@Suite @MainActor struct SourceReassignmentCloudSyncTests {

    @Test func aCrossSubscriptionMoveRoundTripsThroughSavedValuesAndAdopt() {
        let a = SourceReassignment(defaults: clean(#function + ".a"))
        a.reassign(moved(), address: address, origin: firstOrigin, sourceName: "Movies",
                   to: target, targetName: "Two")

        let snapshot = a.savedValues
        #expect(snapshot.count == 1)

        let b = SourceReassignment(defaults: clean(#function + ".b"))
        b.adopt(snapshot)
        #expect(b.savedValues == snapshot)
        #expect(b.moveCount == 1)
        #expect(b.destination(address: address, sourceKey: "movie", origin: firstOrigin) == target)
        #expect(b.moves[0].sourceName == "Movies")
        #expect(b.moves[0].targetName == "Two")
    }
}
