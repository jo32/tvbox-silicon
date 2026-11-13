import SwiftUI
import TVCore

/// What the reader opens: a book's table of contents and where to start.
struct NovelReading: Identifiable {
    let book: NovelBook
    let chapters: [NovelChapter]
    var chapter: Int
    /// How far into that chapter, 0–1.
    var position: Double
    var id: String { book.id }
}

/// A book's page: cover, author, intro, the latest chapter, Read / Continue, the table of contents and the source it is
/// read from, which can be switched to another that has the same book.
struct NovelDetailView: View {
    @State private var book: NovelBook
    @State private var alternatives: [NovelBook]
    @State private var store = NovelStore.shared
    @State private var details: NovelBook?
    @State private var chapters: [NovelChapter] = []
    @State private var failure: String?
    @State private var reading: NovelReading?
    @State private var expanded = false
    @State private var heroCover: CGImage?
    @Environment(\.openRoute) private var openRoute
    #if os(macOS)
    @State private var macPastHero = false
    #endif

    init(book: NovelBook, alternatives: [NovelBook] = []) {
        // A shelf book opens from the source it was last read from.
        let saved = NovelStore.shared.shelfBook(book)?.book
        _book = State(initialValue: saved ?? book)
        _alternatives = State(initialValue: alternatives)
    }

    private var current: NovelBook { details ?? book }
    /// The shelf's copy, found by the filled-in details too: a list entry without the author doesn't match the shelf's.
    private var entry: NovelLibrary.ShelfBook? { store.shelfBook(current) ?? store.shelfBook(book) }
    private func toggleShelf() { store.toggleShelf(entry?.book ?? current) }
    private var readable: [NovelChapter] { chapters.filter { !$0.isVolume } }

    var body: some View {
        page
            .task(id: book.id) { await load() }
            .task(id: current.cover) { await loadHeroCover() }
            #if os(macOS)
            .onChange(of: reading?.id) { _, _ in
                if let reading { openRoute?(Route { AnyView(NovelReaderView(reading: reading)) }); self.reading = nil }
            }
            #else
            .fullScreenCover(item: $reading) { NovelReaderView(reading: $0) }
            #endif
    }

    private func load(refresh: Bool = false) async {
        failure = nil
        if refresh { details = nil; chapters = [] }
        do {
            let filled = try await NovelBooks.shared.details(book)
            details = filled
            chapters = try await NovelBooks.shared.chapters(filled, refresh: refresh || entry == nil)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaNovelRead"), reading == nil { readOn() }
            #endif
        } catch is CancellationError {
        } catch {
            failure = error.novelMessage
        }
    }

    private func loadHeroCover() async {
        guard let request = current.coverRequest,
              let image = await PosterPalette.image(request.url, headers: request.headers),
              !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.4)) { heroCover = image }
    }

    /// Read from the start, or Continue where the viewer stopped.
    private func readOn() {
        if let entry, entry.started, chapters.indices.contains(entry.chapterIndex) {
            read(at: entry.chapterIndex, position: entry.position)
        } else {
            read(at: readable.first?.index ?? 0, position: 0)
        }
    }

    private func read(at index: Int, position: Double) {
        guard !chapters.isEmpty else { return }
        reading = NovelReading(book: current, chapters: chapters, chapter: min(index, chapters.count - 1), position: position)
    }

    private func switchTo(_ other: NovelBook) {
        guard other.id != book.id else { return }
        let old = book
        if !alternatives.contains(where: { $0.id == old.id }) { alternatives.insert(old, at: 0) }
        book = other; details = nil; chapters = []; heroCover = nil
        Task {
            guard store.isOnShelf(old) else { return }
            // The shelf follows to the new source, its place kept by chapter title.
            if let filled = try? await NovelBooks.shared.details(other), let list = try? await NovelBooks.shared.chapters(filled, refresh: true) {
                store.switchSource(of: old, to: filled, chapters: list)
            }
        }
    }

    // MARK: Shared parts

    private var facts: String {
        var parts: [String] = []
        if !current.author.isEmpty { parts.append(current.author) }
        let kinds = current.kind.split(whereSeparator: { ",， ".contains($0) }).prefix(3).joined(separator: " ")
        if !kinds.isEmpty { parts.append(kinds) }
        // Some rules pick several elements for the count, one per line: the first is the count.
        if let count = current.wordCount.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !count.isEmpty {
            parts.append(count)
        }
        return parts.joined(separator: " · ")
    }

    private var readTitle: String { entry?.started == true ? L10n.text("Continue") : L10n.text("Read") }
    private var progressText: String? { entry.flatMap { $0.started ? NovelProgressText.short($0) : nil } }

    /// The table of contents and the source, as rows under the intro.
    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !current.lastChapter.isEmpty || !readable.isEmpty {
                RouteLink {
                    NovelTOCView(book: current, chapters: chapters)
                } label: {
                    // One line, as tall as the Source row: the latest chapter, the count at the right end. A "Contents"
                    // title said nothing the icon doesn't.
                    NovelRow(symbol: "list.bullet",
                             title: readable.last.map { L10n.text("Latest: %@", $0.title) } ?? current.lastChapter,
                             detail: readable.isEmpty ? "" : L10n.text("%lld chapters", readable.count))
                }
                .novelRowButton()
                .accessibilityHint(L10n.text("Contents"))
                .disabled(chapters.isEmpty)
                .accessibilityIdentifier("novel.contents")
            }
            RouteLink {
                NovelSourcePicker(book: current, alternatives: alternatives) { switchTo($0) }
            } label: {
                NovelRow(symbol: "arrow.left.arrow.right", title: L10n.text("Source"), detail: store.name(of: book.sourceKey),
                         note: alternatives.count > 1 ? L10n.text("%lld sources have this book", alternatives.count) : nil)
            }
            .novelRowButton()
            .accessibilityIdentifier("novel.source")
        }
        .tvFocusSection()
    }

    @ViewBuilder private var status: some View {
        if let failure {
            EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure) {
                HStack(spacing: 12) {
                    Button(L10n.text("Try Again")) { Task { await load(refresh: true) } }.controlButton()
                    RouteLink { NovelSourcePicker(book: current, alternatives: alternatives) { switchTo($0) } } label: {
                        Text(L10n.text("Change Source"))
                    }
                    .controlButton()
                }
            }
        } else if chapters.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(30)
        }
    }

    private var blurb: some View {
        let text = current.intro.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.callout).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if !expanded, text.count > 80 { Text(L10n.text("More")).font(.callout.weight(.semibold)) }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.smooth) { expanded.toggle() } }
    }

    // MARK: Pages

    #if os(iOS)
    /// As the comic page: the cover from the screen's top edge, the title and facts over its foot, a wide Read button with
    /// round plates beside it, then the intro, contents and source on a dark page tinted by the cover.
    private var page: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fills = width < 600
            let height = fills ? width * 1.25 : min(620, width * 0.6)
            if width >= 700 { padPage(size: geometry.size) } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    phoneHero(height: height, fills: fills)
                    VStack(alignment: .leading, spacing: 20) {
                        if !current.intro.isEmpty { blurb }
                        status
                        rows
                    }
                    .padding(.horizontal, DiscoverLayout.gutter)
                    .frame(maxWidth: Layout.maxWidth, alignment: .leading)
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            }
        }
        .background { MangaPageBackground(image: heroCover) }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .animation(.smooth(duration: 0.3), value: chapters.isEmpty)
    }

    /// iPad, as the Mac's page: the cover large in the hero's corner over a blur of itself, the title, Read and the plates
    /// at its foot with the intro beside them, the chapters under it.
    private func padPage(size: CGSize) -> some View {
        let height = max(460, min(size.height * 0.7, size.width * 0.6, 720))
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.name).font(.system(size: 38, weight: .bold, design: .serif)).lineLimit(2).minimumScaleFactor(0.6)
                            .frame(maxWidth: 760, alignment: .leading).shadow(color: .black.opacity(0.4), radius: 10)
                        if !facts.isEmpty { Text(facts).font(.system(size: 15, weight: .medium)).lineLimit(1).opacity(0.75) }
                    }
                    HStack(alignment: .top, spacing: 40) {
                        padActions.frame(width: 340, alignment: .leading)
                        if !current.intro.isEmpty { blurb.frame(maxWidth: 560, alignment: .leading) }
                    }
                }
                .padding(.horizontal, 40).padding(.bottom, 36)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
                .background { NovelHeroBackdrop(image: heroCover).ignoresSafeArea() }
                .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 18) {
                    status
                    if !chapters.isEmpty {
                        NovelChapterGrid(chapters: chapters, current: entry.flatMap { $0.started ? $0.chapterIndex : nil }) { index in
                            read(at: index, position: entry?.chapterIndex == index ? entry?.position ?? 0 : 0)
                        }
                    }
                }
                .padding(.horizontal, 40)
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    private var padActions: some View {
        let shelved = entry != nil
        return VStack(alignment: .leading, spacing: 18) {
            Button(action: readOn) {
                HStack(spacing: 7) {
                    Image(systemName: "book.fill")
                    Text(readTitle)
                    if let progressText { Text(progressText).fontWeight(.medium).opacity(0.55) }
                }
                .font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(.black)
                .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 50)
                .background(Capsule().fill(.white))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(chapters.isEmpty).opacity(chapters.isEmpty ? 0.6 : 1)
            .accessibilityIdentifier("novel.read")
            HStack(alignment: .top, spacing: 6) {
                Button { withAnimation(.smooth) { toggleShelf() } } label: {
                    // The plate adds ".fill" when on.
                    WatchPlateLabel(symbol: shelved ? "books.vertical" : "plus", caption: shelved ? L10n.text("On Bookshelf") : L10n.text("Add to Bookshelf"),
                                    on: shelved, tint: Brand.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("novel.shelf")
                if entry?.started == true, !chapters.isEmpty {
                    Button { read(at: readable.first?.index ?? 0, position: 0) } label: {
                        WatchPlateLabel(symbol: "arrow.counterclockwise", caption: L10n.text("Start Over"))
                    }
                    .buttonStyle(.plain)
                }
                RouteLink { NovelSourcePicker(book: current, alternatives: alternatives) { switchTo($0) } } label: {
                    WatchPlateLabel(symbol: "arrow.left.arrow.right", caption: store.name(of: book.sourceKey))
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("Change Source"))
                .accessibilityIdentifier("novel.source")
            }
            .environment(\.colorScheme, .dark)
        }
    }

    private func phoneHero(height: CGFloat, fills: Bool) -> some View {
        let shelved = entry != nil
        return VStack(spacing: 14) {
            Text(current.name).font(.system(size: 28, weight: .bold, design: .serif)).multilineTextAlignment(.center)
                .lineLimit(3).minimumScaleFactor(0.7).shadow(color: .black.opacity(0.4), radius: 10)
            if !facts.isEmpty { Text(facts).font(.system(size: 13)).multilineTextAlignment(.center).lineLimit(2).opacity(0.85) }
            HStack(spacing: 12) {
                Button(action: readOn) {
                    HStack(spacing: 7) {
                        Image(systemName: "book.fill")
                        Text(readTitle)
                        if let progressText { Text(progressText).fontWeight(.medium).opacity(0.55) }
                    }
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16).frame(maxWidth: .infinity).frame(height: 54)
                    .background(Capsule().fill(.white))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(chapters.isEmpty).opacity(chapters.isEmpty ? 0.6 : 1)
                .accessibilityIdentifier("novel.read")
                Button { withAnimation(.smooth) { toggleShelf() } } label: {
                    Image(systemName: shelved ? "books.vertical.fill" : "plus").font(.system(size: 20))
                        .foregroundStyle(shelved ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.white))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 54, height: 54).glassSurface(.regular, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shelved ? L10n.text("On Bookshelf") : L10n.text("Add to Bookshelf"))
                .accessibilityAddTraits(shelved ? .isSelected : [])
                .accessibilityIdentifier("novel.shelf")
                if entry?.started == true, !chapters.isEmpty {
                    Button { read(at: readable.first?.index ?? 0, position: 0) } label: {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 54, height: 54).glassSurface(.regular, in: Circle()).contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Start Over"))
                }
            }
            .frame(maxWidth: 520)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottom)
        .background(alignment: .top) {
            if current.coverRequest == nil {
                // No cover: the drawn one, small, over the dark page.
                NovelPlainCover(title: current.name, author: current.author).frame(width: 150, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(.top, 110)
            } else {
                MangaPhoneCover(image: heroCover, height: height, fills: fills)
            }
        }
    }
    #elseif os(macOS)
    /// As the Mac's video and comic pages: the cover's colours under the toolbar, the cover large at the trailing edge,
    /// the title, Read and plates at the hero's foot with the intro beside them.
    private var page: some View {
        GeometryReader { geometry in
            let height = MacHeroMetrics.height(for: geometry.size)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    MacVideoHero(height: height, width: geometry.size.width, backdrop: nil, backdropImage: heroCover, art: heroCover) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(current.name).font(.system(size: 36, weight: .bold, design: .serif)).lineLimit(2).minimumScaleFactor(0.6)
                                .frame(maxWidth: 760, alignment: .leading).textSelection(.enabled)
                                .shadow(color: .black.opacity(0.4), radius: 10)
                            if !facts.isEmpty { Text(facts).font(.system(size: 14, weight: .medium)).lineLimit(1).opacity(0.75) }
                        }
                    } actions: {
                        macActions
                    } side: {
                        if !current.intro.isEmpty { MacHeroSynopsis(text: current.intro.trimmingCharacters(in: .whitespacesAndNewlines), lines: 5) }
                    }
                    // The chapters themselves under the hero, as the comic page's; the source is a plate beside the shelf.
                    VStack(alignment: .leading, spacing: 18) {
                        status
                        if !chapters.isEmpty {
                            NovelChapterGrid(chapters: chapters, current: entry.flatMap { $0.started ? $0.chapterIndex : nil }) { index in
                                read(at: index, position: entry?.chapterIndex == index ? entry?.position ?? 0 : 0)
                            }
                        }
                    }
                    .padding(.horizontal, MacHeroMetrics.gutter)
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .macHeroScroll(heroHeight: height, past: $macPastHero)
        }
        .background { MangaPageBackground(image: heroCover) }
        .environment(\.colorScheme, .dark)
        .navigationTitle(macPastHero ? current.name : "")
        .artUnderToolbar()
        .animation(.smooth(duration: 0.3), value: chapters.isEmpty)
    }

    private var macActions: some View {
        let shelved = entry != nil
        return VStack(alignment: .leading, spacing: 18) {
            Button(action: readOn) {
                HStack(spacing: 8) {
                    Image(systemName: "book.fill")
                    Text(readTitle)
                    if let progressText { Text(progressText).fontWeight(.medium).opacity(0.7) }
                }
                .font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            }
            .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
            .disabled(chapters.isEmpty)
            .accessibilityIdentifier("novel.read")
            HStack(alignment: .top, spacing: 6) {
                // The plate adds ".fill" when on: "books.vertical.fill" here asked for a symbol that doesn't exist.
                MacPlate(symbol: shelved ? "books.vertical" : "plus", caption: shelved ? L10n.text("On Bookshelf") : L10n.text("Add to Bookshelf"),
                         on: shelved, tint: Brand.accent, id: "novel.shelf") {
                    withAnimation(.smooth) { toggleShelf() }
                }
                if entry?.started == true, !chapters.isEmpty {
                    MacPlate(symbol: "arrow.counterclockwise", caption: L10n.text("Start Over"), id: "novel.startOver") {
                        read(at: readable.first?.index ?? 0, position: 0)
                    }
                }
                MacPlate(symbol: "arrow.left.arrow.right", caption: store.name(of: book.sourceKey), id: "novel.source") {
                    openRoute?(Route { AnyView(NovelSourcePicker(book: current, alternatives: alternatives) { switchTo($0) }) })
                }
                .help(alternatives.count > 1 ? L10n.text("%lld sources have this book", alternatives.count) : L10n.text("Change Source"))
            }
        }
    }
    #else
    /// Apple TV, as the Mac's page: the cover large in the hero's corner over a blur of itself, the title, facts and intro
    /// at its foot over the buttons, then the chapters in columns under it.
    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 18) {
                    Text(current.name).font(.system(size: 66, weight: .bold, design: .serif)).lineLimit(2).minimumScaleFactor(0.6)
                        .frame(maxWidth: 1100, alignment: .leading).shadow(color: .black.opacity(0.4), radius: 12)
                    if !facts.isEmpty { Text(facts).font(.callout.weight(.medium)).lineLimit(1).opacity(0.75) }
                    if !current.intro.isEmpty {
                        Text(current.intro.trimmingCharacters(in: .whitespacesAndNewlines)).font(.callout).lineSpacing(4).lineLimit(3)
                            .opacity(0.85).frame(maxWidth: 1050, alignment: .leading)
                    }
                    tvActions.padding(.top, 18)
                }
                .padding(.horizontal, 80).padding(.bottom, 20)
                .frame(maxWidth: .infinity, minHeight: 800, alignment: .bottomLeading)
                // Up past the screen's top edge; its foot ends black, as the page under it.
                .background { NovelHeroBackdrop(image: heroCover).padding(.top, -300).padding(.horizontal, -100) }
                .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 20) {
                    status
                    if !chapters.isEmpty {
                        NovelChapterTVGrid(chapters: chapters, current: entry.flatMap { $0.started ? $0.chapterIndex : nil }) { index in
                            read(at: index, position: entry?.chapterIndex == index ? entry?.position ?? 0 : 0)
                        }
                    }
                }
                .padding(.horizontal, 52)
            }
            .padding(.bottom, 60)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.3), value: chapters.isEmpty)
    }

    private var tvActions: some View {
        let shelved = entry != nil
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                Button(action: readOn) { Label(readTitle, systemImage: "book.fill").lineLimit(1).padding(.horizontal, 10) }
                    .controlButton(prominent: true)
                    .disabled(chapters.isEmpty)
                    .accessibilityIdentifier("novel.read")
                Button { toggleShelf() } label: {
                    Label(shelved ? L10n.text("On Bookshelf") : L10n.text("Add to Bookshelf"), systemImage: shelved ? "books.vertical.fill" : "plus").lineLimit(1)
                }
                .controlButton()
                if entry?.started == true, !chapters.isEmpty {
                    Button { read(at: readable.first?.index ?? 0, position: 0) } label: { Label(L10n.text("Start Over"), systemImage: "arrow.counterclockwise") }
                        .controlButton()
                }
                RouteLink { NovelSourcePicker(book: current, alternatives: alternatives) { switchTo($0) } } label: {
                    Label(store.name(of: book.sourceKey), systemImage: "arrow.left.arrow.right").lineLimit(1)
                }
                .controlButton()
                .accessibilityHint(L10n.text("Change Source"))
                .accessibilityIdentifier("novel.source")
            }
            if let progressText { Text(progressText).font(.caption).opacity(0.6).lineLimit(1).padding(.leading, 8) }
        }
        .tvFocusSection()
    }
    #endif
}

/// A row on the book page: a symbol, a title, a value, and a line under it.
struct NovelRow: View {
    let symbol: String
    let title: String
    var detail: String = ""
    var note: String? = nil
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 28).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            #if !os(tvOS)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            #endif
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension View {
    /// A wide glass row button: tvOS's focus plate, a glass card elsewhere.
    @ViewBuilder func novelRowButton() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
            .glassOrFill(.regular.interactive(), Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        #endif
    }
}

// MARK: - Contents

/// A book's table of contents: volumes as headings, the chapter last read marked, a chapter opens the reader.
struct NovelTOCView: View {
    let book: NovelBook
    let chapters: [NovelChapter]
    @State private var store = NovelStore.shared
    @State private var reading: NovelReading?
    @Environment(\.openRoute) private var openRoute

    private var last: Int? { store.shelfBook(book).flatMap { $0.started ? $0.chapterIndex : nil } }

    var body: some View {
        NovelChapterList(book: book, chapters: chapters, current: last) { index in open(index) }
            .background { Backdrop() }
            .screenTitle(L10n.text("Contents"))
            #if os(macOS)
            .onChange(of: reading?.id) { _, _ in
                if let reading { openRoute?(Route { AnyView(NovelReaderView(reading: reading)) }); self.reading = nil }
            }
            #else
            .fullScreenCover(item: $reading) { NovelReaderView(reading: $0) }
            #endif
    }

    private func open(_ index: Int) {
        let saved = store.shelfBook(book)
        let position = saved?.chapterIndex == index ? saved?.position ?? 0 : 0
        reading = NovelReading(book: book, chapters: chapters, chapter: index, position: position)
    }
}

// MARK: - Change source

/// The same book from other sources: the ones the search found, or a new search of every source by its title.
struct NovelSourcePicker: View {
    let book: NovelBook
    let alternatives: [NovelBook]
    let pick: (NovelBook) -> Void
    @State private var store = NovelStore.shared
    @State private var found: [NovelBook] = []
    @State private var searching = false
    @State private var searched = 0
    @Environment(\.dismiss) private var dismiss

    private var all: [NovelBook] {
        var seen = Set<String>()
        return ([book] + alternatives + found).filter { seen.insert($0.sourceKey).inserted }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(all) { other in
                    Button {
                        pick(other)
                        dismiss()
                    } label: {
                        NovelRow(symbol: other.sourceKey == book.sourceKey ? "checkmark.circle.fill" : "circle", title: store.name(of: other.sourceKey),
                                 detail: other.author, note: other.lastChapter.isEmpty ? nil : L10n.text("Latest: %@", other.lastChapter))
                    }
                    .novelRowButton()
                }
                HStack(spacing: 12) {
                    if searching {
                        ProgressView().appControlSize(.small)
                        Text(L10n.text("Searched %lld of %lld sources", searched, store.searchable.count)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        Button { Task { await search() } } label: { Label(L10n.text("Search All Sources"), systemImage: "magnifyingglass") }
                            .controlButton()
                            .accessibilityIdentifier("novel.source.search")
                    }
                }
                .padding(.top, 12)
            }
            .padding(Layout.gutter)
            .frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .background { Backdrop() }
        .screenTitle(L10n.text("Change Source"))
        .task { if alternatives.count <= 1 { await search() } }
    }

    private func search() async {
        guard !searching else { return }
        searching = true; searched = 0
        defer { searching = false }
        for await answer in NovelBooks.search(book.name, in: store.searchable) {
            searched += 1
            if case .success(let books) = answer.result {
                found += books.filter { $0.match == book.match || (book.author.isEmpty && NovelBookNameMatch.same($0.name, book.name)) }
            }
        }
    }
}

enum NovelBookNameMatch {
    static func same(_ a: String, _ b: String) -> Bool { NovelChapterTitle.key(a) == NovelChapterTitle.key(b) }
}

#if !os(macOS)
/// Behind the hero on the iPad and Apple TV, as the Mac's: a blur of the cover across it, the cover itself sharp in the top
/// trailing corner fading into the blur, darker toward the text at the leading edge and the foot.
struct NovelHeroBackdrop: View {
    let image: CGImage?
    var body: some View {
        // Black at exactly the hero's size, the pictures over it: a filled picture as the base grew the backdrop past
        // the hero (a background is centred on its view), over the chapters below.
        Color.black
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 60, opaque: true).saturation(1.25).opacity(0.8)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let image {
                    GeometryReader { proxy in
                        // Its own size, so the fades run across the picture and not a wider box around it.
                        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
                        let height = min(proxy.size.height * 0.9, proxy.size.width * 0.5 / aspect)
                        Image(decorative: image, scale: 1).resizable()
                            .frame(width: height * aspect, height: height)
                            .mask {
                                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.4)],
                                               startPoint: .leading, endPoint: .trailing)
                            }
                            .mask {
                                LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                               startPoint: .top, endPoint: .bottom)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.45), location: 0.45),
                                       .init(color: .clear, location: 0.8)], startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 0.85)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            // The foot fades out into the page under it (the iPad's is tinted by the cover), with no edge.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.86), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.4), value: image != nil)
    }
}
#endif
