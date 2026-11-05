import SwiftUI
import TVCore

/// The Manga section's state: installed Venera sources, the shelf (favorites, reading history) and reader settings.
@MainActor @Observable final class MangaStore {
    static let shared = MangaStore()

    private(set) var sources: [MangaInstalledSource] = MangaSources.shared.installed
    private(set) var repositories: [URL] = MangaSources.shared.repositories
    private(set) var favorites: [MangaLibrary.Favorite] = MangaLibrary.load("favorites.json", as: [MangaLibrary.Favorite].self) ?? []
    private(set) var history: [MangaLibrary.Progress] = MangaLibrary.load("history.json", as: [MangaLibrary.Progress].self) ?? []
    /// Shown on the page that started it: a message from a source (UI.showMessage).
    var notice: String?
    /// Until when a site makes requests wait (拷贝漫画's "too many requests").
    var throttledUntil: Date?
    /// The source the Browse page shows.
    var selectedSource: String? {
        didSet { UserDefaults.standard.set(selectedSource, forKey: "manga.source") }
    }
    var readerMode: MangaReaderMode {
        didSet { UserDefaults.standard.set(readerMode.rawValue, forKey: "manga.readerMode") }
    }
    /// Comics whose reading direction differs from the default, by comic.
    private var modes: [String: String] = UserDefaults.standard.dictionary(forKey: "manga.readerModes") as? [String: String] ?? [:]

    private init() {
        selectedSource = UserDefaults.standard.string(forKey: "manga.source")
        #if os(tvOS)
        readerMode = MangaReaderMode(rawValue: UserDefaults.standard.string(forKey: "manga.readerMode") ?? "") ?? .rightToLeft
        #else
        readerMode = MangaReaderMode(rawValue: UserDefaults.standard.string(forKey: "manga.readerMode") ?? "") ?? .vertical
        #endif
        NotificationCenter.default.addObserver(forName: MangaRuntime.throttleNotification, object: nil, queue: .main) { note in
            let seconds = note.userInfo?["seconds"] as? Double ?? 0
            MainActor.assumeIsolated { MangaStore.shared.throttledUntil = Date().addingTimeInterval(seconds) }
        }
        NotificationCenter.default.addObserver(forName: MangaRuntime.noticeNotification, object: nil, queue: .main) { note in
            let text = note.userInfo?["text"] as? String
            MainActor.assumeIsolated { MangaStore.shared.notice = text }
        }
        if selectedSource == nil || !sources.contains(where: { $0.key == selectedSource }) { selectedSource = sources.first?.key }
    }

    var currentSource: MangaInstalledSource? { sources.first { $0.key == selectedSource } ?? sources.first }

    func reloadSources() {
        sources = MangaSources.shared.installed
        repositories = MangaSources.shared.repositories
        if selectedSource == nil || !sources.contains(where: { $0.key == selectedSource }) { selectedSource = sources.first?.key }
    }

    func name(of key: String) -> String { sources.first { $0.key == key }?.name ?? key }

    // MARK: Shelf

    func isFavorite(_ comic: MangaComic) -> Bool { favorites.contains { $0.id == comic.identity } }
    func toggleFavorite(_ comic: MangaComic) {
        if isFavorite(comic) { favorites.removeAll { $0.id == comic.identity } }
        else { favorites.insert(MangaLibrary.Favorite(comic: comic), at: 0) }
        MangaLibrary.save(favorites, as: "favorites.json")
    }

    func progress(_ comic: MangaComic) -> MangaLibrary.Progress? { history.first { $0.id == comic.identity } }
    func record(_ progress: MangaLibrary.Progress) {
        history.removeAll { $0.id == progress.id }
        history.insert(progress, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        MangaLibrary.save(history, as: "history.json")
        // A favorite's cover and title follow what the source last showed.
        if let index = favorites.firstIndex(where: { $0.id == progress.id }) { favorites[index].comic = progress.comic; MangaLibrary.save(favorites, as: "favorites.json") }
    }
    func forget(_ progress: MangaLibrary.Progress) {
        history.removeAll { $0.id == progress.id }
        MangaLibrary.save(history, as: "history.json")
    }
    func clearHistory() { history = []; MangaLibrary.save(history, as: "history.json") }

    func mode(for comic: MangaComic) -> MangaReaderMode { modes[comic.identity].flatMap(MangaReaderMode.init(rawValue:)) ?? readerMode }
    func setMode(_ mode: MangaReaderMode, for comic: MangaComic) {
        modes[comic.identity] = mode == readerMode ? nil : mode.rawValue
        UserDefaults.standard.set(modes, forKey: "manga.readerModes")
    }

    // MARK: Sources

    func install(_ address: URL) async throws {
        try await MangaSources.shared.install(from: address)
        reloadSources()
    }
    func remove(_ key: String) async {
        await MangaSources.shared.remove(key)
        reloadSources()
    }
    func addRepository(_ url: URL) { MangaSources.shared.addRepository(url); reloadSources() }
    func removeRepository(_ url: URL) { MangaSources.shared.removeRepository(url); reloadSources() }
    func move(_ offsets: IndexSet, _ destination: Int) { MangaSources.shared.move(fromOffsets: offsets, toOffset: destination); reloadSources() }
}

enum MangaReaderMode: String, CaseIterable, Identifiable {
    /// Pages one under another, scrolled continuously (webtoons, and most Chinese comics).
    case vertical
    /// One page at a time, turned to the right (Western comics, manhua).
    case leftToRight
    /// One page at a time, turned to the left (Japanese manga).
    case rightToLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .vertical: L10n.text("Vertical Scroll")
        case .leftToRight: L10n.text("Left to Right")
        case .rightToLeft: L10n.text("Right to Left")
        }
    }
    var symbol: String {
        switch self {
        case .vertical: "arrow.down.to.line.compact"
        case .leftToRight: "arrow.right.to.line.compact"
        case .rightToLeft: "arrow.left.to.line.compact"
        }
    }
    var paged: Bool { self != .vertical }
}

/// Covers from a source, requested as the source asks (MangaImages), decoded once and kept in memory.
@MainActor final class MangaCoverCache {
    static let shared = MangaCoverCache()
    private let cache = NSCache<NSString, CGImageBox>()
    final class CGImageBox { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    init() { cache.countLimit = 300; cache.totalCostLimit = 80 << 20 }
    func image(_ key: String) -> CGImage? { cache.object(forKey: key as NSString)?.image }
    func store(_ image: CGImage, _ key: String) { cache.setObject(CGImageBox(image), forKey: key as NSString, cost: image.bytesPerRow * image.height) }
}

struct MangaCover: View {
    let source: String
    let url: String
    @State private var image: CGImage?
    @State private var failed = false
    private var key: String { source + "\n" + url }
    var body: some View {
        #if os(tvOS)
        // One image cropped to the frame and never clipped, as PosterImage draws Watch Now's and Discover's covers: the
        // card button lifts the first image in its label and draws the glass rim around it. A clipped stack never grew.
        GeometryReader { proxy in
            Image(decorative: PosterImage.cover(image, proxy.size), scale: 1).resizable()
                .overlay {
                    if image == nil { Image(systemName: failed ? "photo" : "book.closed").font(.title2).foregroundStyle(.white.opacity(0.5)) }
                }
                .preference(key: CardCoverHeightKey.self, value: proxy.size.height)
        }
        .task(id: key) { await load() }
        #else
        ZStack {
            Rectangle().fill(Color(white: 0.2))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: failed ? "photo" : "book.closed").font(.title2).foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipped()
        .task(id: key) { await load() }
        #endif
    }

    private func load() async {
            if let cached = MangaCoverCache.shared.image(key) { image = cached; return }
            image = nil; failed = false
            guard !url.isEmpty else { failed = true; return }
            do {
                let data = try await MangaImages.shared.data(source: source, url: url, kind: .cover)
                let decoded = await Task.detached(priority: .userInitiated) { MangaImages.bitmap(data, width: 480) }.value
                guard !Task.isCancelled else { return }
                if let decoded { MangaCoverCache.shared.store(decoded, key); image = decoded } else { failed = true }
            } catch { if !Task.isCancelled { failed = true } }
    }
}

/// A cover with its title under it, for grids and shelves.
struct MangaCard: View {
    let comic: MangaComic
    var caption: String? = nil
    var showsSource = false
    var body: some View {
        #if os(tvOS)
        // Watch Now's and Discover's card (WatchNowTVCover): a 2:3 cover the focus lift grows, and one line of title and
        // one of detail under it that move down with it.
        let detail = caption ?? (showsSource ? MangaStore.shared.name(of: comic.sourceKey) : comic.subtitle)
        VStack(spacing: 5) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { MangaCover(source: comic.sourceKey, url: comic.cover) }
            VStack(spacing: 0) {
                Text(comic.title).font(.system(size: 26))
                Text(detail.isEmpty ? " " : detail).font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1).cardCaption()
        }
        .accessibilityElement(children: .combine)
        #else
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { MangaCover(source: comic.sourceKey, url: comic.cover) }
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(comic.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                let detail = caption ?? (showsSource ? MangaStore.shared.name(of: comic.sourceKey) : comic.subtitle)
                Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .cardCaption()
        }
        .accessibilityElement(children: .combine)
        #endif
    }
}

/// Opens a comic's page.
struct MangaComicLink: View {
    let comic: MangaComic
    var caption: String? = nil
    var showsSource = false
    var body: some View {
        RouteLink { MangaDetailView(comic: comic) } label: { MangaCard(comic: comic, caption: caption, showsSource: showsSource) }
            .cardButton()
    }
}

enum MangaLayout {
    #if os(tvOS)
    static let cardWidth: CGFloat = 220
    static let columns = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40, alignment: .top)]
    #elseif os(macOS)
    static let cardWidth: CGFloat = 150
    static let columns = [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 18, alignment: .top)]
    #else
    static let cardWidth: CGFloat = 112
    static let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 12, alignment: .top)]
    #endif
}

/// A titled row of covers that scrolls sideways. On iPhone and the Mac its heading is Watch Now's: the whole line opens
/// the full list (`route`), with a chevron; on Apple TV a See All button does.
struct MangaShelfRow: View {
    let title: String
    let comics: [MangaComic]
    var captions: [String: String] = [:]
    var showsSource = false
    var route: Route? = nil
    @Environment(\.openRoute) private var openRoute

    #if os(tvOS)
    private let gutter = Layout.gutter
    #else
    private let gutter = DiscoverLayout.gutter
    #endif

    var body: some View {
        #if os(tvOS)
        // Watch Now's rail: its heading, covers that lift, and See All waiting at the start of the row.
        WatchNowTVRail(title: title, seeAll: route.map { WatchNowTVSeeAll(height: WatchNowTVCover.height, route: $0) }, gutter: gutter) {
            ForEach(comics) { comic in
                MangaComicLink(comic: comic, caption: captions[comic.identity], showsSource: showsSource)
                    .frame(width: MangaLayout.cardWidth)
            }
        }
        #else
        VStack(alignment: .leading, spacing: 0) {
            WatchNowPhoneHeading(title: title, route: route)
            row
        }
        #endif
    }

    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                ForEach(comics) { comic in
                    MangaComicLink(comic: comic, caption: captions[comic.identity], showsSource: showsSource)
                        .frame(width: MangaLayout.cardWidth)
                }
            }
            .padding(.horizontal, gutter)
            #if os(tvOS)
            .padding(.vertical, 24)
            #endif
        }
        .scrollClipDisabled()
    }
}

/// A shelf that leads nowhere else: its comics as a grid.
struct MangaShelfPage: View {
    let title: String
    let comics: [MangaComic]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: MangaLayout.columns, alignment: .leading, spacing: Layout.gridRowSpacing) {
                ForEach(comics) { MangaComicLink(comic: $0) }
            }
            .padding(Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(title)
    }
}

/// An endless grid of comics: a search, a category, a ranking or an explore list, a page at a time.
struct MangaComicGrid: View {
    let load: (MangaCursor?) async throws -> MangaPage
    var id: String
    @State private var comics: [MangaComic] = []
    @State private var next: MangaCursor?
    @State private var finished = false
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: MangaLayout.columns, alignment: .leading, spacing: Layout.gridRowSpacing) {
                ForEach(comics) { comic in
                    MangaComicLink(comic: comic)
                        .onAppear { if comic.id == comics.last?.id { Task { await more() } } }
                }
            }
            .padding(.horizontal, Layout.gutter)
            if comics.isEmpty, loading, failure == nil { ProgressView().padding(.top, 60) }
            footer
        }
        .task(id: id) { await reset() }
    }

    @ViewBuilder private var footer: some View {
        if let failure {
            EmptyResults(symbol: "exclamationmark.triangle", title: comics.isEmpty ? L10n.text("Unable to Load") : L10n.text("Unable to Load More"),
                         message: failure, action: L10n.text("Try Again")) { Task { await more() } }
        } else if comics.isEmpty, finished {
            EmptyResults(symbol: "books.vertical", title: L10n.text("No Comics"))
        } else if loading, !comics.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        } else if !finished, !comics.isEmpty {
            // Apple TV has no scrolling past the end to trigger the next page: a button does it.
            Button(L10n.text("Load More")) { Task { await more() } }.controlButton().frame(maxWidth: .infinity).padding(24)
        }
    }

    private func reset() async {
        comics = []; next = nil; finished = false; failure = nil
        await more()
    }

    private func more() async {
        guard !loading, !finished else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let page = try await load(comics.isEmpty ? nil : next)
            let known = Set(comics.map(\.id))
            let fresh = page.comics.filter { !known.contains($0.id) }
            if let first = fresh.first { await MangaImages.shared.prepareCovers(source: first.sourceKey, urls: fresh.map(\.cover)) }
            comics += fresh
            next = page.next
            finished = page.next == nil || fresh.isEmpty
        } catch is CancellationError {
        } catch {
            failure = error.mangaMessage
        }
    }
}

/// A source's message, shown briefly at the bottom of the page.
struct MangaNoticeBanner: ViewModifier {
    @State private var store = MangaStore.shared
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let notice = store.notice {
                Text(notice).font(.callout).multilineTextAlignment(.center).lineLimit(4)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { store.notice = nil }
                    }
            }
        }
        .animation(.smooth, value: store.notice)
    }
}

extension View {
    /// A capsule button for tags and quick links: the glass chip on Apple TV, a glass capsule elsewhere.
    @ViewBuilder func mangaPill() -> some View {
        #if os(tvOS)
        glassPill()
        #else
        buttonStyle(MangaPillStyle())
        #endif
    }
}

#if !os(tvOS)
/// A Liquid Glass capsule, as Watch Now's source and filter chips.
private struct MangaPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline).lineLimit(1)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(minHeight: 32)
            .glassOrFill(.regular.interactive(), Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
#endif

extension Error {
    /// What a comic source's failure tells the reader: the site's "too many requests" answer (拷贝漫画's 210) in words.
    var mangaMessage: String {
        if let problem = self as? MangaSiteProblem { return problem.message }
        let text = localizedDescription
        if text.contains("status code: 210") || text.contains("Status Code 210") { return L10n.text("The site is limiting requests right now. Wait a minute, then try again.") }
        let lower = text.lowercased()
        if lower.contains("not logged in") || lower.contains("login required") || lower.contains("please login") || lower.contains("please log in")
            || ["未登录", "请登录", "未登入", "請登入", "需要登录"].contains(where: text.contains) {
            return L10n.text("This source needs you to sign in. Sign in under Settings › Comic Sources.") + "\n" + L10n.text("The source said: %@", text)
        }
        return text
    }
}

/// While a site makes requests wait (拷贝漫画's 210), how long is left, under a page's spinner.
struct MangaWaitNote: View {
    @State private var store = MangaStore.shared
    var body: some View {
        if let until = store.throttledUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = Int(until.timeIntervalSince(context.date).rounded(.up))
                if left > 0 {
                    Text(L10n.text("The site asked to slow down. Continuing in %d s…", left))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).monospacedDigit()
                }
            }
        }
    }
}

extension MangaSiteProblem {
    /// What happened, in words, then what the source itself said.
    var message: String {
        let reason: String = switch kind {
        case .regionBlocked: L10n.text("%@ blocks visitors from your region (HTTP %lld). The app can't get around this; try another source.", host, status)
        case .browserCheck: L10n.text("%@ asks for a browser check (HTTP %lld) that the app can't pass. Pick another domain in this source's settings, or try another source.", host, status)
        case .rateLimited: L10n.text("%@ is limiting requests right now (HTTP %lld). Wait a minute, then try again.", host, status)
        case .signInNeeded: L10n.text("%@ needs you to sign in (HTTP %lld). Sign in under Settings › Comic Sources.", host, status)
        case .notFound: L10n.text("%@ couldn't find this page (HTTP %lld). The source may be out of date; check for an update in Settings › Comic Sources.", host, status)
        case .serverError: L10n.text("%@ is having problems (HTTP %lld). Try again later.", host, status)
        case .refused: L10n.text("%@ refused the request (HTTP %lld).", host, status)
        case .unreachable: L10n.text("Couldn't reach %@. The site may be down or blocked on your network.", host)
        }
        return detail.isEmpty ? reason : reason + "\n" + L10n.text("The source said: %@", detail)
    }
}
