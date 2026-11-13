import SwiftUI
import TVCore

/// The Novels section's state: subscribed Legado book source lists, the bookshelf and the reader's settings.
@MainActor @Observable final class NovelStore {
    static let shared = NovelStore()

    private(set) var lists: [NovelSourceList] = NovelSources.shared.lists
    private(set) var sources: [NovelSource] = NovelSources.shared.all
    private(set) var enabledKeys: Set<String> = Set(NovelSources.shared.enabled.map(\.key))
    private(set) var shelf: [NovelLibrary.ShelfBook] = NovelLibrary.load("shelf.json", as: [NovelLibrary.ShelfBook].self) ?? []
    /// What the last search found, kept while the app runs so Back to the search shows it again.
    var lastSearch: (keyword: String, hits: [NovelSearchHit]) = ("", [])
    /// The group search is limited to (nil: every source that is on). Big lists hold thousands of sources.
    var searchGroup: String? {
        didSet { UserDefaults.standard.set(searchGroup, forKey: "novel.searchGroup"); recomputeScope() }
    }
    /// The source whose explore page the section shows.
    var exploreSource: String? {
        didSet { UserDefaults.standard.set(exploreSource, forKey: "novel.exploreSource"); recomputeExplore() }
    }

    // Reader settings.
    var fontSize: Double { didSet { UserDefaults.standard.set(fontSize, forKey: "novel.fontSize") } }
    /// Line pitch as a multiple of the font size.
    var lineHeight: Double { didSet { UserDefaults.standard.set(lineHeight, forKey: "novel.lineHeight") } }
    /// Space at the sides of the page, in points.
    var margin: Double { didSet { UserDefaults.standard.set(margin, forKey: "novel.margin") } }
    var font: NovelFontChoice { didSet { UserDefaults.standard.set(font.rawValue, forKey: "novel.font") } }
    var theme: NovelTheme { didSet { UserDefaults.standard.set(theme.rawValue, forKey: "novel.theme") } }
    var appearance: NovelAppearance { didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "novel.appearance") } }
    var pageTurn: NovelPageTurn { didSet { UserDefaults.standard.set(pageTurn.rawValue, forKey: "novel.pageTurn") } }

    static let lineHeightRange: ClosedRange<Double> = 1.3...2.4
    #if os(tvOS)
    static let fontRange: ClosedRange<Double> = 26...56
    private static let defaultFont = 36.0
    static let marginRange: ClosedRange<Double> = 60...260
    private static let defaultMargin = 140.0
    #elseif os(macOS)
    static let fontRange: ClosedRange<Double> = 13...36
    private static let defaultFont = 19.0
    static let marginRange: ClosedRange<Double> = 24...140
    private static let defaultMargin = 64.0
    #else
    static let fontRange: ClosedRange<Double> = 13...34
    private static let defaultFont = 19.0
    static let marginRange: ClosedRange<Double> = 10...56
    private static let defaultMargin = 26.0
    #endif

    private init() {
        let defaults = UserDefaults.standard
        exploreSource = defaults.string(forKey: "novel.exploreSource")
        searchGroup = defaults.string(forKey: "novel.searchGroup")
        let size = defaults.double(forKey: "novel.fontSize")
        fontSize = Self.fontRange.contains(size) ? size : Self.defaultFont
        let height = defaults.double(forKey: "novel.lineHeight")
        lineHeight = Self.lineHeightRange.contains(height) ? height : 1.75
        let margin = defaults.double(forKey: "novel.margin")
        self.margin = Self.marginRange.contains(margin) ? margin : Self.defaultMargin
        font = NovelFontChoice(rawValue: defaults.string(forKey: "novel.font") ?? "") ?? .songti
        theme = NovelTheme(rawValue: defaults.string(forKey: "novel.theme") ?? "") ?? .sepia
        appearance = NovelAppearance(rawValue: defaults.string(forKey: "novel.appearance") ?? "") ?? .automatic
        pageTurn = NovelPageTurn(rawValue: defaults.string(forKey: "novel.pageTurn") ?? "") ?? .pages
        recompute()
        NotificationCenter.default.addObserver(forName: NovelSources.changedNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NovelStore.shared.reloadSources() }
        }
    }

    func reloadSources() {
        lists = NovelSources.shared.lists
        sources = NovelSources.shared.all
        enabledKeys = Set(NovelSources.shared.enabled.map(\.key))
        recompute()
        if let key = exploreSource, !explorable.contains(where: { $0.key == key }) { exploreSource = nil }
        if let group = searchGroup, !searchGroups.contains(where: { $0.name == group }) { searchGroup = nil }
    }

    /// Lists hold thousands of sources, and views read these while scrolling, so they are worked out once per change
    /// instead of on every read.
    private func recompute() {
        enabledSources = sources.filter { enabledKeys.contains($0.key) }
        searchable = enabledSources.filter(\.searchable)
        explorable = enabledSources.filter(\.explorable)
        var counts: [String: Int] = [:]
        for source in searchable { for group in source.groups { counts[group, default: 0] += 1 } }
        searchGroups = counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        names = Dictionary(sources.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        recomputeScope()
        recomputeExplore()
    }
    private func recomputeScope() {
        searchScope = searchGroup.map { group in searchable.filter { $0.groups.contains(group) } } ?? searchable
    }
    private func recomputeExplore() {
        currentExplore = explorable.first { $0.key == exploreSource } ?? explorable.first
    }

    private(set) var enabledSources: [NovelSource] = []
    private(set) var searchable: [NovelSource] = []
    private(set) var explorable: [NovelSource] = []
    /// The sources a search asks: the switched-on ones, in the chosen group.
    private(set) var searchScope: [NovelSource] = []
    /// The groups of the searchable sources, biggest first.
    private(set) var searchGroups: [(name: String, count: Int)] = []
    private(set) var currentExplore: NovelSource?
    @ObservationIgnored private var names: [String: String] = [:]
    func name(of key: String) -> String { names[key] ?? URL(string: key)?.host() ?? key }

    // MARK: Lists and sources

    func addList(_ url: URL, data: Data) throws {
        try NovelSources.shared.add(url, data: data)
        reloadSources()
    }
    func removeList(_ url: URL) { NovelSources.shared.remove(url); reloadSources() }
    /// Downloads every list again; one that fails keeps its last copy.
    func refreshLists() async {
        for list in lists { _ = try? await NovelSources.shared.refresh(list.address) }
        reloadSources()
    }
    func refresh(_ url: URL) async throws {
        try await NovelSources.shared.refresh(url)
        reloadSources()
    }
    func setEnabled(_ enabled: Bool, _ keys: [String]) {
        NovelSources.shared.setEnabled(enabled, for: keys)
        reloadSources()
    }

    // MARK: Shelf

    func shelfBook(_ book: NovelBook) -> NovelLibrary.ShelfBook? { shelf.first { $0.id == book.match } }
    func isOnShelf(_ book: NovelBook) -> Bool { shelfBook(book) != nil }
    func toggleShelf(_ book: NovelBook) {
        if isOnShelf(book) { shelf.removeAll { $0.id == book.match } }
        else { shelf.insert(NovelLibrary.ShelfBook(book: book), at: 0) }
        saveShelf()
    }
    func remove(_ entry: NovelLibrary.ShelfBook) {
        shelf.removeAll { $0.id == entry.id }
        saveShelf()
        Task { await NovelBooks.shared.clear(entry.book) }
    }

    /// Where reading stopped. Reading a book puts it on the shelf, most recent first.
    func record(_ book: NovelBook, chapter: NovelChapter, count: Int, position: Double) {
        var entry = shelfBook(book) ?? NovelLibrary.ShelfBook(book: book)
        entry.book = book
        entry.chapterIndex = chapter.index; entry.chapterTitle = chapter.title; entry.chapterCount = count
        entry.position = min(1, max(0, position)); entry.updated = Date()
        shelf.removeAll { $0.id == entry.id }
        shelf.insert(entry, at: 0)
        saveShelf()
    }

    /// Reads the shelf's book from another source from now on, keeping the place by chapter title.
    func switchSource(of old: NovelBook, to book: NovelBook, chapters: [NovelChapter]) {
        guard var entry = shelfBook(old) else { return }
        entry.book = book
        let title = NovelChapterTitle.key(entry.chapterTitle)
        if let match = chapters.first(where: { NovelChapterTitle.key($0.title) == title }) ?? (chapters.indices.contains(entry.chapterIndex) ? chapters[entry.chapterIndex] : nil) {
            entry.chapterIndex = match.index; entry.chapterTitle = match.title
        }
        entry.chapterCount = chapters.count
        if let index = shelf.firstIndex(where: { $0.id == entry.id }) { shelf[index] = entry }
        saveShelf()
    }

    private func saveShelf() { NovelLibrary.save(shelf, as: "shelf.json") }
}

enum NovelChapterTitle {
    /// A chapter title without spaces and punctuation, to find the same chapter in another source's list.
    static func key(_ title: String) -> String { title.lowercased().filter { $0.isLetter || $0.isNumber } }
}

/// Turning pages, or one long column to scroll.
enum NovelPageTurn: String, CaseIterable, Identifiable {
    case pages, scroll
    var id: String { rawValue }
    var title: String { self == .pages ? L10n.text("Paged") : L10n.text("Scroll") }
}

/// Whether the page follows the system's light or dark appearance or keeps one.
enum NovelAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: L10n.text("Automatic")
        case .light: L10n.text("Light")
        case .dark: L10n.text("Dark")
        }
    }
    func isDark(_ system: Bool) -> Bool { self == .dark || (self == .automatic && system) }
}

/// The reader's page colours, each with a light and a dark version (the palettes Readest uses).
enum NovelTheme: String, CaseIterable, Identifiable {
    case standard, gray, sepia, grass, cherry, sky, solarized, gruvbox, nord, contrast, sunset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: L10n.text("Default")
        case .gray: L10n.text("Gray")
        case .sepia: L10n.text("Sepia")
        case .grass: L10n.text("Grass")
        case .cherry: L10n.text("Cherry")
        case .sky: L10n.text("Sky")
        case .solarized: L10n.text("Solarized")
        case .gruvbox: L10n.text("Gruvbox")
        case .nord: L10n.text("Nord")
        case .contrast: L10n.text("Contrast")
        case .sunset: L10n.text("Sunset")
        }
    }
    /// Background and text, as hex.
    private func hex(dark: Bool) -> (background: UInt32, text: UInt32) {
        switch (self, dark) {
        case (.standard, false): (0xFFFFFF, 0x171717)
        case (.standard, true): (0x222222, 0xE0E0E0)
        case (.gray, false): (0xE0E0E0, 0x222222)
        case (.gray, true): (0x444444, 0xC6C6C6)
        case (.sepia, false): (0xF1E8D0, 0x5B4636)
        case (.sepia, true): (0x342E25, 0xFFD595)
        case (.grass, false): (0xD7DBBD, 0x232C16)
        case (.grass, true): (0x333627, 0xD8DEBA)
        case (.cherry, false): (0xF0D1D5, 0x4E1609)
        case (.cherry, true): (0x462F32, 0xE5C4C8)
        case (.sky, false): (0xCEDEF5, 0x262D48)
        case (.sky, true): (0x282E47, 0xBABEE1)
        case (.solarized, false): (0xFDF6E3, 0x586E75)
        case (.solarized, true): (0x002B36, 0x93A1A1)
        case (.gruvbox, false): (0xFBF1C7, 0x3C3836)
        case (.gruvbox, true): (0x282828, 0xEBDBB2)
        case (.nord, false): (0xECEFF4, 0x2E3440)
        case (.nord, true): (0x2E3440, 0xD8DEE9)
        case (.contrast, false): (0xFFFFFF, 0x000000)
        case (.contrast, true): (0x000000, 0xFFFFFF)
        case (.sunset, false): (0xFFF7F0, 0x423126)
        case (.sunset, true): (0x3C2B25, 0xF6E1D7)
        }
    }
    func colors(dark: Bool) -> (background: Color, text: Color) {
        let hex = hex(dark: dark)
        return (Color(novelHex: hex.background), Color(novelHex: hex.text))
    }
}

extension Color {
    init(novelHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Covers and cards

/// A book cover from its source (with the headers it asks for); a titled placeholder when it has none.
struct NovelCover: View {
    let book: NovelBook
    var body: some View {
        if let request = book.coverRequest {
            PosterImage(url: request.url, headers: request.headers, symbol: "book.closed")
        } else {
            NovelPlainCover(title: book.name, author: book.author)
        }
    }
}

/// A cover drawn for books without one: the title on a tinted board, as printed spines are.
struct NovelPlainCover: View {
    let title: String
    let author: String
    /// From the title's characters, so a book keeps its colour (hashValue changes every launch).
    private var hue: Double { Double(title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 3600 } % 360) / 360 }
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.42), Color(hue: hue, saturation: 0.45, brightness: 0.26)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Rectangle().fill(.white.opacity(0.10)).frame(width: max(2, width * 0.035)).padding(.leading, width * 0.07)
                VStack(alignment: .leading, spacing: width * 0.05) {
                    Text(title).font(.system(size: max(10, width * 0.13), weight: .bold, design: .serif)).lineLimit(4).minimumScaleFactor(0.6)
                    if !author.isEmpty { Text(author).font(.system(size: max(8, width * 0.08))).lineLimit(1).opacity(0.75) }
                }
                .foregroundStyle(.white)
                .padding(.leading, width * 0.17).padding(.trailing, width * 0.08).padding(.top, width * 0.14)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A cover with its title and a detail line under it, for shelves and grids.
struct NovelCard: View {
    let book: NovelBook
    var caption: String? = nil
    var body: some View {
        let detail = caption ?? book.author
        #if os(tvOS)
        VStack(spacing: 5) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).overlay { NovelCover(book: book) }
            VStack(spacing: 0) {
                Text(book.name).font(.system(size: 26))
                Text(detail.isEmpty ? " " : detail).font(.system(size: 22, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1).cardCaption()
        }
        .accessibilityElement(children: .combine)
        #else
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay { NovelCover(book: book) }
                .posterClip(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .cardCaption()
        }
        .accessibilityElement(children: .combine)
        #endif
    }
}

/// Opens a book's page. `alternatives` are the same book from other sources (from a search).
struct NovelBookLink: View {
    let book: NovelBook
    var alternatives: [NovelBook] = []
    var caption: String? = nil
    var body: some View {
        RouteLink { NovelDetailView(book: book, alternatives: alternatives) } label: { NovelCard(book: book, caption: caption) }
            .cardButton()
    }
}

enum NovelLayout {
    #if os(tvOS)
    static let cardWidth: CGFloat = 220
    static let columns = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40, alignment: .top)]
    #elseif os(macOS)
    static let cardWidth: CGFloat = 140
    static let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18, alignment: .top)]
    #else
    static let cardWidth: CGFloat = 104
    static let columns = [GridItem(.adaptive(minimum: 98, maximum: 140), spacing: 12, alignment: .top)]
    #endif
}

/// A titled row of books that scrolls sideways, as the Manga and Watch Now shelves.
struct NovelShelfRow<Item: Identifiable>: View {
    let title: String
    let items: [Item]
    var route: Route? = nil
    let link: (Item) -> NovelBookLink

    var body: some View {
        #if os(tvOS)
        WatchNowTVRail(title: title, seeAll: route.map { WatchNowTVSeeAll(height: WatchNowTVCover.height, route: $0) }, gutter: Layout.gutter) {
            ForEach(items) { link($0).frame(width: NovelLayout.cardWidth) }
        }
        #else
        VStack(alignment: .leading, spacing: 0) {
            WatchNowPhoneHeading(title: title, route: route)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Layout.cardSpacing) {
                    ForEach(items) { link($0).frame(width: NovelLayout.cardWidth) }
                }
                .padding(.horizontal, DiscoverLayout.gutter)
            }
            .scrollClipDisabled()
        }
        #endif
    }
}

enum NovelProgressText {
    static func short(_ entry: NovelLibrary.ShelfBook) -> String {
        guard entry.started else { return L10n.text("Not started") }
        if entry.chapterCount > 0 { return L10n.text("%lld of %lld", entry.chapterIndex + 1, entry.chapterCount) }
        return entry.chapterTitle
    }
}

extension Error {
    /// A book source's failure in words.
    var novelMessage: String {
        let text = localizedDescription
        if (self as? URLError)?.code == .timedOut || text.lowercased().contains("timed out") { return L10n.text("The source took too long to answer. Try again, or switch to another source.") }
        return text
    }
}
