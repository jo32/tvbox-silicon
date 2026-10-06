#if DEBUG
import SwiftUI
import TVCore

/// Debug-only launch hooks for screenshot QA on simulators without input:
/// `simctl launch <device> <bundle> -qaSection live -qaPage channels:0`.
/// Launch arguments land in UserDefaults' argument domain, so nothing persists.
enum QALaunch {
    static var section: AppSection? { UserDefaults.standard.string(forKey: "qaSection").flatMap(AppSection.init(rawValue:)) ?? sectionByKey }
    private static var sectionByKey: AppSection? {
        switch UserDefaults.standard.string(forKey: "qaSection") {
        case "home": .home
        case "live": .live
        case "search": .search
        case "sites": .sites
        case "favorites": .favorites
        case "settings": .settings
        case "more": .more
        default: nil
        }
    }
    static var page: String? { UserDefaults.standard.string(forKey: "qaPage") }

    @MainActor static func start(_ store: Store) async {
        guard section != nil || page != nil else { return }
        if let subscription = UserDefaults.standard.string(forKey: "qaSubscription") { await store.importSubscription(address: subscription) }
        else if store.subscription == nil { await store.importSubscription() }
        if let section { store.section = section }
        if let page, page.hasPrefix("search:") { store.searchVideos(String(page.dropFirst(7))) }
        if page == "player", let url = URL(string: "http://127.0.0.1:8765/clip.mp4") {
            store.playing = Channel(name: "测试频道 01", url: url)
        }
        if page == "player-error", let url = URL(string: "http://127.0.0.1:8765/missing.mp4") {
            store.playing = Channel(name: "无法播放的频道", url: url)
        }
    }

    /// The pushed page to show as the section's root, so detail screens can be captured without taps.
    @MainActor @ViewBuilder static func page(for section: AppSection, store: Store) -> some View {
        if section == self.section, let page, let config = store.subscription {
            let parts = page.split(separator: ":", maxSplits: 2).map(String.init)
            switch parts.first {
            case "site":
                if let site = config.sites.first(where: { $0.key == parts.dropFirst().first }) {
                    SiteView(site: site, origin: config.origin, jarURL: config.spiderURL, initialQuery: UserDefaults.standard.string(forKey: "qaQuery") ?? "")
                }
            case "detail":
                if parts.count == 3, let site = config.sites.first(where: { $0.key == parts[1] }),
                   let video = Video(json: ["vod_id": .string(parts[2]), "vod_name": .string("测试影片 \(parts[2])"),
                                            "vod_pic": .string("http://127.0.0.1:8765/poster.png"), "vod_remarks": .string("更新至 36 集")],
                                     origin: config.origin) {
                    VideoDetailView(video: video, client: CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL))
                }
            case "channels":
                if let index = Int(parts.dropFirst().first ?? ""), config.lives.indices.contains(index) {
                    ChannelListView(source: config.lives[index])
                }
            case "runtime": RuntimeView()
            case "logs": DiagnosticsView()
            case "licenses": LicensesView()
            #if !os(macOS)
            case "cloud-login": CloudQRLoginView(drive: parts.dropFirst().first == "uc" ? .uc : .quark) {}
            #endif
            default: EmptyView()
            }
        }
    }

    static func overrides(_ section: AppSection) -> Bool {
        guard section == self.section, let page else { return false }
        return ["site", "detail", "channels", "runtime", "logs", "licenses", "cloud-login"].contains(page.split(separator: ":").first.map(String.init) ?? "")
    }
}
#endif
