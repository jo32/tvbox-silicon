import SwiftUI
import TVCore

@MainActor @Observable final class Store {
    static let defaultURL = "https://raw.githubusercontent.com/qist/tvbox/master/fty.json"
    let searchModel = SearchModel()
    let recommendationModel = RecommendationModel()
    var subscription: Subscription?
    var subscriptionAddress: String
    var favorites: [Channel] = []
    var importing = false
    var error: String?
    var notice: String?
    var playing: Channel?
    var section: AppSection = .home
    private let defaults: UserDefaults
    private let http = HTTPClient()
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        subscriptionAddress = defaults.string(forKey: "subscriptionAddress") ?? Self.defaultURL
        let cached = (try? Data(contentsOf: Self.subscriptionFile)) ?? defaults.data(forKey: "subscription")
        if let cached { subscription = try? JSONDecoder().decode(Subscription.self, from: cached) }
        if let subscription { Self.registerPlugins(subscription) }
        // Older builds kept the whole subscription in defaults; move it to the file and drop the key.
        if let legacy = defaults.data(forKey: "subscription") {
            try? Self.saveSubscription(legacy)
            defaults.removeObject(forKey: "subscription")
        }
        if let data = defaults.data(forKey: "favorites") { favorites = (try? JSONDecoder().decode([Channel].self, from: data)) ?? [] }
    }
    /// Large subscriptions run to megabytes, past the defaults size limit that aborts tvOS apps,
    /// so the parsed subscription lives in a file. tvOS only offers Caches, which the system may purge;
    /// `restoreSubscription()` refetches it from the saved address when that happens.
    private static var subscriptionFile: URL {
        #if os(tvOS)
        let directory = URL.cachesDirectory
        #else
        let directory = URL.applicationSupportDirectory
        #endif
        return directory.appending(path: "subscription.json")
    }
    private static func saveSubscription(_ data: Data) throws {
        try FileManager.default.createDirectory(at: subscriptionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: subscriptionFile, options: .atomic)
    }
    /// Lets sources on a shared spider borrow classes from the subscription's other plugin archives.
    private static func registerPlugins(_ subscription: Subscription) {
        let archives = subscription.pluginArchives
        Task { await PluginLocator.shared.use(archives) }
    }
    /// Refetches a previously imported subscription whose cached copy is gone.
    func restoreSubscription() async {
        guard subscription == nil, defaults.string(forKey: "subscriptionAddress") != nil else { return }
        await importSubscription()
    }
    func importSubscription(address: String? = nil) async {
        guard !importing else { return }
        importing = true; error = nil; notice = nil
        defer { importing = false }
        do {
            let url = try WebAddress.resolve(address ?? subscriptionAddress)
            let value = try await http.subscription(url)
            try Self.saveSubscription(JSONEncoder().encode(value))
            defaults.set(url.absoluteString, forKey: "subscriptionAddress")
            searchModel.reset()
            recommendationModel.reset()
            subscription = value
            Self.registerPlugins(value)
            notice = L10n.text("Imported sources: %lld · Live playlists: %lld", value.sites.count, value.lives.count)
        } catch { self.error = L10n.text("Import failed: %@", error.localizedDescription) }
    }
    func searchVideos(_ title: String) {
        guard let config = subscription else { return }
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        let old = defaults.data(forKey: "videoSearchHistory").flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        defaults.set(try? JSONEncoder().encode(Array(([keyword] + old.filter { $0 != keyword }).prefix(20))), forKey: "videoSearchHistory")
        searchModel.search(keyword, config: config)
        section = .search
    }
    func toggleFavorite(_ channel: Channel) {
        if let index = favorites.firstIndex(where: { $0.id == channel.id }) { favorites.remove(at: index) }
        else { favorites.append(channel) }
        defaults.set(try? JSONEncoder().encode(favorites), forKey: "favorites")
    }
    func isFavorite(_ channel: Channel) -> Bool { favorites.contains { $0.id == channel.id } }
}
