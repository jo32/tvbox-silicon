import Foundation
import Testing
@testable import TVCore

private let one = URL(string: "https://one.example/a.json")!
private let two = URL(string: "https://two.example/b.json")!

private func source(_ key: String, origin: URL? = nil) -> Site {
    var site = Site(key: key, name: key, type: 1, api: "https://api.example/" + key, raw: ["key": .string(key)])
    if let origin { site.provenance = SourceProvenance(origin: origin, spider: nil) }
    return site
}

/// A vault with a passcode already set, for the tests that are about hiding rather than about the
/// passcode. Six digits is `PrivacyVault.minimumLength`: four was brute-forceable from a copied
/// preferences file, and the tests used to encode the old rule.
private func unlockedVault(_ passcode: String = "123456", now: Date = Date()) throws -> PrivacyVault {
    var vault = PrivacyVault(rounds: 10)
    try vault.setPasscode(passcode, now: now)
    return vault
}

/// The bug behind "turning off A also turned off B": a hide used to be recorded by source key
/// alone, and public subscriptions reuse keys constantly.
@Test func hidingASourceLeavesItsNamesakeInAnotherSubscription() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["csp_AppYsV2"], origin: one, now: now)
    // Hiding shows its effect once the vault closes: while it is open its owner sees everything.
    vault.lock()

    #expect(!vault.permits(sourceKey: "csp_AppYsV2", origin: one, now: now))
    #expect(vault.permits(sourceKey: "csp_AppYsV2", origin: two, now: now))
    #expect(vault.permits(sourceKey: "somethingElse", origin: one, now: now))
}

@Test func lockingHidesAndUnlockingBringsBack() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    #expect(vault.permits(sourceKey: "a", origin: one, now: now))

    vault.lock()
    #expect(!vault.permits(sourceKey: "a", origin: one, now: now))

    let opened = vault.unlock("123456", now: now)
    #expect(opened)
    #expect(vault.permits(sourceKey: "a", origin: one, now: now))
}

/// A hidden subscription must not take the built-in sources with it. Built-in sources carry no
/// origin, and the filter used to fall back to the merged subscription's — which is the first
/// subscription's — so hiding that one emptied the built-in group.
@Test func aHiddenSubscriptionDoesNotHideBuiltInSources() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    let builtIn = source("bilibili")
    try vault.hide(subscription: one, sourceKeys: ["a"], now: now)
    vault.lock()

    #expect(!vault.permits(site: source("a", origin: one), fallback: one, now: now))
    #expect(vault.permits(site: builtIn, fallback: one, now: now))
}

@Test func aHiddenSubscriptionHidesItsOwnSources() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(subscription: one, sourceKeys: [], now: now)
    vault.lock()
    #expect(vault.isHidden(subscription: one))
    #expect(!vault.permits(subscription: one, now: now))
    #expect(vault.permits(subscription: two, now: now))
    // Every source of that feed goes with it, through the site-level question the lists ask.
    #expect(!vault.permits(site: source("a", origin: one), fallback: one, now: now))
    #expect(vault.permits(site: source("a", origin: two), fallback: two, now: now))
}

/// Reading a switch asks "is this hidden", not "may this be seen": a locked vault would otherwise
/// draw every switch as off and look as though everything were hidden.
@Test func aSwitchReadsItsOwnPositionWhateverTheLock() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    vault.lock()

    #expect(vault.isHidden(sourceKey: "a", origin: one))
    #expect(!vault.isHidden(sourceKey: "b", origin: one))
    #expect(!vault.isHidden(sourceKey: "a", origin: two))
}

/// Builds before the identity carried an origin saved bare keys. Those still hide after the update,
/// otherwise an existing vault would silently empty itself.
@Test func bareKeysFromAnOlderVaultStillHide() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["keep"], origin: two, now: now)

    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(vault)) as? [String: Any])
    json["hiddenSources"] = (json["hiddenSources"] as? [String] ?? []) + ["legacyKey"]
    let migrated = try JSONDecoder().decode(PrivacyVault.self, from: try JSONSerialization.data(withJSONObject: json))

    var reopened = migrated
    // A decoded vault always starts locked.
    #expect(!reopened.permits(sourceKey: "legacyKey", origin: one, now: now))
    #expect(!reopened.permits(sourceKey: "keep", origin: two, now: now))
    #expect(reopened.permits(sourceKey: "keep", origin: one, now: now))

    let opened = reopened.unlock("123456", now: now)
    #expect(opened)
    #expect(reopened.permits(sourceKey: "legacyKey", origin: one, now: now))
}

/// Cached source rows compare `revision`; without a bump, hiding something would change nothing on
/// screen until the app restarted.
@Test func everyVisibilityChangeBumpsTheRevision() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    let start = vault.revision
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    #expect(vault.revision > start)
    let hidden = vault.revision
    vault.lock()
    #expect(vault.revision > hidden)
    let locked = vault.revision
    let opened = vault.unlock("123456", now: now)
    #expect(opened)
    #expect(vault.revision > locked)
}

/// Without a passcode nothing is hidden, even if a previous vault left a list behind.
@Test func withoutAPasscodeNothingIsHidden() throws {
    var vault = try unlockedVault()
    try vault.hide(sourceKeys: ["a"], origin: one)
    try vault.removePasscode()
    #expect(vault.permits(sourceKey: "a", origin: one))
    #expect(vault.permits(sourceKey: "a", origin: one))
}

/// The Sources page filters through this: a hidden source's history row and favourite go with it.
@Test func historyAndFavouritesFollowTheSourceIdentity() throws {
    let now = Date()
    var vault = try unlockedVault(now: now)
    try vault.hide(sourceKeys: ["a"], origin: one, now: now)
    vault.lock()

    let context = PlaybackHistoryContext(origin: one, sourceKey: "a", sourceName: "A", videoID: "1", videoName: "V",
                                         episodeID: "e", episodeName: "E", episodeFlag: "line")
    #expect(!vault.permits(PlaybackHistoryEntry(context: context, position: 1, duration: 2, updatedAt: now), now: now))
    #expect(vault.visibleHistory([PlaybackHistoryEntry(context: context, position: 1, duration: 2, updatedAt: now)], now: now).isEmpty)
}


@Test func aPasscodeShorterThanTheMinimumIsRefused() {
    var vault = PrivacyVault(rounds: 10)
    #expect(throws: PrivacyVault.PasscodeError.tooShort) {
        try vault.setPasscode("1234")
    }
    #expect(!vault.hasPasscode)
    #expect(throws: Never.self) {
        try vault.setPasscode(String(repeating: "1", count: PrivacyVault.minimumLength))
    }
    #expect(vault.hasPasscode)
}
