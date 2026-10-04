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
        if let data = defaults.data(forKey: "subscription") { subscription = try? JSONDecoder().decode(Subscription.self, from: data) }
        if let data = defaults.data(forKey: "favorites") { favorites = (try? JSONDecoder().decode([Channel].self, from: data)) ?? [] }
    }
    func importSubscription(address: String? = nil) async {
        guard !importing else { return }
        importing = true; error = nil; notice = nil
        defer { importing = false }
        do {
            let url = try WebAddress.resolve(address ?? subscriptionAddress)
            let value = try await http.subscription(url)
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: "subscription")
            defaults.set(url.absoluteString, forKey: "subscriptionAddress")
            searchModel.reset()
            recommendationModel.reset()
            subscription = value
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
