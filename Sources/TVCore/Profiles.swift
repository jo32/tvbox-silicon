import Foundation
import Observation

/// One person's library on a shared device (#1456): their subscriptions, favorites, Continue Watching, followed shows,
/// search history and source choices. The main profile is the library the app always had; each other one keeps its
/// own in a defaults suite and a folder of its own, so switching shows nothing of another profile's.
public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public static let mainID = "main"
    public static let main = Profile(id: mainID, name: "")
    public let id: String
    /// Empty shows the default title.
    public var name: String

    public init(id: String = UUID().uuidString, name: String) {
        self.id = id; self.name = name
    }

    public var isMain: Bool { id == Self.mainID }
    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.text(isMain ? "Main Profile" : "Profile") : trimmed
    }
}

/// The profiles on this device and the one open. The list itself lives in the main defaults; it is not synced.
@MainActor @Observable public final class Profiles {
    public static let shared = Profiles()
    nonisolated static let listKey = "profiles.v1"
    nonisolated static let currentKey = "profiles.current"

    /// The main profile first, then the others in the order they were added.
    public private(set) var all: [Profile]
    public private(set) var currentID: String
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let suitePrefix: String
    @ObservationIgnored private var suites: [String: UserDefaults] = [:]

    public init(defaults: UserDefaults = .standard, root: URL? = nil, suitePrefix: String = "com.tvbox.yingxia.profile.") {
        self.defaults = defaults; self.suitePrefix = suitePrefix
        #if os(tvOS)
        self.root = root ?? URL.cachesDirectory.appending(path: "Profiles", directoryHint: .isDirectory)
        #else
        self.root = root ?? URL.applicationSupportDirectory.appending(path: "Profiles", directoryHint: .isDirectory)
        #endif
        let saved = defaults.data(forKey: Self.listKey).flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        var seen = Set<String>()
        let others = saved.filter { !$0.isMain && !$0.id.isEmpty && seen.insert($0.id).inserted }
        let list = [saved.first(where: \.isMain) ?? .main] + others
        let current = defaults.string(forKey: Self.currentKey)
        all = list
        currentID = list.contains { $0.id == current } ? current ?? Profile.mainID : Profile.mainID
    }

    public var current: Profile { all.first { $0.id == currentID } ?? all[0] }
    /// Where the open profile keeps what isn't the store's: the search histories.
    public var currentDefaults: UserDefaults { defaults(for: current) }

    /// The main defaults for the main profile, else the profile's own suite.
    public func defaults(for profile: Profile) -> UserDefaults {
        guard !profile.isMain else { return defaults }
        if let suite = suites[profile.id] { return suite }
        // A suite name is only refused when it is the app's own or the global domain, which these never are.
        let suite = UserDefaults(suiteName: suitePrefix + profile.id) ?? defaults
        suites[profile.id] = suite
        return suite
    }

    /// The folder for the profile's files (subscription copies, Continue Watching); nil for the main profile, whose
    /// files stay where they always were.
    public func folder(for profile: Profile) -> URL? {
        profile.isMain ? nil : root.appending(path: profile.id, directoryHint: .isDirectory)
    }

    @discardableResult public func add(named name: String) -> Profile {
        let profile = Profile(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        all.append(profile)
        save()
        return profile
    }

    public func rename(_ profile: Profile, to name: String) {
        guard let index = all.firstIndex(where: { $0.id == profile.id }) else { return }
        all[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Remembers the profile to open; the store opens its library.
    public func select(_ profile: Profile) {
        guard all.contains(where: { $0.id == profile.id }) else { return }
        currentID = profile.id
        defaults.set(profile.id, forKey: Self.currentKey)
    }

    /// Deletes a profile other than the main one and the one open, with everything it kept. Files it added that no
    /// other profile lists go too.
    public func remove(_ profile: Profile) {
        guard !profile.isMain, profile.id != currentID, all.contains(where: { $0.id == profile.id }) else { return }
        let addresses = subscriptionAddresses(of: profile)
        all.removeAll { $0.id == profile.id }
        save()
        for address in addresses where ImportedFiles.isImported(address) && !lists(address, besides: nil) {
            ImportedFiles.remove(address)
        }
        defaults(for: profile).removePersistentDomain(forName: suitePrefix + profile.id)
        suites[profile.id] = nil
        if let folder = folder(for: profile) { try? FileManager.default.removeItem(at: folder) }
    }

    /// Whether a profile other than `profile` lists this subscription address: an imported file's copy is shared by
    /// name, so one profile removing it must not take it from another.
    public func lists(_ address: String, besides profile: Profile?) -> Bool {
        all.contains { $0.id != profile?.id && subscriptionAddresses(of: $0).contains(address) }
    }

    /// Whether another profile has an enabled subscription whose saved copy has sources or live playlists:
    /// shared sections and settings (such as Music) stay available after switching to a profile that has not
    /// added its own subscriptions yet (#1853).
    public func hasWorkingSubscription(besides profile: Profile?, mainDirectory: URL) -> Bool {
        all.contains { other in
            other.id != profile?.id && hasWorkingSubscription(in: other, mainDirectory: mainDirectory)
        }
    }

    private func hasWorkingSubscription(in profile: Profile, mainDirectory: URL) -> Bool {
        let entries = subscriptionEntries(of: profile).filter(\.enabled)
        guard !entries.isEmpty else { return false }
        let folder = (folder(for: profile) ?? mainDirectory).appending(path: "subscriptions")
        return entries.contains { entry in
            guard let data = try? Data(contentsOf: folder.appending(path: entry.cacheName)),
                  let content = try? JSONDecoder().decode(SubscriptionContent.self, from: data) else { return false }
            return !content.sites.isEmpty || !content.lives.isEmpty
        }
    }

    /// Only the counts of `sites` and `lives` from a cached `Subscription`, avoiding decoding every source entry.
    private struct SubscriptionContent: Decodable {
        struct Item: Decodable {}
        let sites: [Item]
        let lives: [Item]
    }

    /// The profile's subscriptions, as the store saved them.
    func subscriptionEntries(of profile: Profile) -> [SubscriptionEntry] {
        let data = defaults(for: profile).data(forKey: "subscriptions")
        return data.flatMap { try? JSONDecoder().decode([SubscriptionEntry].self, from: $0) } ?? []
    }

    /// The addresses of the profile's subscriptions, as the store saved them.
    func subscriptionAddresses(of profile: Profile) -> [String] {
        subscriptionEntries(of: profile).map(\.address)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(all), forKey: Self.listKey)
    }
}
