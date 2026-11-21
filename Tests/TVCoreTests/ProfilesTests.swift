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
