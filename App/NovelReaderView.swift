import SwiftUI
import TVCore

// The reader follows Readest's page (github.com/readest/readest): pages that fit the screen exactly, justified text
// with indented paragraphs, the chapter's title small in the top margin and how far the chapter goes at the foot,
// named page colours, and one panel at the bottom with progress, contents, type and colour.

/// One line of the scroll layout: a chapter's heading or a run of its text.
struct NovelLine: Identifiable, Hashable {
    let id: String
    let chapter: Int
    /// The line's place in its chapter, for saving how far reading got.
    let offset: Int
    let text: String
    let heading: Bool
    /// The rest of a long paragraph cut into pieces: no indent, no gap above.
    let continued: Bool
}

/// Where reading is in the page layout: a chapter and the first character on screen.
struct NovelPlace: Hashable {
    var chapter: Int
    var location: Int
}

/// What a set of pages was laid out for; a change sets the chapters again.
struct NovelPageKey: Equatable {
    var style: NovelTypeStyle
    var width: Double
    var height: Double
    var columns: Int
}

/// The reader's state: the chapters fetched, where reading is, and the neighbours fetched ahead.
@MainActor @Observable final class NovelReaderModel {
    let book: NovelBook
    let chapters: [NovelChapter]
    /// Chapter texts fetched so far, the ones near the reader kept.
    private(set) var contents: [Int: NovelContent] = [:]
    private(set) var failure: String?
    private(set) var nextFailure: String?
    /// A neighbouring chapter being fetched for a page turn.
    private(set) var fetching: Int?
    /// Why a chapter the reader stands on couldn't be fetched again.
    private(set) var missing: [Int: String] = [:]

    // Page layout.
    private(set) var place: NovelPlace?
    @ObservationIgnored private var paged: [Int: NovelPages] = [:]
    @ObservationIgnored private var pagedKey: NovelPageKey?

    // Scroll layout: the chapters shown one after another; reading on appends the next one.
    private(set) var lines: [NovelLine] = []
    private(set) var loaded: [Int] = []
    private var counts: [Int: Int] = [:]
    private(set) var loadingNext = false
    /// The line at the top of the screen.
    var anchor: String?
    /// Heights measured as lines draw, for turning a screen at a time; not observed.
    @ObservationIgnored var heights: [String: CGFloat] = [:]
    @ObservationIgnored private var saved = Date.distantPast

    init(_ reading: NovelReading) {
        book = reading.book
        chapters = reading.chapters
    }

    private var pagesLayout: Bool { NovelStore.shared.pageTurn == .pages }
    var currentChapter: Int { pagesLayout ? (place?.chapter ?? 0) : scrollChapter }
    private var scrollChapter: Int {
        guard let anchor, let line = lines.first(where: { $0.id == anchor }) else { return loaded.first ?? place?.chapter ?? 0 }
        return line.chapter
    }
    var currentTitle: String { chapters.indices.contains(currentChapter) ? chapters[currentChapter].title : "" }
    var readable: [NovelChapter] { chapters.filter { !$0.isVolume } }
    func previous(_ index: Int) -> Int? { chapters[..<min(index, chapters.count)].last { !$0.isVolume }?.index }
    func next(_ index: Int) -> Int? { index + 1 < chapters.count ? chapters[(index + 1)...].first { !$0.isVolume }?.index : nil }
    /// The current chapter's place among the readable ones, from 0.
    var readableIndex: Int { readable.firstIndex { $0.index == currentChapter } ?? 0 }
    /// "12 / 340", counting chapters only.
    var progressText: String { readable.isEmpty ? "" : "\(readableIndex + 1) / \(readable.count)" }

    // MARK: Fetching

    func load(_ index: Int) async throws -> NovelContent {
        if let content = contents[index] { return content }
        let content = try await NovelBooks.shared.content(book, chapters: chapters, index: index)
        contents[index] = content
        // Keep the chapters around the reader and around the one just loaded; drop the far ones. (Measuring from the
        // reader alone dropped a chapter opened far away, e.g. from the slider, the moment it arrived: the reader then
        // waited for it forever.)
        let anchors = [currentChapter, index]
        func distance(_ chapter: Int) -> Int { anchors.map { abs($0 - chapter) }.min() ?? 0 }
        while contents.count > 8, let far = contents.keys.filter({ distance($0) > 1 }).max(by: { distance($0) < distance($1) }) {
            contents[far] = nil; paged[far] = nil
        }
        return content
    }

    /// Fetches the chapter the reader stands on when its text is gone, so a page never waits on nothing.
    func refetch(_ chapter: Int) async {
        guard contents[chapter] == nil else { return }
        missing[chapter] = nil
        do { _ = try await load(chapter) }
        catch is CancellationError {}
        catch { missing[chapter] = error.novelMessage }
    }

    /// Opens a chapter on its own, at `position` (0–1) of it.
    func open(_ index: Int, position: Double = 0) async {
        guard !chapters.isEmpty else { return }
        var index = min(max(0, index), chapters.count - 1)
        if chapters[index].isVolume, let next = next(index) { index = next }
        failure = nil; nextFailure = nil
        do {
            let content = try await load(index)
            let length = NovelTypeStyle.length(content)
            place = NovelPlace(chapter: index, location: position > 0 ? Int(Double(length) * min(1, position)) : 0)
            let made = Self.lines(content, chapter: index)
            lines = made; loaded = [index]; counts = [index: made.count]
            let target = min(made.count - 1, max(0, Int((Double(made.count) * position).rounded(.down))))
            anchor = position > 0 ? made[target].id : made.first?.id
            save(force: true)
            fetchNeighbours(of: index)
        } catch is CancellationError {
        } catch {
            failure = error.novelMessage
        }
    }

    private func fetchNeighbours(of index: Int) {
        for neighbour in [next(index), previous(index)].compactMap({ $0 }) where contents[neighbour] == nil {
            Task { _ = try? await load(neighbour) }
        }
        Task { await NovelBooks.shared.prefetch(book, chapters: chapters, after: index) }
    }

    // MARK: Pages

    /// A chapter laid out for `key`, set on first use and kept while the key holds.
    func pages(_ chapter: Int, _ key: NovelPageKey) -> NovelPages? {
        if key != pagedKey { paged = [:]; pagedKey = key }
        if let pages = paged[chapter] { return pages }
        guard let content = contents[chapter] else { return nil }
        let pages = NovelPages(chapter: chapter, text: key.style.text(content), column: CGSize(width: key.width, height: key.height), columns: key.columns)
        paged[chapter] = pages
        return pages
    }

    /// The place one screen on or back; nil at the book's ends, or while the neighbouring chapter isn't fetched.
    func step(from place: NovelPlace, forward: Bool, key: NovelPageKey) -> NovelPlace? {
        guard let pages = pages(place.chapter, key) else { return nil }
        let spread = pages.spread(containing: place.location)
        if forward {
            if spread + 1 < pages.spreadCount { return NovelPlace(chapter: place.chapter, location: pages.location(ofSpread: spread + 1)) }
            guard let next = next(place.chapter), contents[next] != nil else { return nil }
            return NovelPlace(chapter: next, location: 0)
        } else {
            if spread > 0 { return NovelPlace(chapter: place.chapter, location: pages.location(ofSpread: spread - 1)) }
            guard let previous = previous(place.chapter), let before = self.pages(previous, key) else { return nil }
            return NovelPlace(chapter: previous, location: before.location(ofSpread: before.spreadCount - 1))
        }
    }

    /// Fetches the chapter a page turn needs; true once it is there.
    func fetchNeighbour(of place: NovelPlace, forward: Bool) async -> Bool {
        guard fetching == nil, let index = forward ? next(place.chapter) : previous(place.chapter) else { return false }
        fetching = index; nextFailure = nil
        defer { fetching = nil }
        do { _ = try await load(index); return true } catch is CancellationError { return false } catch {
            nextFailure = error.novelMessage
            return false
        }
    }

    func move(to place: NovelPlace) {
        let chapterChanged = place.chapter != self.place?.chapter
        self.place = place
        // Saving touches the shelf, which redraws the book page under the reader: at most every 2 s while turning.
        save(force: chapterChanged)
        if chapterChanged { fetchNeighbours(of: place.chapter) }
    }

    /// Moves between the page and scroll layouts, keeping the place.
    func switchLayout(to turn: NovelPageTurn) {
        switch turn {
        case .pages:
            let chapter = scrollChapter
            guard let content = contents[chapter] else { return }
            var fraction = 0.0
            if let anchor, let line = lines.first(where: { $0.id == anchor }) { fraction = Double(line.offset) / Double(max(1, counts[chapter] ?? 1)) }
            place = NovelPlace(chapter: chapter, location: Int(Double(NovelTypeStyle.length(content)) * fraction))
        case .scroll:
            guard let place, let content = contents[place.chapter] else { return }
            let fraction = Double(place.location) / Double(max(1, NovelTypeStyle.length(content)))
            Task { await open(place.chapter, position: fraction) }
        }
    }

    // MARK: Scroll layout

    /// Appends the chapter after the last one shown.
    func loadNext() async {
        guard !loadingNext, let last = loaded.last, let index = next(last) else { return }
        loadingNext = true; nextFailure = nil
        defer { loadingNext = false }
        do {
            let content = try await load(index)
            guard loaded.last == last else { return }
            let made = Self.lines(content, chapter: index)
            lines += made; loaded.append(index); counts[index] = made.count
            // Far behind the reader: drop the oldest chapters so the column stays light.
            if loaded.count > 4, let first = loaded.first {
                lines.removeAll { $0.chapter == first }; loaded.removeFirst(); counts[first] = nil
            }
            fetchNeighbours(of: index)
        } catch is CancellationError {
        } catch {
            nextFailure = error.novelMessage
        }
    }

    var hasNext: Bool { loaded.last.flatMap(next) != nil }

    /// Called as the top line changes: saves the place now and then, and reads on near a chapter's end.
    func moved() {
        guard let anchor, let at = lines.firstIndex(where: { $0.id == anchor }) else { return }
        if lines.count - at < 40, hasNext { Task { await loadNext() } }
        save()
    }

    func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(saved) > 2 else { return }
        if pagesLayout {
            guard let place, chapters.indices.contains(place.chapter), let content = contents[place.chapter] else { return }
            saved = Date()
            let length = max(1, NovelTypeStyle.length(content))
            NovelStore.shared.record(book, chapter: chapters[place.chapter], count: chapters.count, position: Double(place.location) / Double(length))
        } else {
            guard let anchor, let line = lines.first(where: { $0.id == anchor }), chapters.indices.contains(line.chapter) else { return }
            saved = Date()
            let count = max(1, counts[line.chapter] ?? 1)
            NovelStore.shared.record(book, chapter: chapters[line.chapter], count: chapters.count, position: Double(line.offset) / Double(count))
        }
    }

    /// The line one screen further on (`forward`) or back from the top line, from the heights measured so far.
    func turn(forward: Bool, viewport: CGFloat, lineHeight: CGFloat) -> String? {
        guard let anchor, let at = lines.firstIndex(where: { $0.id == anchor }) else { return lines.first?.id }
        let room = max(lineHeight * 2, viewport - lineHeight * 1.5)
        if forward {
            var used: CGFloat = 0, index = at
            while index < lines.count {
                let height = heights[lines[index].id] ?? lineHeight * 2
                if used + height > room { break }
                used += height; index += 1
            }
            // The line cut by the screen's foot starts the next screen; a line taller than a screen is passed whole.
            return lines[min(lines.count - 1, max(at + 1, index))].id
        } else {
            var used: CGFloat = 0, index = at
            while index > 0 {
                let height = heights[lines[index - 1].id] ?? lineHeight * 2
                if used + height > room { break }
                used += height; index -= 1
            }
            return lines[max(0, min(at - 1, index))].id
        }
    }

    /// A chapter as lines: its heading, then its paragraphs, long ones cut at sentence ends so a screen turn never skips
    /// text inside one.
    static func lines(_ content: NovelContent, chapter: Int) -> [NovelLine] {
        var lines = [NovelLine(id: "\(chapter)-h", chapter: chapter, offset: 0, text: content.title, heading: true, continued: false)]
        for paragraph in NovelTypeStyle.paragraphs(content) {
            for (piece, text) in pieces(paragraph).enumerated() {
                lines.append(NovelLine(id: "\(chapter)-\(lines.count)", chapter: chapter, offset: lines.count, text: text, heading: false, continued: piece > 0))
            }
        }
        return lines
    }

    static func pieces(_ paragraph: String, limit: Int = 160) -> [String] {
        guard paragraph.count > limit * 2 else { return [paragraph] }
        var pieces: [String] = [], current = ""
        for character in paragraph {
            current.append(character)
            if current.count >= limit, "。！？!?…”」.;；".contains(character) { pieces.append(current); current = "" }
        }
        if !current.isEmpty {
            if current.count < limit / 3, !pieces.isEmpty { pieces[pieces.count - 1] += current } else { pieces.append(current) }
        }
        return pieces
    }
}

/// The page's measurements: the text columns inside the margins and the bands above and below them.
private struct NovelPageFrame {
    var size: CGSize
    var top: CGFloat
    var bottom: CGFloat
    var side: CGFloat
    var columns: Int
    var columnWidth: CGFloat
    var gap: CGFloat
    var height: CGFloat
    var band: CGFloat

    init(size: CGSize, insets: EdgeInsets, margin: CGFloat) {
        self.size = size
        #if os(tvOS)
        band = 90
        #elseif os(macOS)
        band = 52
        #else
        band = 34
        #endif
        top = insets.top + band
        bottom = insets.bottom + band
        side = margin + max(insets.leading, insets.trailing)
        let width = max(100, size.width - side * 2)
        // Two columns where a line would otherwise run too long to read comfortably.
        columns = width > 1000 ? 2 : 1
        gap = columns > 1 ? max(56, margin * 1.5) : 0
        columnWidth = floor((width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        height = max(100, floor(size.height - top - bottom))
    }
}

/// The reader. In the page layout a swipe, or a tap at either side, turns the page; the middle shows the controls.
/// The scroll layout is one column of chapters read on downwards.
struct NovelReaderView: View {
    @State private var model: NovelReaderModel
    @State private var store = NovelStore.shared
    @State private var fonts = NovelFonts.shared
    @State private var chrome = true
    @State private var panel: Panel?
    @State private var showContents = false
    @State private var viewport: CGFloat = 600
    // Page turning.
    @State private var drag: CGFloat = 0
    @State private var turning = false
    @State private var pageKey: NovelPageKey?
    @State private var pageWidth: CGFloat = 400
    /// The chapter slider's value while it is dragged.
    @State private var scrub: Double?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    #if os(macOS)
    @Environment(Store.self) private var appStore
    #endif
    #if os(tvOS)
    @FocusState private var textFocused: Bool
    /// The control the remote is on while the controls show: Contents when they come up, or the page's text had focus
    /// and nothing took it over.
    @FocusState private var controlFocus: String?
    #endif
    private let start: NovelReading

    enum Panel { case text, theme }

    init(reading: NovelReading) {
        start = reading
        _model = State(initialValue: NovelReaderModel(reading))
    }

    private var dark: Bool { store.appearance.isDark(scheme == .dark) }
    private var colors: (background: Color, text: Color) { store.theme.colors(dark: dark) }
    private var style: NovelTypeStyle {
        NovelTypeStyle(fontSize: store.fontSize, lineHeight: store.lineHeight, font: store.font, text: colors.text, fontsReady: fonts.generation)
    }
    private var lineHeight: CGFloat { store.fontSize * store.lineHeight }
    #if os(tvOS)
    private let chromeFont: CGFloat = 22
    #else
    private let chromeFont: CGFloat = 12
    #endif

    var body: some View {
        ZStack {
            colors.background.ignoresSafeArea()
            if model.place != nil || !model.lines.isEmpty {
                if store.pageTurn == .pages { pager } else { column }
            } else if let failure = model.failure {
                ErrorState(title: L10n.text("Unable to Load"), message: failure, details: "",
                           retry: { Task { await model.open(model.currentChapter) } }, goBack: { close() }, backTitle: L10n.text("Close"))
                    .padding()
            } else {
                ProgressView().appControlSize(.large)
            }
            if chrome { controls.transition(.opacity) }
        }
        .foregroundStyle(colors.text)
        .environment(\.colorScheme, dark ? .dark : .light)
        #if os(iOS)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        #if os(macOS)
        .toolbar(.hidden, for: .windowToolbar)
        .navigationBarBackButtonHidden()
        .onAppear { appStore.hidesSidebar = true }
        .onDisappear { appStore.hidesSidebar = false }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.downArrow, .space, .pageDown, .rightArrow]) { _ in turn(forward: true); return .handled }
        .onKeyPress(keys: [.upArrow, .pageUp, .leftArrow]) { _ in turn(forward: false); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        #endif
        #if os(tvOS)
        .onExitCommand {
            if panel != nil { withAnimation(.smooth) { panel = nil } } else if chrome { close() } else { withAnimation(.smooth) { chrome = true } }
        }
        .onChange(of: chrome, initial: true) { _, shown in
            guard shown else { return }
            Task { try? await Task.sleep(for: .milliseconds(80)); controlFocus = "contents" }
        }
        #endif
        .sheet(isPresented: $showContents) {
            NovelReaderContents(model: model, colors: colors, dark: dark) { index in
                showContents = false
                Task { await model.open(index) }
            }
        }
        .onChange(of: store.pageTurn) { _, turn in model.switchLayout(to: turn) }
        .onChange(of: store.font) { _, font in fonts.prepare(font) }
        .task {
            fonts.prepare(store.font)
            await model.open(start.chapter, position: start.position)
            try? await Task.sleep(for: .seconds(1.5))
            #if DEBUG
            // `-qaNovelTurns <n>` turns n pages on; `-qaNovelPanel text|theme` opens that panel.
            for _ in 0..<UserDefaults.standard.integer(forKey: "qaNovelTurns") {
                turn(forward: true)
                try? await Task.sleep(for: .seconds(0.6))
            }
            // `-qaNovelSwipes <n>`: a finger dragging a third of the way left at 60 Hz, then letting go.
            for _ in 0..<UserDefaults.standard.integer(forKey: "qaNovelSwipes") {
                for step in 1...12 {
                    drag = -CGFloat(step) * pageWidth / 36
                    try? await Task.sleep(for: .milliseconds(16))
                }
                turn(forward: true)
                try? await Task.sleep(for: .seconds(0.8))
            }
            for jump in (UserDefaults.standard.string(forKey: "qaNovelJumps") ?? "").split(separator: ",").compactMap({ Double($0) }) {
                withAnimation(.smooth) { chrome = true }
                scrub = jump
                await scrubbed(to: jump)
                try? await Task.sleep(for: .seconds(4))
            }
            switch UserDefaults.standard.string(forKey: "qaNovelPanel") {
            case "text": panel = .text
            case "theme": panel = .theme
            case "contents": showContents = true
            default: break
            }
            if UserDefaults.standard.bool(forKey: "qaNovelChrome") || panel != nil { return }
            #endif
            withAnimation(.smooth) { chrome = false }
        }
        .onDisappear { model.save(force: true) }
    }

    // MARK: Pages

    private var pager: some View {
        // The outer reader keeps to the safe area only to learn its insets; the page itself runs edge to edge, with its
        // text and bands inside them (clear of the Dynamic Island and the home indicator).
        GeometryReader { safe in
            pagerBody(insets: safe.safeAreaInsets)
        }
    }

    private func pagerBody(insets: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let frame = NovelPageFrame(size: geometry.size, insets: insets, margin: store.margin)
            let key = NovelPageKey(style: style, width: frame.columnWidth, height: frame.height, columns: frame.columns)
            ZStack(alignment: .topLeading) {
                if let place = model.place {
                    // Identified by place, so when a turn ends the page already drawn underneath simply becomes the
                    // current one: nothing is drawn again, nothing flickers.
                    ForEach(layers(place, key: key, width: geometry.size.width), id: \.place) { layer in
                        page(layer.place, frame: frame, key: key)
                            .overlay(alignment: .trailing) { edgeShade(layer.shade) }
                            .offset(x: layer.offset)
                            .zIndex(layer.z)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            #if os(iOS)
            .gesture(swipe(width: geometry.size.width))
            #endif
            #if !os(tvOS)
            .onTapGesture { location in tap(location, size: geometry.size) }
            #endif
            .onChange(of: key, initial: true) { _, key in pageKey = key }
            .onChange(of: geometry.size.width, initial: true) { _, width in pageWidth = width }
        }
        .ignoresSafeArea()
        #if os(tvOS)
        .focusable(!chrome)
        .focused($textFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .right, .down: turn(forward: true)
            case .left, .up: turn(forward: false)
            default: break
            }
        }
        .onPlayPauseCommand { withAnimation(.smooth) { chrome.toggle() } }
        .onTapGesture { withAnimation(.smooth) { chrome.toggle() } }
        .onChange(of: chrome) { _, shown in if !shown { textFocused = true } }
        #endif
    }

    private struct PageLayer {
        let place: NovelPlace
        let offset: CGFloat
        let z: Double
        /// How strong the lifted page's shadow is, 0 when it lies flat.
        let shade: Double
    }

    /// The pages on screen during a turn. Turning on, the page slides off to the left over the next one, which waits
    /// still beneath; turning back, the previous page slides in from the left over the current one.
    private func layers(_ place: NovelPlace, key: NovelPageKey, width: CGFloat) -> [PageLayer] {
        if drag < 0, let next = model.step(from: place, forward: true, key: key) {
            // The shadow fades as the page leaves, so none is left at the screen's edge when the turn ends.
            let shade = max(0, min(1, 1 + drag / max(1, width)))
            return [PageLayer(place: next, offset: 0, z: 0, shade: 0), PageLayer(place: place, offset: drag, z: 1, shade: shade)]
        }
        if drag > 0, let previous = model.step(from: place, forward: false, key: key) {
            return [PageLayer(place: place, offset: 0, z: 0, shade: 0), PageLayer(place: previous, offset: drag - width, z: 1, shade: 1)]
        }
        return [PageLayer(place: place, offset: drag, z: 1, shade: 0)]
    }

    /// The shadow a lifted page casts on the one beneath: a gradient strip past its edge, cheaper than a view shadow.
    /// Always there, its opacity animated with the page: removing it mid-turn left it fading where it had been.
    private func edgeShade(_ shade: Double) -> some View {
        LinearGradient(colors: [.black.opacity(dark ? 0.5 : 0.16), .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
            .frame(width: 22)
            .offset(x: 22)
            .opacity(shade)
            .allowsHitTesting(false)
    }

    /// One screen: the columns, the chapter's title above them and how far the chapter goes below.
    @ViewBuilder private func page(_ place: NovelPlace, frame: NovelPageFrame, key: NovelPageKey) -> some View {
        ZStack(alignment: .topLeading) {
            colors.background
            if let pages = model.pages(place.chapter, key) {
                let spread = pages.spread(containing: place.location)
                ForEach(0..<frame.columns, id: \.self) { column in
                    let index = spread * frame.columns + column
                    if pages.hasColumn(index) {
                        NovelColumn(pages: pages, index: index)
                            .frame(width: frame.columnWidth, height: frame.height)
                            .offset(x: frame.side + CGFloat(column) * (frame.columnWidth + frame.gap), y: frame.top)
                    }
                }
                // The running head stays off a chapter's first page, where its title is printed large.
                if spread > 0 {
                    Text(model.chapters.indices.contains(place.chapter) ? model.chapters[place.chapter].title : "")
                        .font(.system(size: chromeFont, weight: .light))
                        .lineLimit(1)
                        .opacity(chrome ? 0 : 0.6)
                        .frame(width: frame.size.width - frame.side * 2)
                        .position(x: frame.size.width / 2, y: frame.top - frame.band / 2)
                }
                HStack(spacing: 12) {
                    Text(remaining(pages.spreadCount - spread - 1))
                    Spacer(minLength: 8)
                    if model.fetching != nil { ProgressView().controlSize(.mini) }
                    Text("\(spread + 1) / \(pages.spreadCount)")
                }
                .font(.system(size: chromeFont, weight: .light).monospacedDigit())
                .lineLimit(1)
                .opacity(chrome ? 0 : 0.6)
                .frame(width: frame.size.width - frame.side * 2)
                .position(x: frame.size.width / 2, y: frame.size.height - frame.bottom + frame.band / 2)
            } else if let failure = model.missing[place.chapter] {
                VStack(spacing: 14) {
                    Text(failure).font(.footnote).multilineTextAlignment(.center).opacity(0.7)
                    Button(L10n.text("Retry")) { Task { await model.refetch(place.chapter) } }
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, frame.side)
                .frame(width: frame.size.width)
                .position(x: frame.size.width / 2, y: frame.size.height / 2)
            } else {
                ProgressView().position(x: frame.size.width / 2, y: frame.size.height / 2)
                    .task(id: place.chapter) { await model.refetch(place.chapter) }
            }
        }
        .frame(width: frame.size.width, height: frame.size.height, alignment: .topLeading)
    }

    private func remaining(_ pages: Int) -> String {
        pages <= 0 ? L10n.text("Last page in chapter") : pages == 1 ? L10n.text("1 page left in chapter") : L10n.text("%d pages left in chapter", pages)
    }

    #if os(iOS)
    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard !turning, let place = model.place, let key = pageKey else { return }
                let dx = value.translation.width
                // Past the book's ends, or before the next chapter arrives, the page only gives a little.
                let open = model.step(from: place, forward: dx < 0, key: key) != nil
                drag = open ? dx : dx * 0.25
            }
            .onEnded { value in
                guard !turning else { return }
                let travel = value.predictedEndTranslation.width
                if travel < -width * 0.3 { turn(forward: true) }
                else if travel > width * 0.3 { turn(forward: false) }
                else { withAnimation(.smooth(duration: 0.25)) { drag = 0 } }
            }
    }
    #endif

    // MARK: Turning

    private func tap(_ location: CGPoint, size: CGSize) {
        if panel != nil { withAnimation(.smooth) { panel = nil }; return }
        if chrome { withAnimation(.smooth) { chrome = false }; return }
        if store.pageTurn == .pages {
            if location.x < size.width * 0.3 { turn(forward: false) }
            else if location.x > size.width * 0.7 { turn(forward: true) }
            else { withAnimation(.smooth(duration: 0.2)) { chrome = true } }
        } else {
            if location.y < size.height * 0.3 { turn(forward: false) }
            else if location.y > size.height * 0.7 { turn(forward: true) }
            else { withAnimation(.smooth(duration: 0.2)) { chrome = true } }
        }
    }

    private func turn(forward: Bool) {
        if store.pageTurn == .scroll {
            guard let target = model.turn(forward: forward, viewport: viewport, lineHeight: lineHeight) else { return }
            withAnimation(.easeInOut(duration: 0.28)) { model.anchor = target }
            return
        }
        guard !turning, let place = model.place, let key = pageKey else { return }
        guard let target = model.step(from: place, forward: forward, key: key) else {
            withAnimation(.smooth(duration: 0.25)) { drag = 0 }
            Task { if await model.fetchNeighbour(of: place, forward: forward), model.place == place { turn(forward: forward) } }
            return
        }
        turning = true
        withAnimation(.smooth(duration: 0.3)) {
            drag = forward ? -pageWidth : pageWidth
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.move(to: target)
                drag = 0
            }
            turning = false
        }
    }

    private func step(_ forward: Bool) {
        let current = model.currentChapter
        guard let index = forward ? model.next(current) : model.previous(current) else { return }
        Task { await model.open(index) }
    }

    private func close() {
        model.save(force: true)
        dismiss()
    }

    // MARK: Scroll layout

    #if os(tvOS)
    private let maxColumn: CGFloat = 1300
    private let topMargin: CGFloat = 60
    #elseif os(macOS)
    private let maxColumn: CGFloat = 760
    private let topMargin: CGFloat = 44
    #else
    private let maxColumn: CGFloat = 720
    private let topMargin: CGFloat = 12
    #endif

    private var column: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.lines) { line in
                        lineView(line)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.heights[line.id] = $0 }
                    }
                    footer
                }
                .scrollTargetLayout()
                .frame(maxWidth: maxColumn)
                .padding(.horizontal, store.margin)
                .frame(maxWidth: .infinity)
                .padding(.top, topMargin)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollPosition(id: $model.anchor, anchor: .top)
            .onChange(of: model.anchor) { _, _ in model.moved() }
            .onAppear { viewport = geometry.size.height }
            .onChange(of: geometry.size.height) { _, height in viewport = height }
            #if os(iOS) || os(macOS)
            .simultaneousGesture(SpatialTapGesture().onEnded { tap($0.location, size: geometry.size) })
            #endif
            #if os(tvOS)
            .focusable(!chrome && panel == nil)
            .focused($textFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .down, .right: turn(forward: true)
                case .up, .left: turn(forward: false)
                default: break
                }
            }
            .onPlayPauseCommand { withAnimation(.smooth) { chrome.toggle() } }
            .onTapGesture { withAnimation(.smooth) { chrome.toggle() } }
            .onChange(of: chrome) { _, shown in if !shown { textFocused = true } }
            #endif
        }
    }

    @ViewBuilder private func lineView(_ line: NovelLine) -> some View {
        if line.heading {
            Text(line.text)
                .font(store.font.font(size: store.fontSize * 1.45, bold: true))
                .lineSpacing(store.fontSize * 0.3)
                .padding(.top, line.offset == 0 && line.chapter == model.loaded.first ? store.fontSize * 1.2 : store.fontSize * 3)
                .padding(.bottom, store.fontSize * 1.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(line.id)
        } else {
            Text((line.continued ? "" : "\u{3000}\u{3000}") + line.text)
                .font(store.font.font(size: store.fontSize))
                .lineSpacing(max(0, store.fontSize * (store.lineHeight - 1.3)))
                .padding(.top, line.continued ? max(0, store.fontSize * (store.lineHeight - 1.3)) : store.fontSize * 0.55)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .id(line.id)
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 14) {
            if model.loadingNext { ProgressView() }
            else if let failure = model.nextFailure {
                Text(failure).font(.footnote).multilineTextAlignment(.center).opacity(0.7)
                Button(L10n.text("Try Again")) { Task { await model.loadNext() } }.controlButton()
            } else if !model.hasNext {
                Text(L10n.text("The End")).font(store.font.font(size: store.fontSize, bold: true)).opacity(0.6)
                Text(L10n.text("You've reached the latest chapter.")).font(.footnote).opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
        // A short chapter leaves the foot on screen with no scrolling to read on: load the next one as it shows.
        .onAppear { if model.hasNext, model.nextFailure == nil { Task { await model.loadNext() } } }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(NovelRoundButtonStyle(size: 40))
                    .accessibilityLabel(L10n.text("Close"))
                    .accessibilityIdentifier("novel.reader.close")
                VStack(spacing: 2) {
                    Text(model.book.name).font(.footnote.weight(.semibold))
                    Text(model.currentTitle).font(.caption2).opacity(0.6)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                Button { showContents = true } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(NovelRoundButtonStyle(size: 40))
                    .accessibilityLabel(L10n.text("Contents"))
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 22)
            // The page's own colour fades in behind the bar, so the text never runs under the buttons.
            .background {
                LinearGradient(stops: [.init(color: colors.background, location: 0), .init(color: colors.background, location: 0.8),
                                       .init(color: colors.background.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea(edges: .top)
            }
            Spacer(minLength: 0)
            if let failure = model.nextFailure, store.pageTurn == .pages {
                Text(failure).font(.footnote).padding(.horizontal, 16).padding(.vertical, 10)
                    .glassSurface(.regular, in: Capsule()).padding(.bottom, 10)
            }
            bottomPanel
                .background(alignment: .bottom) {
                    LinearGradient(colors: [colors.background.opacity(0), colors.background.opacity(0.9)], startPoint: .top, endPoint: .bottom)
                        .padding(.top, -60)
                        .ignoresSafeArea(edges: .bottom)
                }
        }
        #if os(tvOS)
        .focusSection()
        .defaultFocus($controlFocus, "contents")
        #endif
    }

    private var bottomPanel: some View {
        VStack(spacing: 16) {
            switch panel {
            case .text: textSettings
            case .theme: themeSettings
            case nil: EmptyView()
            }
            if panel != nil { Divider().opacity(0.5) }
            chapterRow
            HStack(spacing: tabSpacing) {
                tab("contents", L10n.text("Contents"), "list.bullet", selected: false) { showContents = true }
                tab("text", L10n.text("Text"), "Aa", selected: panel == .text) { toggle(.text) }
                tab("theme", L10n.text("Theme"), "paintpalette", selected: panel == .theme) { toggle(.theme) }
                tab("layout", store.pageTurn == .pages ? L10n.text("Paged") : L10n.text("Scroll"),
                    store.pageTurn == .pages ? "book.pages" : "scroll", selected: false) {
                    store.pageTurn = store.pageTurn == .pages ? .scroll : .pages
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: panelWidth)
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 12).padding(.bottom, 6)
        .animation(.smooth(duration: 0.25), value: panel)
    }

    #if os(tvOS)
    private let panelWidth: CGFloat = 1100
    private let tabSpacing: CGFloat = 18
    #else
    private let panelWidth: CGFloat = 560
    private let tabSpacing: CGFloat = 6
    #endif

    private func toggle(_ next: Panel) { withAnimation(.smooth(duration: 0.25)) { panel = panel == next ? nil : next } }

    /// The chapter buttons with the slider between them on one centre line, and where reading is beneath.
    private var chapterRow: some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 14) {
                Button { step(false) } label: { Image(systemName: "chevron.backward.2") }
                    .buttonStyle(NovelRoundButtonStyle(size: 38))
                    .disabled(model.previous(model.currentChapter) == nil)
                    .accessibilityLabel(L10n.text("Previous Chapter"))
                #if os(tvOS)
                chapterLabel.frame(maxWidth: .infinity)
                #else
                if model.readable.count > 1 {
                    Slider(value: Binding(get: { scrub ?? Double(model.readableIndex) }, set: { scrub = $0.rounded() }),
                           in: 0...Double(model.readable.count - 1)) { editing in
                        guard !editing, let value = scrub else { return }
                        Task { await scrubbed(to: value) }
                    }
                    .tint(colors.text.opacity(0.75))
                } else {
                    Spacer(minLength: 0)
                }
                #endif
                Button { step(true) } label: { Image(systemName: "chevron.forward.2") }
                    .buttonStyle(NovelRoundButtonStyle(size: 38))
                    .disabled(model.next(model.currentChapter) == nil)
                    .accessibilityLabel(L10n.text("Next Chapter"))
            }
            #if !os(tvOS)
            chapterLabel
            #endif
        }
    }

    /// Opens the chapter the slider was let go at. The thumb stays there until the chapter is open; clearing it first
    /// sent it back to the old chapter for a moment.
    private func scrubbed(to value: Double) async {
        let readable = model.readable
        guard !readable.isEmpty else { return }
        await model.open(readable[min(readable.count - 1, max(0, Int(value)))].index)
        if scrub == value { scrub = nil }
    }

    /// The chapter the slider points at while dragged, otherwise "12 / 340".
    private var chapterLabel: some View {
        Group {
            if let scrub, model.readable.indices.contains(Int(scrub)) {
                Text(model.readable[Int(scrub)].title)
            } else {
                Text(model.progressText)
            }
        }
        .font(.caption.monospacedDigit()).opacity(0.7).lineLimit(1)
    }

    private func tab(_ id: String, _ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        // Apple TV: a glass pill with the icon before the word, as the TV app's buttons; focus is the only highlight.
        Button(action: action) {
            HStack(spacing: 12) {
                if symbol == "Aa" { Text("Aa").font(.system(size: 28, weight: .medium, design: .serif)) }
                else { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity)
        }
        .glassPill(lift: 1.04, selected: selected)
        .focused($controlFocus, equals: id)
        #else
        Button(action: action) {
            VStack(spacing: 4) {
                // "Aa" as text: the textformat symbols turn into 大小 in Chinese.
                Group {
                    if symbol == "Aa" { Text("Aa").font(.system(size: 18, weight: .medium, design: .serif)) }
                    else { Image(systemName: symbol).font(.system(size: 18, weight: .regular)) }
                }
                .frame(height: 22)
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(selected ? AnyShapeStyle(colors.text.opacity(0.12)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #endif
    }

    private var textSettings: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text("A").font(.system(size: smallA)).frame(width: aWidth, alignment: .leading)
                NovelAdjuster(value: $store.fontSize, range: NovelStore.fontRange, step: 1, label: L10n.text("Font Size")) { "\(Int($0))" }
                Text("A").font(.system(size: smallA * 1.7)).frame(width: largeAWidth)
            }
            HStack(spacing: 12) {
                Text(L10n.text("Line Spacing")).font(.caption).opacity(0.75).lineLimit(1).frame(width: labelWidth, alignment: .leading)
                NovelAdjuster(value: $store.lineHeight, range: NovelStore.lineHeightRange, step: 0.05, label: L10n.text("Line Spacing")) { String(format: "%.2f", $0) }
                #if os(tvOS)
                Color.clear.frame(width: largeAWidth, height: 1)
                #endif
            }
            HStack(spacing: 12) {
                Text(L10n.text("Margins")).font(.caption).opacity(0.75).lineLimit(1).frame(width: labelWidth, alignment: .leading)
                NovelAdjuster(value: $store.margin, range: NovelStore.marginRange, step: 2, label: L10n.text("Margins")) { "\(Int($0))" }
                #if os(tvOS)
                Color.clear.frame(width: largeAWidth, height: 1)
                #endif
            }
            HStack(spacing: 8) {
                ForEach(NovelFontChoice.allCases) { choice in
                    Button { store.font = choice } label: {
                        #if os(tvOS)
                        // Apple TV: the tabs' glass pills, the chosen one lighter.
                        HStack(spacing: 10) {
                            Text(choice.title).font(choice.font(size: 28))
                            if fonts.downloading.contains(choice) { ProgressView() }
                        }
                        .frame(maxWidth: .infinity)
                        #else
                        HStack(spacing: 6) {
                            Text(choice.title).font(choice.font(size: 16))
                            if fonts.downloading.contains(choice) { ProgressView().controlSize(.mini) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(store.font == choice ? AnyShapeStyle(colors.text.opacity(0.14)) : AnyShapeStyle(colors.text.opacity(0.05)),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(colors.text.opacity(store.font == choice ? 0.6 : 0), lineWidth: 1.5)
                        }
                        #endif
                    }
                    #if os(tvOS)
                    .glassPill(lift: 1.04, selected: store.font == choice)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityAddTraits(store.font == choice ? .isSelected : [])
                }
            }
        }
    }

    private var themeSettings: some View {
        VStack(spacing: 14) {
            Picker(L10n.text("Appearance"), selection: $store.appearance) {
                ForEach(NovelAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: themeColumns), spacing: 10) {
                ForEach(NovelTheme.allCases) { theme in
                    let swatch = theme.colors(dark: dark)
                    let selected = store.theme == theme
                    Button { store.theme = theme } label: {
                        VStack(spacing: 1) {
                            Text("Aa").font(.system(size: 18, weight: .semibold, design: .serif))
                            Text(theme.title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(swatch.text)
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .background(swatch.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? colors.text : colors.text.opacity(0.15), lineWidth: selected ? 2 : 1)
                        }
                    }
                    #if os(tvOS)
                    .buttonStyle(.card)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .accessibilityLabel(theme.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    #if os(tvOS)
    private let themeColumns = 6
    private let labelWidth: CGFloat = 240
    /// The small A sits in the labels' column on Apple TV, so the three adjusters line up.
    private let aWidth: CGFloat? = 240
    private let largeAWidth: CGFloat? = 60
    private let smallA: CGFloat = 22
    #else
    private let themeColumns = 4
    private let labelWidth: CGFloat = 84
    private let aWidth: CGFloat? = nil
    private let largeAWidth: CGFloat? = nil
    private let smallA: CGFloat = 13
    #endif
}

/// A slider; on Apple TV, which has none, a minus and a plus button around the value.
private struct NovelAdjuster: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let format: (Double) -> String
    var body: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus") }
            Text(format(value)).font(.body.monospacedDigit()).frame(minWidth: 80)
            Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus") }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
        #else
        // No `step:` — it draws a tick for every value; the value is rounded to the step instead.
        Slider(value: Binding(get: { value }, set: { value = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step)) }), in: range) { Text(label) }
            .labelsHidden()
            .tint(Color.primary.opacity(0.7))
        #endif
    }
}

/// A round glass button for the reader's controls, in the page's text colour.
private struct NovelRoundButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration, size: size) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        var body: some View {
            #if os(tvOS)
            // Apple TV: bigger, and white with a dark symbol under focus, as the system's round buttons.
            configuration.label
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(focused ? AnyShapeStyle(Color.black) : AnyShapeStyle(.primary))
                .frame(width: 72, height: 72)
                .glassSurface(focused ? .regular.tint(.white).interactive() : .regular, in: Circle())
                .scaleEffect(configuration.isPressed ? 1.05 : focused ? 1.15 : 1)
                .opacity(enabled ? 1 : 0.35)
                .animation(.easeOut(duration: 0.15), value: focused)
            #else
            configuration.label
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .glassSurface(.regular.interactive(), in: Circle())
                .contentShape(Circle())
                .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            #endif
        }
    }
}

/// The table of contents inside the reader, the current chapter in view.
private struct NovelReaderContents: View {
    let model: NovelReaderModel
    let colors: (background: Color, text: Color)
    let dark: Bool
    let open: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            NovelChapterList(book: model.book, chapters: model.chapters, current: model.currentChapter,
                             colors: NovelListColors(background: colors.background, text: colors.text, accent: colors.text)) { open($0) }
                .background(colors.background.ignoresSafeArea())
                .navigationTitle(L10n.text("Contents"))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                #if !os(tvOS)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Done")) { dismiss() } } }
                #endif
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        #if !os(tvOS)
        .presentationBackground(colors.background)
        #endif
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}
