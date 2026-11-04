import Foundation
import Testing
@testable import TVCore

private func clean(_ name: String) -> UserDefaults {
    let suite = "TVCoreTests." + name
    let box = UserDefaults(suiteName: suite)!
    box.removePersistentDomain(forName: suite)
    return box
}

private func moved(_ key: String = "movie") -> Site {
    Site(key: key, name: key.capitalized, type: 1, api: "https://api.example/" + key,
         raw: ["key": .string(key), "name": .string(key.capitalized)])
}

/// The address a viewer typed, and the two mirrors it resolved to across two refreshes.
private let address = "https://short.example/moved"
private let firstOrigin = URL(string: "https://cdn.example/a.json")!
private let secondOrigin = URL(string: "https://cdn2.example/a.json")!
private let target = "https://two.example/b.json"

/// The bug behind "the move disappears after an update": a refresh lands on a new mirror, so the
/// origin changes while the address the viewer added stays the same. Keyed by origin, every move died
/// on the next refresh.
@Test @MainActor func aMoveSurvivesTheRefreshThatChangesTheMirror() {
    let box = clean(#function)
    let first = SourceReassignment(defaults: box)
    first.reassign(moved(), address: address, origin: firstOrigin, sourceName: "Movies", to: target, targetName: "Two")
    #expect(first.destination(address: address, sourceKey: "movie", origin: firstOrigin) == target)

    // Second launch, after a refresh that moved the subscription to another mirror.
    let second = SourceReassignment(defaults: box)
    #expect(second.destination(address: address, sourceKey: "movie", origin: secondOrigin) == target)
    #expect(second.moveCount == 1)
}

/// Dropping a source back onto its own subscription, or choosing "move back", deletes the record
/// rather than storing a move onto itself.
@Test @MainActor func returningASourceDeletesTheRecord() {
    let box = clean(#function)
    let store = SourceReassignment(defaults: box)
    store.reassign(moved(), address: address, origin: firstOrigin, to: target, targetName: "Two")
    #expect(store.moveCount == 1)

    store.reassign(moved(), address: address, origin: firstOrigin, to: address)
    #expect(store.moveCount == 0)
    #expect(store.destination(address: address, sourceKey: "movie", origin: firstOrigin) == nil)

    // And it stays gone after a relaunch, which is the point of persisting the removal.
    #expect(SourceReassignment(defaults: box).moveCount == 0)
}

/// A move repeated onto a new target replaces the old one, keeping the moment it was first made.
@Test @MainActor func movingAgainReplacesTheMoveInsteadOfAddingOne() {
    let box = clean(#function)
    let store = SourceReassignment(defaults: box)
    store.reassign(moved(), address: address, origin: firstOrigin, to: target, targetName: "Two")
    let first = store.moves[0]

    store.reassign(moved(), address: address, origin: firstOrigin, to: "https://three.example/c.json", targetName: "Three")
    #expect(store.moveCount == 1)
    #expect(store.moves[0].target == "https://three.example/c.json")
    #expect(store.moves[0].movedAt == first.movedAt)
    #expect(store.moves[0].sourceName == "Movie")
}

/// Builds kept the map keyed by the subscription's origin. Those moves still apply, and writing a new
/// move does not wipe the ones that have not been rewritten yet.
@Test @MainActor func movesSavedByAnOlderBuildStillApply() throws {
    let box = clean(#function)
    let legacyKey = String(data: try JSONEncoder().encode([firstOrigin.absoluteString, "movie", ""]), encoding: .utf8)!
    let otherKey = String(data: try JSONEncoder().encode([firstOrigin.absoluteString, "show", ""]), encoding: .utf8)!
    box.set([legacyKey: target, otherKey: target], forKey: "sourceReassignment.v1")

    let store = SourceReassignment(defaults: box)
    #expect(store.destination(address: address, sourceKey: "movie", origin: firstOrigin) == target)

    // Rewriting one of them must not drop the other from disk.
    store.reassign(moved(), address: address, origin: firstOrigin, to: target, targetName: "Two")
    let reopened = SourceReassignment(defaults: box)
    #expect(reopened.destination(address: address, sourceKey: "show", origin: firstOrigin) == target)
}

/// A move from an older build applies, but the maintenance list cannot see it until the app knows
/// which address its origin belongs to; `Store` rewrites it, which is what this reports.
@Test @MainActor func movesFromAnOlderBuildAreReportedForPromotion() {
    let box = clean(#function)
    box.set([EpisodeSkipSettings.scope(origin: firstOrigin, source: "movie", video: ""): target],
            forKey: "sourceReassignment.v1")
    let store = SourceReassignment(defaults: box)
    #expect(store.moveCount == 0)
    #expect(store.pendingLegacy == [SourceReassignment.LegacyMove(origin: firstOrigin.absoluteString,
                                                                 sourceKey: "movie", target: target)])
    store.reassign(moved(), address: address, origin: firstOrigin, to: target)
    #expect(store.pendingLegacy.isEmpty)
    #expect(store.moveCount == 1)
}

/// The maintenance list reads back what the viewer named things at the time, so a rename in the feed
/// does not turn a row into a raw key.
@Test @MainActor func theListRemembersTheNamesUsedAtTheTime() {
    let box = clean(#function)
    let store = SourceReassignment(defaults: box)
    store.reassign(moved(), address: address, origin: firstOrigin, sourceName: "Movies", to: target, targetName: "Two")
    let move = store.moves[0]
    #expect(move.title == "Movies")
    #expect(move.targetName == "Two")
    #expect(move.id == SourceMove.key(address: address, sourceKey: "movie"))
    #expect(store.savedValues[move.id] == move)

    // A move recorded without a name still has one to show: the feed's, then the key itself.
    store.reassign(moved("show"), address: address, origin: firstOrigin, sourceName: "", to: target)
    let named = store.moves.first { $0.sourceKey == "show" }
    #expect(named?.title == "Show")
    #expect(SourceMove(address: address, sourceKey: "bare", target: target, sourceName: "  ").title == "bare")
}

/// Undo, one at a time and all at once, from the maintenance list.
@Test @MainActor func undoingAMoveIsPersistedAndCanBeWholesale() {
    let box = clean(#function)
    let store = SourceReassignment(defaults: box)
    store.reassign(moved(), address: address, origin: firstOrigin, to: target)
    store.reassign(moved("show"), address: address, origin: firstOrigin, to: target)
    #expect(store.moveCount == 2)

    let one = store.moves[0].id
    store.remove(one)
    #expect(store.moveCount == 1)
    #expect(SourceReassignment(defaults: box).moveCount == 1)

    store.removeAll()
    #expect(store.moveCount == 0)
    #expect(SourceReassignment(defaults: box).moveCount == 0)
}

/// Every visibility change bumps the revision, so a cached source list cannot outlive it; the sync
/// hook fires for local edits but not for something another device already wrote.
@Test @MainActor func changesBumpTheRevisionAndOnlyLocalEditsNotify() {
    let box = clean(#function)
    let store = SourceReassignment(defaults: box)
    var notifications = 0
    store.onChange = { notifications += 1 }

    let start = store.revision
    store.reassign(moved(), address: address, origin: firstOrigin, to: target)
    #expect(store.revision == start + 1)
    #expect(notifications == 1)

    store.adopt(store.savedValues)
    #expect(store.revision == start + 1)
    #expect(notifications == 1)

    store.adopt([:])
    #expect(store.moveCount == 0)
}

private func entry(_ address: String, name: String) -> SubscriptionEntry {
    SubscriptionEntry(address: address, name: name, enabled: true)
}

private func document(_ origin: String, keys: [String]) throws -> Subscription {
    let sites = keys.map { #"{"key":"\#($0)","name":"\#($0)","type":1,"api":"https://api.example/\#($0)"}"# }.joined(separator: ",")
    return try Subscription.parse(Data(#"{"sites":[\#(sites)]}"#.utf8), origin: URL(string: origin)!)
}

/// A moved source is listed under the subscription it was filed into, and leaves its own group.
@Test func aMovedSourceIsListedUnderItsNewSubscription() throws {
    let one = try document("https://one.example/a.json", keys: ["show", "movie"])
    let two = try document("https://two.example/b.json", keys: ["other"])
    let oneAddress = "https://one.example/a.json"
    let twoAddress = "https://two.example/b.json"
    let merged = try #require(Subscription.merge([one, two]))
    let groups = SourceGroups.make(entries: [entry(oneAddress, name: "One"), entry(twoAddress, name: "Two")],
                                   documents: [oneAddress: one, twoAddress: two],
                                   builtIns: [], builtInOrigin: one.origin, mergedSites: merged.sites,
                                   pinOrder: [], userHidden: { _ in false }, includeHidden: false, jarURL: nil,
                                   reassign: { site, own in site.sourceKey == "movie" ? twoAddress : own })
    let first = try #require(groups.first { $0.id == oneAddress })
    let second = try #require(groups.first { $0.id == twoAddress })
    #expect(first.sites.map(\.key) == ["show"])
    #expect(second.sites.map(\.key).sorted() == ["movie", "other"])
}

/// A move whose target subscription is gone must not hide the source: it waits in "Other Sources"
/// until the viewer either restores the target or undoes the move.
@Test func aMoveToAMissingSubscriptionLeavesTheSourceVisible() throws {
    let one = try document("https://one.example/a.json", keys: ["movie"])
    let oneAddress = "https://one.example/a.json"
    let merged = try #require(Subscription.merge([one]))
    let groups = SourceGroups.make(entries: [entry(oneAddress, name: "One")],
                                   documents: [oneAddress: one],
                                   builtIns: [], builtInOrigin: one.origin, mergedSites: merged.sites,
                                   pinOrder: [], userHidden: { _ in false }, includeHidden: false, jarURL: nil,
                                   reassign: { _, _ in "https://gone.example/c.json" })
    #expect(groups.map(\.id) == ["other"])
    #expect(groups[0].sites.map(\.key) == ["movie"])
}
