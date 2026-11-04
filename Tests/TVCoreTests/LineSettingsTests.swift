import Foundation
import Testing
@testable import TVCore

/// 线路级设置（LineSettings）：单条线路的强制路由与隐藏，以及批量隐藏/恢复。
/// key 是 `EpisodeSkipSettings.scope` 产生的 JSON 数组，P2-8 之前用 `|` 分隔解析恒空，这里锁定正确解析。
@Suite @MainActor struct LineSettingsTests {

    private func clean(_ name: String) -> UserDefaults {
        let suite = "TVCoreTests.LineSettings." + name
        let box = UserDefaults(suiteName: suite)!
        box.removePersistentDomain(forName: suite)
        return box
    }

    private let origin = URL(string: "https://sub.example/list.json")!
    private let sourceKey = "source-a"
    private let flag = "线路1"

    // MARK: - 路由

    @Test func aForcedRouteIsReadBackAndClearingItRemovesTheRecord() {
        let box = clean(#function)
        let settings = LineSettings(defaults: box)
        settings.setRoute(.proxy("p1"), origin: origin, sourceKey: sourceKey, flag: flag)
        #expect(settings.route(origin: origin, sourceKey: sourceKey, flag: flag)?.proxyID == "p1")
        // 清除（nil）后 record 应被移除，而不是留一个 route=nil 的空壳。
        settings.setRoute(nil, origin: origin, sourceKey: sourceKey, flag: flag)
        #expect(settings.route(origin: origin, sourceKey: sourceKey, flag: flag) == nil)
        #expect(settings.savedValues.isEmpty)
    }

    @Test func routesAreScopedByOriginSourceAndFlag() {
        let box = clean(#function)
        let settings = LineSettings(defaults: box)
        settings.setRoute(.proxy("p1"), origin: origin, sourceKey: sourceKey, flag: flag)
        #expect(settings.route(origin: URL(string: "https://other.example/x.json")!, sourceKey: sourceKey, flag: flag) == nil)
        #expect(settings.route(origin: origin, sourceKey: "other-source", flag: flag) == nil)
        #expect(settings.route(origin: origin, sourceKey: sourceKey, flag: "线路2") == nil)
    }

    // MARK: - 隐藏

    @Test func toggleHiddenFlipsAndRestoreAllBringsEveryLineBack() {
        let box = clean(#function)
        let settings = LineSettings(defaults: box)
        #expect(settings.toggleHidden(origin: origin, sourceKey: sourceKey, flag: "l1"))
        #expect(settings.toggleHidden(origin: origin, sourceKey: sourceKey, flag: "l2"))
        #expect(settings.isHidden(origin: origin, sourceKey: sourceKey, flag: "l1"))
        #expect(settings.hiddenFlags(origin: origin, sourceKey: sourceKey) == ["l1", "l2"])

        settings.restoreAll(origin: origin, sourceKey: sourceKey)
        #expect(settings.hiddenFlags(origin: origin, sourceKey: sourceKey).isEmpty)
        #expect(!settings.isHidden(origin: origin, sourceKey: sourceKey, flag: "l1"))
    }

    @Test func hiddenFlagsDoesNotLeakAcrossSources() {
        let box = clean(#function)
        let settings = LineSettings(defaults: box)
        settings.toggleHidden(origin: origin, sourceKey: "source-a", flag: "l1")
        #expect(settings.hiddenFlags(origin: origin, sourceKey: "source-b").isEmpty)
    }

    @Test func settingsSurviveRelaunch() {
        let box = clean(#function)
        let first = LineSettings(defaults: box)
        first.setRoute(.proxy("p1"), origin: origin, sourceKey: sourceKey, flag: flag)
        first.toggleHidden(origin: origin, sourceKey: sourceKey, flag: flag)

        let second = LineSettings(defaults: box)
        #expect(second.route(origin: origin, sourceKey: sourceKey, flag: flag)?.proxyID == "p1")
        #expect(second.isHidden(origin: origin, sourceKey: sourceKey, flag: flag))
    }
}
