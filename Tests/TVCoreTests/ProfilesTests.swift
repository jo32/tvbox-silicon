import Foundation
import Testing
@testable import TVCore

/// A profile list in its own defaults suite and folder, removed again by `clean`.
@MainActor private struct Sandbox {
    let name = "profiles-test-" + UUID().uuidString
    let defaults: UserDefaults
    let root: URL
    var prefix: String { name + "." }
    init() {
        defaults = UserDefaults(suiteName: name)!
        root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
    }
    func profiles() -> Profiles { Profiles(defaults: defaults, root: root, suitePrefix: prefix) }
    func clean(_ profiles: Profiles) {
        for profile in profiles.all where !profile.isMain { profiles.defaults(for: profile).removePersistentDomain(forName: prefix + profile.id) }
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test @MainActor func profilesKeepTheirLibrariesApart() throws {
    let sandbox = Sandbox(), profiles = sandbox.profiles()
    defer { sandbox.clean(profiles) }
    #expect(profiles.all == [.main] && profiles.current.isMain)
    // The main profile is the library the app always had.
    #expect(profiles.defaults(for: .main) === sandbox.defaults && profiles.folder(for: .main) == nil)
    let kid = profiles.add(named: "  Kid ")
    #expect(kid.name == "Kid" && kid.title == "Kid" && !kid.isMain)
    let own = profiles.defaults(for: kid)
    #expect(own !== sandbox.defaults && profiles.defaults(for: kid) === own)
    own.set(Data("x".utf8), forKey: "videoSearchHistory")
    #expect(sandbox.defaults.data(forKey: "videoSearchHistory") == nil)
    #expect(profiles.folder(for: kid) == sandbox.root.appending(path: kid.id, directoryHint: .isDirectory))
    // The list and the open profile outlast the app.
    profiles.select(kid)
    profiles.rename(kid, to: "Guest")
    let again = sandbox.profiles()
    #expect(again.all.map(\.id) == [Profile.mainID, kid.id] && again.current.id == kid.id && again.current.title == "Guest")
    #expect(again.currentDefaults.data(forKey: "videoSearchHistory") == Data("x".utf8))
}

@Test @MainActor func onlyAProfileThatIsNeitherMainNorOpenIsDeleted() throws {
    let sandbox = Sandbox(), profiles = sandbox.profiles()
    defer { sandbox.clean(profiles) }
    let kid = profiles.add(named: "Kid"), guest = profiles.add(named: "")
    #expect(guest.title == L10n.text("Profile"))
    let entries = [SubscriptionEntry(address: "https://example.com/a.json")]
    profiles.defaults(for: kid).set(try JSONEncoder().encode(entries), forKey: "subscriptions")
    let folder = try #require(profiles.folder(for: kid))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: folder.appending(path: "playback-history-v1.json"))
    #expect(profiles.lists("https://example.com/a.json", besides: nil) && !profiles.lists("https://example.com/a.json", besides: kid))

    profiles.select(kid)
    profiles.remove(kid)
    profiles.remove(.main)
    #expect(profiles.all.count == 3)

    profiles.select(.main)
    profiles.remove(kid)
    #expect(profiles.all.map(\.id) == [Profile.mainID, guest.id])
    #expect(!FileManager.default.fileExists(atPath: folder.path) && !profiles.lists("https://example.com/a.json", besides: nil))
    #expect(UserDefaults(suiteName: sandbox.prefix + kid.id)?.data(forKey: "subscriptions") == nil)
}

@Test @MainActor func anUnknownOpenProfileFallsBackToTheMainOne() {
    let sandbox = Sandbox()
    sandbox.defaults.set("gone", forKey: Profiles.currentKey)
    let profiles = sandbox.profiles()
    defer { sandbox.clean(profiles) }
    #expect(profiles.current == .main)
}

@Test @MainActor func workingSubscriptionInAnotherProfileKeepsExtrasUnlocked() throws {
    let sandbox = Sandbox(), profiles = sandbox.profiles()
    defer { sandbox.clean(profiles) }
    let mainDir = sandbox.root.appending(path: "main-data", directoryHint: .isDirectory)
    let kid = profiles.add(named: "Kid")
    let address = "https://example.com/tvbox.json"
    let origin = try #require(URL(string: address))
    let entry = SubscriptionEntry(address: address)

    func write(_ subscription: Subscription, for profile: Profile, entry: SubscriptionEntry) throws {
        let dir = (profiles.folder(for: profile) ?? mainDir).appending(path: "subscriptions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(subscription).write(to: dir.appending(path: entry.cacheName))
    }

    // No subscriptions yet in any profile.
    #expect(!profiles.hasWorkingSubscription(besides: kid, mainDirectory: mainDir))
    #expect(!profiles.hasWorkingSubscription(besides: .main, mainDirectory: mainDir))

    // An enabled entry without a cached copy does not unlock.
    profiles.defaults(for: .main).set(try JSONEncoder().encode([entry]), forKey: "subscriptions")
    #expect(!profiles.hasWorkingSubscription(besides: kid, mainDirectory: mainDir))

    // A cached copy with neither sites nor live playlists does not unlock.
    try write(Subscription(origin: origin, importedAt: Date(), sites: [], lives: [], raw: [:]), for: .main, entry: entry)
    #expect(!profiles.hasWorkingSubscription(besides: kid, mainDirectory: mainDir))

    // A cached copy with sites in the main profile unlocks for another profile, not for main itself.
    let site = Site(key: "s1", name: "S1", type: 1, api: "https://example.com/api", raw: [:])
    try write(Subscription(origin: origin, importedAt: Date(), sites: [site], lives: [], raw: [:]), for: .main, entry: entry)
    #expect(profiles.hasWorkingSubscription(besides: kid, mainDirectory: mainDir))
    #expect(!profiles.hasWorkingSubscription(besides: .main, mainDirectory: mainDir))

    // Disabling the subscription stops unlocking for other profiles.
    let disabled = SubscriptionEntry(address: address, enabled: false)
    profiles.defaults(for: .main).set(try JSONEncoder().encode([disabled]), forKey: "subscriptions")
    #expect(!profiles.hasWorkingSubscription(besides: kid, mainDirectory: mainDir))

    // A working live-only subscription in another profile unlocks for the main profile, until that profile is deleted.
    let live = LiveSource(name: "Live", url: try #require(URL(string: "https://example.com/live.m3u")))
    profiles.defaults(for: kid).set(try JSONEncoder().encode([entry]), forKey: "subscriptions")
    try write(Subscription(origin: origin, importedAt: Date(), sites: [], lives: [live], raw: [:]), for: kid, entry: entry)
    #expect(profiles.hasWorkingSubscription(besides: .main, mainDirectory: mainDir))

    profiles.remove(kid)
    #expect(!profiles.hasWorkingSubscription(besides: .main, mainDirectory: mainDir))
}
