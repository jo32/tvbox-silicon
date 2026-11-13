import SwiftUI
import TVCore

/// What the reader opens: a comic's chapters and where to start.
struct MangaReading: Identifiable {
    let comic: MangaComic
    let chapters: [MangaChapter]
    var chapter: Int
    var page: Int
    var id: String { comic.identity }
}

/// A comic's page: cover, details, tags, chapters, and the Read / Continue button.
struct MangaDetailView: View {
    let comic: MangaComic
    @State private var store = MangaStore.shared
    @State private var details: MangaDetails?
    @State private var failure: String?
    @State private var reading: MangaReading?
    @State private var newestFirst = false
    @State private var group = 0
    @State private var expanded = false
    @Environment(\.openRoute) private var openRoute

    private var current: MangaComic { details?.comic ?? comic }
    private var chapters: [MangaChapter] { details?.chapters ?? [] }
    private var coverURL: String { current.cover.isEmpty ? comic.cover : current.cover }

    #if os(macOS)
    @State private var macPastHero = false
    #endif
    #if !os(tvOS)
    /// The cover, loaded once for the hero.
    @State private var heroCover: CGImage?
    #endif

    var body: some View {
        page
            .modifier(MangaNoticeBanner())
            .task { if details == nil { await load() } }
            #if os(macOS)
            .onChange(of: reading?.id) { _, _ in
                if let reading { openRoute?(Route { AnyView(MangaReaderView(reading: reading)) }); self.reading = nil }
            }
            #else
            .fullScreenCover(item: $reading) { MangaReaderView(reading: $0) }
            #endif
    }

    #if os(macOS)
    private var page: some View { macPage }
    #elseif os(iOS)
    private var page: some View { phonePage }
    #else
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                header
                if let details {
                    if !details.tags.isEmpty { tags(details) }
                    chapterList(details)
                    if !details.recommend.isEmpty {
                        MangaShelfRow(title: L10n.text("Related"), comics: details.recommend).padding(.horizontal, -Layout.gutter)
                    }
                } else if let failure {
                    EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure, action: L10n.text("Try Again")) {
                        Task { await load(fresh: true) }
                    }
                } else {
                    VStack(spacing: 14) { ProgressView(); MangaWaitNote() }.frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(Layout.gutter)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(current.title)
    }
    #endif

    private func load(fresh: Bool = false) async {
        failure = nil
        do {
            let loaded = try await MangaRuntime.shared.details(comic.sourceKey, id: comic.id, fresh: fresh)
            details = loaded
            if let index = store.progress(comic).flatMap({ progress in loaded.groups.firstIndex { $0.chapters.contains { $0.id == progress.chapterID } } }) { group = index }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaMangaRead"), reading == nil { read(at: max(0, UserDefaults.standard.integer(forKey: "qaMangaChapter")), page: 0) }
            #endif
        } catch { failure = error.mangaMessage }
    }

    /// Read from the start, or Continue where the viewer stopped.
    private func readOn() {
        if let progress = store.progress(comic), let index = chapters.firstIndex(where: { $0.id == progress.chapterID }) ?? (chapters.isEmpty ? 0 : nil) {
            read(at: index, page: progress.page)
        } else {
            read(at: 0, page: 0)
        }
    }

    private func read(at index: Int, page: Int) {
        guard let details else { return }
        reading = MangaReading(comic: details.comic.merged(comic), chapters: details.chapters, chapter: index, page: page)
    }

    #if os(tvOS)
    private let coverWidth: CGFloat = 300
    #elseif os(macOS)
    private let coverWidth: CGFloat = 180
    #else
    private let coverWidth: CGFloat = 128
    #endif

    private var cover: some View {
        Color.clear.aspectRatio(3.0 / 4.0, contentMode: .fit).frame(width: coverWidth)
            .overlay { MangaCover(source: comic.sourceKey, url: coverURL) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }

    private var sourceLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "puzzlepiece.extension")
            Text(store.name(of: comic.sourceKey))
            if let update = details?.updateTime, !update.isEmpty { Text("·"); Text(update) }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    // MARK: Header

    #if os(tvOS)
    private var header: some View {
        HStack(alignment: .top, spacing: Layout.cardSpacing * 1.5) {
            cover
            VStack(alignment: .leading, spacing: 10) {
                Text(current.title).font(.title2.weight(.bold)).lineLimit(3)
                if !current.subtitle.isEmpty { Text(current.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                sourceLine
                if !current.description.isEmpty {
                    Text(current.description).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
                // Room above and below the buttons for the focus lift, which grew Continue over the source line.
                tvActions.padding(.top, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tvFocusSection()
    }

    private var tvActions: some View {
        let progress = store.progress(comic)
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
            Button(action: readOn) {
                Label(progress == nil ? L10n.text("Read") : L10n.text("Continue"), systemImage: "book.fill").lineLimit(1).padding(.horizontal, 6)
            }
            .controlButton(prominent: true)
            .disabled(details == nil)
            Button { store.toggleFavorite(current) } label: {
                Label(store.isFavorite(comic) ? L10n.text("Saved") : L10n.text("Favorite"), systemImage: store.isFavorite(comic) ? "heart.fill" : "heart").lineLimit(1)
            }
            .controlButton()
            }
            // Where reading stopped, under the buttons and clear of them when Continue is focused.
            if let progress {
                Text(MangaProgressText.short(progress)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.leading, 8)
            }
        }
    }
    #elseif os(iOS)
    /// Three lines, and More for the rest.
    private var blurb: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(current.description).font(.callout).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded, current.description.count > 60 {
                Text(L10n.text("More")).font(.callout.weight(.semibold))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.smooth) { expanded.toggle() } }
    }
    #endif

    // MARK: Tags and chapters

    private func tags(_ details: MangaDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(details.tags.enumerated()), id: \.offset) { _, tag in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(tag.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
                    MangaFlow(spacing: 8) {
                        ForEach(tag.values, id: \.self) { value in
                            RouteLink { MangaSourceResults(source: comic.sourceKey, keyword: value) } label: { Text(value).lineLimit(1) }
                                .mangaPill()
                        }
                    }
                }
            }
        }
        .tvFocusSection()
    }

    #if os(macOS)
    private let chapterColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
    #else
    private let chapterColumns = [GridItem(.adaptive(minimum: 104), spacing: 10)]
    #endif

    #if os(tvOS)
    @ViewBuilder private func chapterList(_ details: MangaDetails) -> some View {
        let progress = store.progress(comic)
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            HStack {
                if chapters.count > 1 {
                    // As the episode lists: the heading turns the list around, its arrow showing the order.
                    Button { withAnimation(.smooth) { newestFirst.toggle() } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: newestFirst ? "arrow.down" : "arrow.up").contentTransition(.symbolEffect(.replace))
                            Text(L10n.text("Chapters"))
                            Text("\(chapters.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .glassPill()
                    .accessibilityLabel(L10n.text("Reverse Order"))
                    .accessibilityAddTraits(newestFirst ? .isSelected : [])
                } else {
                    SectionHeader(title: details.isSingle ? L10n.text("Pages") : L10n.text("Chapters"))
                }
                Spacer()
            }
            if details.groups.count > 1 {
                ChipRow {
                    HStack(spacing: 10) {
                        ForEach(Array(details.groups.enumerated()), id: \.offset) { index, item in
                            Chip(title: "\(item.title) (\(item.chapters.count))", selected: index == group) { group = index }
                        }
                    }
                }
            }
            if details.isSingle {
                Button { read(at: 0, page: progress?.page ?? 0) } label: { Label(L10n.text("Read"), systemImage: "book") }.controlButton()
            } else {
                let shown = details.groups.indices.contains(group) ? details.groups[group].chapters : chapters
                // The video page's episode chips: Liquid Glass capsules that turn white under focus, the chapter last read
                // shown selected. Names longer than a chip holds get wider columns, as episode names get rows there.
                let longNames = (shown.map(\.title.count).max() ?? 0) > 6
                LazyVGrid(columns: [GridItem(.adaptive(minimum: longNames ? 320 : 170), spacing: 8)], spacing: 8) {
                    ForEach(newestFirst ? shown.reversed() : shown) { chapter in
                        let last = chapter.id == progress?.chapterID
                        Chip(title: chapter.title, selected: last, fill: true) { open(chapter, last: last) }
                            .accessibilityLabel(last ? L10n.text("%@, last read", chapter.title) : chapter.title)
                    }
                }
                // Room for the focused chip, which grows toward the trailing edge.
                .padding(.trailing, 16).padding(.vertical, 6)
            }
        }
        .tvFocusSection()
    }
    #else
    @ViewBuilder private func chapterList(_ details: MangaDetails) -> some View {
        let progress = store.progress(comic)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(details.isSingle ? L10n.text("Pages") : L10n.text("Chapters")).font(.title3.weight(.bold))
                if !details.isSingle { Text("\(chapters.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                if chapters.count > 1 {
                    // As Apple TV's episode lists: an arrow, up for the first chapter first, down for the newest; it turns
                    // over and the chapters move to their new places.
                    Button { withAnimation(.smooth(duration: 0.4)) { newestFirst.toggle() } } label: {
                        Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                            .font(.subheadline.weight(.bold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 34, height: 34)
                            .glassOrFill(.regular.interactive(), Color.primary.opacity(0.07), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Reverse Order"))
                    .accessibilityLabel(L10n.text("Reverse Order"))
                    .accessibilityAddTraits(newestFirst ? .isSelected : [])
                    .accessibilityIdentifier("manga.chapters.reverse")
                }
                Spacer(minLength: 0)
            }
            if details.groups.count > 1 {
                SourceStrip(items: details.groups.indices.map { .init(id: "\($0)", name: details.groups[$0].title, count: details.groups[$0].chapters.count) },
                            selection: "\(group)") { group = Int($0) ?? 0 }
            }
            if details.isSingle {
                Button { read(at: 0, page: progress?.page ?? 0) } label: { chapterLabel(L10n.text("Read"), last: progress != nil) }
                    .buttonStyle(.plain).frame(maxWidth: 240)
            } else {
                let shown = details.groups.indices.contains(group) ? details.groups[group].chapters : chapters
                GlassGroup(spacing: 10) {
                    LazyVGrid(columns: chapterColumns, spacing: 10) {
                        ForEach(newestFirst ? shown.reversed() : shown) { chapter in
                            let last = chapter.id == progress?.chapterID
                            Button { open(chapter, last: last) } label: { chapterLabel(chapter.title, last: last) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(last ? L10n.text("%@, last read", chapter.title) : chapter.title)
                        }
                    }
                }
            }
        }
    }

    /// A chapter as a glass capsule; the one last read is filled with the accent.
    private func chapterLabel(_ title: String, last: Bool) -> some View {
        HStack(spacing: 5) {
            if last { Image(systemName: "book.fill").font(.caption2) }
            Text(title).lineLimit(1).minimumScaleFactor(0.85)
        }
        .font(.subheadline.weight(last ? .semibold : .regular))
        .foregroundStyle(last ? Brand.onAccent : Color.primary)
        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 42)
        .glassOrFill(last ? .regular.tint(Brand.accent).interactive() : .regular.interactive(),
                     last ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
        .contentShape(Capsule())
    }
    #endif

    #if os(iOS)
    // MARK: The iPhone's page

    /// The iPhone and iPad, as Discover's title page: the cover from the screen's top edge, and over its foot the title, one
    /// line of facts, a wide Read or Continue with round plates beside it, and the blurb. Tags, chapters and related comics
    /// follow on a dark page tinted by the cover.
    private var phonePage: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fills = width < 600
            let height = fills ? width * 1.3 : min(640, width * 0.62)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    phoneHero(height: height, fills: fills)
                    Group {
                        if let details {
                            if !details.tags.isEmpty { tags(details) }
                            chapterList(details)
                        } else if let failure {
                            EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure,
                                         action: L10n.text("Try Again")) { Task { await load(fresh: true) } }
                        } else {
                            VStack(spacing: 14) { ProgressView(); MangaWaitNote() }.frame(maxWidth: .infinity).padding(40)
                        }
                    }
                    .padding(.horizontal, DiscoverLayout.gutter)
                    .frame(maxWidth: Layout.maxWidth, alignment: .leading)
                    if let details, !details.recommend.isEmpty {
                        MangaShelfRow(title: L10n.text("Related"), comics: details.recommend)
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .background { MangaPageBackground(image: heroCover) }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .animation(.smooth(duration: 0.3), value: details != nil)
        .task(id: coverURL) { await loadHeroCover() }
    }

    private func phoneHero(height: CGFloat, fills: Bool) -> some View {
        let progress = store.progress(comic)
        let saved = store.isFavorite(comic)
        return VStack(spacing: 14) {
            Text(current.title).font(.system(size: 28, weight: .bold)).multilineTextAlignment(.center)
                .lineLimit(3).minimumScaleFactor(0.7).shadow(color: .black.opacity(0.4), radius: 10)
            Text(phoneFacts).font(.system(size: 13)).multilineTextAlignment(.center).lineLimit(2).opacity(0.85)
            HStack(spacing: 12) {
                Button(action: readOn) {
                    HStack(spacing: 7) {
                        Image(systemName: "book.fill")
                        Text(progress == nil ? L10n.text("Read") : L10n.text("Continue"))
                        if let progress { Text(MangaProgressText.short(progress)).fontWeight(.medium).opacity(0.55) }
                    }
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 54)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(details == nil).opacity(details == nil ? 0.6 : 1)
                .accessibilityIdentifier("manga.read")
                Button { withAnimation(.smooth) { store.toggleFavorite(current) } } label: {
                    Image(systemName: saved ? "heart.fill" : "heart").font(.system(size: 21))
                        .foregroundStyle(saved ? AnyShapeStyle(Brand.rose) : AnyShapeStyle(.white))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 54, height: 54).glassSurface(.regular, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(saved ? L10n.text("Saved") : L10n.text("Favorite"))
                .accessibilityAddTraits(saved ? .isSelected : [])
                .accessibilityIdentifier("manga.favorite")
                if progress != nil, !chapters.isEmpty {
                    Button { read(at: 0, page: 0) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 54, height: 54).glassSurface(.regular, in: Circle()).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Start Over"))
                    .accessibilityIdentifier("manga.startOver")
                }
            }
            .frame(maxWidth: 520)
            if !current.description.isEmpty { blurb.frame(maxWidth: 560) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottom)
        .background(alignment: .top) { MangaPhoneCover(image: heroCover, height: height, fills: fills) }
    }

    /// The source, when it last updated and how many chapters.
    private var phoneFacts: String {
        var facts = [store.name(of: comic.sourceKey)]
        if let update = details?.updateTime, !update.isEmpty { facts.append(L10n.text("Updated %@", update)) }
        if let details, !details.isSingle, !chapters.isEmpty { facts.append("\(L10n.text("Chapters")) \(chapters.count)") }
        return facts.joined(separator: " · ")
    }
    #endif

    #if os(macOS)
    // MARK: The Mac's page

    /// The Mac, as its video pages: the cover's colours from the window's top edge under the toolbar; at the hero's foot
    /// the cover with the title beside it, Read or Continue with round plates under it, and the blurb and tags beside
    /// them. The chapters and related comics follow on a dark page.
    private var macPage: some View {
        GeometryReader { geometry in
            let height = MacHeroMetrics.height(for: geometry.size)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    macHero(height: height, width: geometry.size.width)
                    Group {
                        if let details {
                            chapterList(details)
                        } else if let failure {
                            EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure,
                                         action: L10n.text("Try Again")) { Task { await load(fresh: true) } }
                        } else {
                            VStack(spacing: 14) { ProgressView(); MangaWaitNote() }.frame(maxWidth: .infinity).padding(40)
                        }
                    }
                    .padding(.horizontal, MacHeroMetrics.gutter)
                    if let details, !details.recommend.isEmpty { macRelated(details.recommend) }
                }
                .padding(.bottom, 40)
            }
            // From the window's top edge: the picture runs on under the toolbar, as the video page's.
            .ignoresSafeArea(edges: .top)
            .macHeroScroll(heroHeight: height, past: $macPastHero)
        }
        .background { MangaPageBackground(image: heroCover) }
        .environment(\.colorScheme, .dark)
        .navigationTitle(macPastHero ? current.title : "")
        .artUnderToolbar()
        .animation(.smooth(duration: 0.3), value: details != nil)
        .task(id: coverURL) { await loadHeroCover() }
    }

    private func macHero(height: CGFloat, width: CGFloat) -> some View {
        let blurb = current.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return MacVideoHero(height: height, width: width, backdrop: nil, backdropImage: heroCover, art: heroCover) {
            VStack(alignment: .leading, spacing: 8) {
                    Text(current.title).font(.system(size: 36, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                        .frame(maxWidth: 760, alignment: .leading).textSelection(.enabled)
                        .shadow(color: .black.opacity(0.4), radius: 10)
                    if !current.subtitle.isEmpty {
                        Text(current.subtitle).font(.system(size: 16, weight: .medium)).lineLimit(1).opacity(0.85)
                    }
                Text(macFacts).font(.system(size: 14, weight: .medium)).lineLimit(1).opacity(0.75)
            }
        } actions: {
            macActions
        } side: {
            VStack(alignment: .leading, spacing: 16) {
                if !blurb.isEmpty { MacHeroSynopsis(text: blurb, lines: 4) }
                if let details, !details.tags.isEmpty { tags(details) }
            }
        }
    }

    /// The source, when it last updated and how many chapters, in one line.
    private var macFacts: String {
        var facts = [store.name(of: comic.sourceKey)]
        if let update = details?.updateTime, !update.isEmpty { facts.append(L10n.text("Updated %@", update)) }
        if let details, !details.isSingle, !chapters.isEmpty { facts.append("\(L10n.text("Chapters")) \(chapters.count)") }
        return facts.joined(separator: " · ")
    }

    /// Read, or Continue where reading stopped (and where that is), as wide as the plates under it.
    private var macActions: some View {
        let progress = store.progress(comic)
        let saved = store.isFavorite(comic)
        return VStack(alignment: .leading, spacing: 18) {
            Button(action: readOn) {
                HStack(spacing: 8) {
                    Image(systemName: "book.fill")
                    Text(progress == nil ? L10n.text("Read") : L10n.text("Continue"))
                    if let progress { Text(MangaProgressText.short(progress)).fontWeight(.medium).opacity(0.7) }
                }
                .font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            }
            .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
            .disabled(details == nil)
            .accessibilityIdentifier("manga.read")
            HStack(alignment: .top, spacing: 6) {
                MacPlate(symbol: "heart", caption: saved ? L10n.text("Saved") : L10n.text("Favorite"), on: saved, id: "manga.favorite") {
                    withAnimation(.smooth) { store.toggleFavorite(current) }
                }
                if progress != nil, !chapters.isEmpty {
                    MacPlate(symbol: "arrow.counterclockwise", caption: L10n.text("Start Over"), id: "manga.startOver") {
                        read(at: 0, page: 0)
                    }
                }
            }
        }
    }

    private func macRelated(_ comics: [MangaComic]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Related")).font(.headline).padding(.horizontal, MacHeroMetrics.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(comics) { MangaComicLink(comic: $0).frame(width: MangaLayout.cardWidth) }
                }
                .padding(.horizontal, MacHeroMetrics.gutter)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
    }

    #endif

    #if !os(tvOS)
    /// The cover at the size the hero shows it (larger than the 480 px thumbnails the cover cache keeps).
    private func loadHeroCover() async {
        guard !coverURL.isEmpty,
              let data = try? await MangaImages.shared.data(source: comic.sourceKey, url: coverURL, kind: .cover) else { return }
        let decoded = await Task.detached(priority: .userInitiated) { MangaImages.bitmap(data, width: 1100) }.value
        guard !Task.isCancelled, let decoded else { return }
        withAnimation(.easeInOut(duration: 0.4)) { heroCover = decoded }
    }
    #endif

    private func open(_ chapter: MangaChapter, last: Bool) {
        guard let index = chapters.firstIndex(of: chapter) else { return }
        read(at: index, page: last ? store.progress(comic)?.page ?? 0 : 0)
    }
}

#if !os(tvOS)
/// Under the comic page on the Mac, iPhone and iPad: near black, tinted by a blur of the cover.
struct MangaPageBackground: View {
    let image: CGImage?
    var body: some View {
        ZStack {
            Color(white: 0.05)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: 90, opaque: true).saturation(1.2).opacity(0.28)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
#endif

#if os(iOS)
/// The picture at the top of the iPhone's comic page, as Discover's title page: the cover across the screen from its top
/// edge, darker toward the title over its foot, which fades into the page. On an iPad, too wide to fill with a portrait
/// cover, the cover stands whole over a blur of itself.
struct MangaPhoneCover: View {
    let image: CGImage?
    let height: CGFloat
    let fills: Bool
    var body: some View {
        Color.clear.frame(height: height)
            .overlay(alignment: .top) {
                if let image {
                    if fills {
                        Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .frame(height: height, alignment: .top)
                    } else {
                        ZStack {
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                .blur(radius: 60, opaque: true).saturation(1.2).opacity(0.7)
                            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                                .padding(.top, 90).padding(.bottom, height * 0.36)
                        }
                        .frame(height: height)
                    }
                }
            }
            .overlay {
                ZStack {
                    // The status bar and Back stay readable over a light cover.
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.2)],
                                   startPoint: .top, endPoint: .bottom)
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.55), location: 0.7),
                                           .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .animation(.easeInOut(duration: 0.4), value: image != nil)
            .accessibilityHidden(true)
    }
}
#endif

extension MangaComic {
    /// The details' copy, keeping what the list knew when the details leave it out.
    func merged(_ list: MangaComic) -> MangaComic {
        var comic = self
        if comic.title.isEmpty { comic.title = list.title }
        if comic.cover.isEmpty { comic.cover = list.cover }
        if comic.subtitle.isEmpty { comic.subtitle = list.subtitle }
        return comic
    }
}
