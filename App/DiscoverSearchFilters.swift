import SwiftUI
import TVCore

enum DiscoverFilterSection: String, CaseIterable {
    case keywords, type, genres, years, sort, platform, language, region
    var title: String {
        L10n.text([Self.keywords: "Keywords", .type: "Content Type", .genres: "Topics", .years: "Years", .sort: "Sort By",
                   .platform: "Platform / Studio", .language: "Language", .region: "Region"][self]!)
    }
    func chipTitle(_ filter: TMDBCatalog.Filter?) -> String {
        let label = L10n.text([Self.type: "Filter Type", .genres: "Filter Genre", .years: "Years", .sort: "Sort By", .platform: "Platform / Studio", .language: "Language", .region: "Region", .keywords: "Keywords"][self]!)
        let value: String
        if let filter {
            switch self {
            case .type: value = filter.kind.title
            case .genres: value = filter.genres.sorted().compactMap { DiscoverGenres.names[$0].map { L10n.text($0) } }.joined(separator: "、")
            case .years: value = filter.from == filter.to ? filter.from : "\(filter.from)–\(filter.to)"
            case .sort: value = L10n.text(["popularity.desc": "Popularity ↓", "popularity.asc": "Popularity ↑", "vote_average.desc": "Rating ↓", "vote_average.asc": "Rating ↑", "date.desc": "Newest First", "date.asc": "Oldest First", "vote_count.desc": "Most Votes", "revenue.desc": "Highest Revenue"][filter.sort] ?? "Popularity ↓")
            case .platform: value = ["213":"Netflix", "2739":"Disney+", "2552":"Apple TV+", "49":"HBO", "174":"Warner Bros.", "33":"Universal", "4":"Paramount", "34":"Sony Pictures", "2":"Disney"][filter.company] ?? ""
            case .language: value = filter.originalLanguage.isEmpty ? "" : Locale(identifier: TMDBMatch.language).localizedString(forLanguageCode: filter.originalLanguage) ?? ""
            case .region: value = filter.region.isEmpty ? "" : Locale(identifier: TMDBMatch.language).localizedString(forRegionCode: filter.region) ?? ""
            case .keywords: value = filter.keywords.map(\.name).joined(separator: "、")
            }
        } else { value = self == .sort ? L10n.text("Popularity ↓") : "" }
        return label + "：" + (value.isEmpty ? L10n.text("Any") : value)
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

struct DiscoverSearchFilters: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var filter: TMDBCatalog.Filter
    let section: DiscoverFilterSection
    @State private var keyword = ""
    @State private var suggestions: [TMDBCatalog.Keyword] = []
    @State private var lookingUp = false
    @State private var lookupFailed = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private let languages = ["zh", "en", "ja", "ko", "fr", "de", "es", "it", "hi", "th"]
    private let regions = ["CN", "HK", "TW", "US", "GB", "JP", "KR", "FR", "DE", "IN", "TH"]
    private let movieGenres = [28,12,16,35,80,99,18,10751,14,36,27,10402,9648,10749,878,10770,53,10752,37]
    private let tvGenres = [10759,16,35,80,99,18,10751,10762,9648,10763,10764,10765,10766,10767,10768,37]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { editor }
                .padding(.horizontal, 16).padding(.vertical, 12)
        }.scrollIndicators(.hidden)
            .frame(idealHeight: panelHeight, maxHeight: panelHeight)
            .glassSurface(.regular.tint((scheme == .dark ? Color(red: 0.27, green: 0.23, blue: 0.31) : Color(red: 0.94, green: 0.91, blue: 0.97)).opacity(0.65)), in: RoundedRectangle(cornerRadius: 28))
            .accessibilityIdentifier("discover.filter.panel")
    }
    private var panelHeight: CGFloat {
        switch section {
        case .genres, .years: return 324
        case .sort: return 400
        case .keywords: return 260
        case .language, .region: return 188
        default: return 144
        }
    }
    @ViewBuilder private var editor: some View {
        switch section {
        case .type:
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach([TMDBCatalog.SearchKind.movie, .tv], id: \.self) { kind in
                    choice(kind.title, selected: filter.kind == kind) {
                        if filter.kind != kind { filter.kind = kind; filter.genres = []; filter.company = ""; if kind == .tv && filter.sort == "revenue.desc" { filter.sort = "popularity.desc" } }
                    }.accessibilityIdentifier("discover.filter.type.\(kind.rawValue)")
                }
            }
        case .genres:
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(filter.kind == .tv ? tvGenres : movieGenres, id: \.self) { id in
                    choice(L10n.text(DiscoverGenres.names[id] ?? (id == 10766 ? "Soap" : "War & Politics")), selected: filter.genres.contains(id)) {
                        if filter.genres.contains(id) { filter.genres.remove(id) } else if filter.genres.count < 8 { filter.genres.insert(id) }
                    }.accessibilityIdentifier("discover.filter.genre.\(id)")
                }
            }
        case .years:
            LazyVGrid(columns: columns, spacing: 8) {
                choice(L10n.text("Any"), selected: filter.from.isEmpty && filter.to.isEmpty) { filter.from = ""; filter.to = "" }
                ForEach(Array(stride(from: Calendar.current.component(.year, from: Date()), through: Calendar.current.component(.year, from: Date()) - 4, by: -1)), id: \.self) { year in
                    choice(String(year), selected: filter.from == String(year) && filter.to == String(year)) { filter.from = String(year); filter.to = String(year) }
                }
                ForEach(Array(stride(from: 2020, through: 1900, by: -10)), id: \.self) { year in
                    choice(L10n.text("%@s", String(year)), selected: filter.from == String(year) && filter.to == String(year + 9)) { filter.from = String(year); filter.to = String(year + 9) }
                }
            }
        case .sort:
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(sortOptions, id: \.0) { value, label in
                    choice(L10n.text(label), selected: filter.sort == value) { filter.sort = value }
                }
            }
            Text(L10n.text("Minimum Rating")).font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach([0,6,7,8,9], id: \.self) { rating in
                    choice(rating == 0 ? L10n.text("Any") : "\(rating)+", selected: filter.rating == rating) { filter.rating = rating }
                }
            }
            Text(L10n.text("Minimum Votes")).font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach([0,100,500,1000,5000], id: \.self) { votes in
                    choice(votes == 0 ? L10n.text("Any") : "\(votes)+", selected: filter.votes == votes) { filter.votes = votes }
                }
            }
            range(L10n.text("Runtime (min)"), from: $filter.minRuntime, to: $filter.maxRuntime, hint: "90", id: "runtime")
        case .platform:
            LazyVGrid(columns: columns, spacing: 8) {
                choice(L10n.text("Any"), selected: filter.company.isEmpty) { filter.company = "" }
                ForEach(platforms, id: \.0) { id, name in choice(name, selected: filter.company == id) { filter.company = id } }
            }
        case .language:
            LazyVGrid(columns: columns, spacing: 8) {
                choice(L10n.text("Any"), selected: filter.originalLanguage.isEmpty) { filter.originalLanguage = "" }
                ForEach(languages, id: \.self) { code in
                    choice(Locale(identifier: TMDBMatch.language).localizedString(forLanguageCode: code) ?? code, selected: filter.originalLanguage == code) { filter.originalLanguage = code }
                }
            }
        case .region:
            LazyVGrid(columns: columns, spacing: 8) {
                choice(L10n.text("Any"), selected: filter.region.isEmpty) { filter.region = "" }
                ForEach(regions, id: \.self) { code in
                    choice(Locale(identifier: TMDBMatch.language).localizedString(forRegionCode: code) ?? code, selected: filter.region == code) { filter.region = code }
                }
            }
        case .keywords:
            TextField(L10n.text("Find a keyword"), text: $keyword).textFieldStyle(.plain).padding(15).glassSurface(.regular, in: Capsule())
                .autocorrectionDisabled().accessibilityIdentifier("discover.filter.keyword")
            if !filter.keywords.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(filter.keywords) { value in choice(value.name + " ×", selected: true) { filter.keywords.removeAll { $0.id == value.id } } }
                }
            }
            if lookingUp { ProgressView() }
            if lookupFailed { Text(L10n.text("Couldn't Load Results")).foregroundStyle(.secondary) }
            ForEach(suggestions) { value in
                Button {
                    if !filter.keywords.contains(where: { $0.id == value.id }), filter.keywords.count < 8 { filter.keywords.append(value) }
                } label: {
                    HStack { Text(value.name); Spacer(); if filter.keywords.contains(where: { $0.id == value.id }) { Image(systemName: "checkmark") } }
                        .padding(.vertical, 10).contentShape(Rectangle())
                }
            }
            Color.clear.frame(height: 1).task(id: keyword) {
                suggestions = []; lookupFailed = false; lookingUp = false
                let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return }
                lookingUp = true
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    let page = try await TMDBCatalog.search(query: query, keywords: true)
                    try Task.checkCancellation(); suggestions = page.keywords; lookingUp = false
                } catch { if !Task.isCancelled { lookupFailed = true; lookingUp = false } }
            }
        }
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity).frame(height: 36)
                .foregroundStyle(selected ? (scheme == .dark ? Color.black : Color.white) : Color.primary)
                .background { if selected { Capsule().fill(Color.primary) } }
                .glassSurface(selected ? .identity : .regular, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func range(_ title: String, from: Binding<String>, to: Binding<String>, hint: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            HStack {
                TextField(L10n.text("From"), text: from).accessibilityIdentifier("discover.filter.\(id).from")
                Text("—").foregroundStyle(.secondary)
                TextField(L10n.text("To"), text: to).accessibilityIdentifier("discover.filter.\(id).to")
            }.textFieldStyle(.roundedBorder)
        }
    }
    private var platforms: [(String, String)] {
        filter.kind == .tv ? [("213", "Netflix"), ("2739", "Disney+"), ("2552", "Apple TV+"), ("49", "HBO")]
            : [("174", "Warner Bros."), ("33", "Universal"), ("4", "Paramount"), ("34", "Sony Pictures"), ("2", "Disney")]
    }
    private var sortOptions: [(String, String)] {
        [("popularity.desc", "Popularity ↓"), ("popularity.asc", "Popularity ↑"), ("vote_average.desc", "Rating ↓"), ("vote_average.asc", "Rating ↑"),
         ("date.desc", "Newest First"), ("date.asc", "Oldest First"), ("vote_count.desc", "Most Votes")]
        + (filter.kind == .movie ? [("revenue.desc", "Highest Revenue")] : [])
    }
}
