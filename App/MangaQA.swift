#if DEBUG
import SwiftUI
import TVCore

/// Launch flags for screenshots and simulator checks of the Manga section (`-qaSection manga` plus):
/// - `-qaMangaRepo 1` adds Venera's source list; `-qaMangaInstall <url,url>` installs those sources first.
/// - `-qaMangaSource <key>` picks the source the page browses; `-qaMangaMode vertical|leftToRight|rightToLeft` the reader.
/// - `-qaMangaPage sources|repo|search|results` opens that page (`-qaMangaQuery <text>` searches; results: one source's).
/// - `-qaMangaOpen <source>@<comic id>` opens a comic; with `-qaMangaRead 1 [-qaMangaChapter <n>]` it reads; `-qaMangaChrome 1` keeps the reader bars up.
/// - `-qaMangaScrollTop 1` scrolls the vertical reader up to its Previous Chapter button after it opens.
/// - `-qaMangaHTTPLog 1` (or MANGA_HTTP_LOG=1 for TVBoxProbe) logs each source request's status as `[mangahttp]`.
@MainActor enum MangaQA {
    private static var started = false

    static func start(openRoute: RouteOpener?) async {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        let store = MangaStore.shared
        if defaults.bool(forKey: "qaMangaRepo") { store.addRepository(MangaSources.veneraRepository) }
        if let list = defaults.string(forKey: "qaMangaInstall") {
            for address in list.split(separator: ",").compactMap({ URL(string: String($0).trimmingCharacters(in: .whitespaces)) }) {
                let name = address.deletingPathExtension().lastPathComponent
                guard !store.sources.contains(where: { $0.origin == address || $0.key == name }) else { continue }
                do { try await store.install(address) } catch { print("QA manga install \(address): \(error)") }
            }
        }
        if let key = defaults.string(forKey: "qaMangaSource") { store.selectedSource = key }
        if let mode = defaults.string(forKey: "qaMangaMode").flatMap(MangaReaderMode.init(rawValue:)) { store.readerMode = mode }
        guard let openRoute else { return }
        switch defaults.string(forKey: "qaMangaPage") {
        case "sources": openRoute(Route { AnyView(MangaSourcesView()) })
        case "repo": openRoute(Route { AnyView(MangaRepositoryView(url: MangaSources.veneraRepository)) })
        case "search": openRoute(Route { AnyView(MangaSearchView()) })
        case "results":
            let source = defaults.string(forKey: "qaMangaSource") ?? store.currentSource?.key ?? "", keyword = defaults.string(forKey: "qaMangaQuery") ?? ""
            openRoute(Route { AnyView(MangaSourceResults(source: source, keyword: keyword)) })
        default: break
        }
        if let target = defaults.string(forKey: "qaMangaOpen"), let at = target.firstIndex(of: "@") {
            let comic = MangaComic(id: String(target[target.index(after: at)...]), sourceKey: String(target[..<at]), title: "")
            openRoute(Route { AnyView(MangaDetailView(comic: comic)) })
        }
    }
}
#endif
