import Foundation
import Testing
@testable import TVCore

private func source(_ key: String, hide: Bool = false) -> Site {
    var raw: [String: JSONValue] = ["key": .string(key), "searchable": .number(1)]
    if hide { raw["hide"] = .number(1) }
    return Site(key: key, name: key, type: 1, api: "https://api.example/" + key, raw: raw)
}

@Test func browsableSourcesSkipJsonHidesAndUserHides() {
    let sites = [source("a"), source("b", hide: true), source("c")]
    let listed = SourceLists.browsable(sites, jarURL: nil) { $0.key == "c" }
    #expect(listed.map(\.key) == ["a"])
}

@Test @MainActor func searchEligibilitySkipsUserHidesAndCacheDropsThem() {
    let sites = [source("a"), source("b"), source("c", hide: true)]
    let eligible = SearchModel.eligible(sites, jarURL: nil) { $0.key == "b" }
    #expect(eligible.map(\.key) == ["a", "c"])
    let results = sites.map { SearchSourceResult(site: $0, page: nil, error: nil) }
    #expect(SearchModel.visible(results) { $0.key == "b" }.map(\.site.key) == ["a", "c"])
}

private func entry(_ address: String, name: String, enabled: Bool) -> SubscriptionEntry {
    SubscriptionEntry(address: address, name: name, enabled: enabled)
}

private func document(_ origin: String, keys: [String]) throws -> Subscription {
    let sites = keys.map { #"{"key":"\#($0)","name":"\#($0)","type":1,"api":"https://api.example/\#($0)"}"# }.joined(separator: ",")
    return try Subscription.parse(Data(#"{"sites":[\#(sites)]}"#.utf8), origin: URL(string: origin)!)
}

@Test func groupsPutPinsAndBuiltInsAboveSubscriptions() throws {
    let first = try document("https://one.example/a.json", keys: ["show", "secret"])
    let second = try document("https://two.example/b.json", keys: ["other"])
    let entries = [
        entry("https://one.example/a.json", name: "One", enabled: true),
        entry("https://off.example/c.json", name: "Off", enabled: false),
        entry("https://two.example/b.json", name: "Two", enabled: true),
    ]
    let merged = try #require(Subscription.merge([first, second]))
    let secret = try #require(merged.sites.first { $0.key == "secret" })
    let documents = [
        "https://one.example/a.json": first,
        "https://two.example/b.json": second,
    ]
    let hidden = SourceGroups.make(entries: entries, documents: documents, builtIns: [], builtInOrigin: first.origin, mergedSites: merged.sites, pinOrder: [secret], userHidden: { $0.key == "other" }, includeHidden: false, jarURL: nil)
    // The hidden source leaves its subscription's group for the Hidden group at the end.
    #expect(hidden.map(\.id) == ["pinned", "https://one.example/a.json", "hidden"])
    #expect(hidden[0].sites.map(\.key) == ["secret"])
    #expect(hidden[1].sites.map(\.key) == ["show"])
    #expect(hidden[2].sites.map(\.key) == ["other"])
    let shown = SourceGroups.make(entries: entries, documents: documents, builtIns: [], builtInOrigin: first.origin, mergedSites: merged.sites, pinOrder: [secret], userHidden: { $0.key == "other" }, includeHidden: true, jarURL: nil)
    #expect(shown.map(\.id) == ["pinned", "https://one.example/a.json", "https://two.example/b.json"])
}

private func document(_ origin: String, sites: [(key: String, api: String)]) throws -> Subscription {
    let items = sites.map { #"{"key":"\#($0.key)","name":"\#($0.key)","type":1,"api":"\#($0.api)"}"# }.joined(separator: ",")
    return try Subscription.parse(Data(#"{"sites":[\#(items)]}"#.utf8), origin: URL(string: origin)!)
}

@Test func laterSubscriptionGroupHoldsItsMergedSites() throws {
    let first = try document("https://one.example/a.json", sites: [
        (key: "same", api: "https://api.example/same"),
        (key: "clash", api: "https://api.example/one"),
    ])
    let second = try document("https://two.example/b.json", sites: [
        (key: "copy", api: "https://api.example/same"),
        (key: "clash", api: "https://api.example/two"),
    ])
    let merged = try #require(Subscription.merge([first, second]))
    let entries = [
        entry("https://one.example/a.json", name: "One", enabled: true),
        entry("https://two.example/b.json", name: "Two", enabled: true),
    ]
    let documents = [
        "https://one.example/a.json": first,
        "https://two.example/b.json": second,
    ]
    let groups = SourceGroups.make(entries: entries, documents: documents, builtIns: [], builtInOrigin: first.origin, mergedSites: merged.sites, pinOrder: [], userHidden: { _ in false }, includeHidden: false, jarURL: nil)
    #expect(groups.map(\.id) == ["https://one.example/a.json", "https://two.example/b.json"])
    #expect(groups[0].sites.map(\.key).sorted() == ["clash", "same"])
    let later = groups[1]
    #expect(later.sites.count == 1)
    let renamed = try #require(later.sites.first)
    #expect(renamed.key == "clash@" + second.tag)
    #expect(renamed.sourceKey == "clash")
    #expect(!later.sites.contains { $0.key == "copy" })
    #expect(renamed.origin(or: first.origin) == second.origin)
}

@Test func homeRowKeepsPinsAndBuiltInsThenFollowsTheDirectory() {
    let pin = source("pin")
    let firstBuiltIn = source("built-a")
    let secondBuiltIn = source("built-b")
    let later = source("later")
    let earlier = source("earlier")
    let groups = [
        SourceGroup(kind: .pinned, title: "Pinned Group", sites: [pin]),
        SourceGroup(kind: .builtIn, title: "Recommended", sites: [secondBuiltIn, firstBuiltIn]),
        SourceGroup(kind: .subscription("two"), title: "Two", sites: [later, pin]),
        SourceGroup(kind: .subscription("one"), title: "One", sites: [earlier]),
        SourceGroup(kind: .hidden, title: "Hidden Sources", sites: [source("hidden-src")]),
    ]
    let row = SourceGroups.homeRow(pinned: [pin], builtIn: [firstBuiltIn, secondBuiltIn], groups: groups)
    #expect(row.map(\.key) == ["pin", "built-a", "built-b", "later", "earlier"])
}

@Test func droppingAGroupMovesItTowardTheTarget() {
    let displayed = ["jia", "yi", "bing"]
    #expect(SubscriptionOrder.moving("jia", onto: "bing", in: displayed) == ["yi", "bing", "jia"])
    #expect(SubscriptionOrder.moving("jia", onto: "yi", in: displayed) == ["yi", "jia", "bing"])
    #expect(SubscriptionOrder.moving("bing", onto: "jia", in: displayed) == ["bing", "jia", "yi"])
    #expect(SubscriptionOrder.moving("jia", onto: "jia", in: displayed) == displayed)
    #expect(SubscriptionOrder.moving("jia", onto: "missing", in: displayed) == displayed)
}

@Test func draggingAVisibleSubscriptionLeavesTheHiddenSlot() {
    let entries = [
        entry("jia", name: "Jia", enabled: true),
        entry("yi", name: "Yi", enabled: false),
        entry("bing", name: "Bing", enabled: true),
    ]
    let moved = SubscriptionOrder.applying(displayed: ["bing", "jia"], to: entries)
    #expect(moved.map(\.address) == ["bing", "yi", "jia"])
    #expect(moved.map(\.name) == ["Bing", "Yi", "Jia"])
}
