import SwiftUI
import TVCore

/// The reading state: loaded chapters (vertical mode reads on from one into the next), where the viewer is,
/// prefetching ahead, and the saved progress.
@MainActor @Observable final class MangaReaderModel {
    struct Chapter: Identifiable {
        let index: Int
        let pages: [String]
        var id: Int { index }
    }
    struct Position: Hashable { var chapter: Int; var page: Int }

    let comic: MangaComic
    let chapters: [MangaChapter]
    private(set) var loaded: [Chapter] = []
    var position: Position
    /// Where to scroll or page to; the views clear it once there.
    var target: Position?
    private(set) var failure: String?
    private(set) var loadingNext = false
    var mode: MangaReaderMode { didSet { MangaStore.shared.setMode(mode, for: comic) } }
    /// Page shapes (width / height) once known, so the column doesn't jump as pages load.
    var aspects: [String: CGFloat] = [:]
    private var saved = Date.distantPast

    init(_ reading: MangaReading) {
        comic = reading.comic
        chapters = reading.chapters
        position = Position(chapter: reading.chapter, page: reading.page)
        mode = MangaStore.shared.mode(for: reading.comic)
    }

    var single: Bool { chapters.isEmpty }
    func pages(_ chapter: Int) -> [String] { loaded.first { $0.index == chapter }?.pages ?? [] }
    var currentPages: [String] { pages(position.chapter) }
    func title(_ chapter: Int) -> String { chapters.indices.contains(chapter) ? chapters[chapter].title : "" }
    var hasNext: Bool { position.chapter + 1 < chapters.count }
    var hasPrevious: Bool { position.chapter > 0 }

    /// Opens `chapter` alone, at `page` (negative counts from the end).
    func open(_ chapter: Int, page: Int = 0) async {
        failure = nil
        do {
            let pages = try await fetch(chapter)
            loaded = [Chapter(index: chapter, pages: pages)]
            let start = page < 0 ? max(0, pages.count + page) : min(page, max(0, pages.count - 1))
            position = Position(chapter: chapter, page: start)
            target = position
            save(force: true)
            prefetch()
        } catch { failure = error.mangaMessage }
    }

    /// Appends the next chapter, for reading on without a break.
    func loadNext() async {
        guard let last = loaded.last, last.index + 1 < chapters.count, !loadingNext else { return }
        loadingNext = true
        defer { loadingNext = false }
        if let pages = try? await fetch(last.index + 1) {
            loaded.append(Chapter(index: last.index + 1, pages: pages))
            // Long reads keep a few chapters, not every image of the comic.
            if loaded.count > 3, loaded.first!.index < position.chapter { loaded.removeFirst() }
        }
    }

    private func fetch(_ chapter: Int) async throws -> [String] {
        try await MangaRuntime.shared.pages(comic.sourceKey, comic: comic.id, chapter: chapters.indices.contains(chapter) ? chapters[chapter].id : nil)
    }

    func seen(_ position: Position) {
        guard position != self.position else { return }
        self.position = position
        save(force: false)
        prefetch()
    }

    /// Downloads the next pages before the viewer gets there.
    func prefetch() {
        let pages = currentPages, chapter = position.chapter
        let ahead = pages.dropFirst(position.page + 1).prefix(mode.paged ? 4 : 6)
        let source = comic.sourceKey, comicID = comic.id, chapterID = chapters.indices.contains(chapter) ? chapters[chapter].id : nil
        for url in ahead {
            Task(priority: .utility) { _ = try? await MangaImages.shared.data(source: source, url: url, kind: .page, comic: comicID, chapter: chapterID) }
        }
        if position.page >= pages.count - 3, !mode.paged { Task { await loadNext() } }
    }

    func save(force: Bool) {
        guard force || Date().timeIntervalSince(saved) > 1.5 else { return }
        saved = Date()
        MangaStore.shared.record(MangaLibrary.Progress(comic: comic, chapterID: chapters.indices.contains(position.chapter) ? chapters[position.chapter].id : nil,
                                                       chapterTitle: title(position.chapter), chapterIndex: position.chapter,
                                                       chapterCount: chapters.count, page: position.page, pageCount: currentPages.count))
    }

    func chapterID(_ chapter: Int) -> String? { chapters.indices.contains(chapter) ? chapters[chapter].id : nil }
}

/// Reads a comic full screen: vertical scroll (webtoons) or one page at a time in either direction.
struct MangaReaderView: View {
    @State private var model: MangaReaderModel
    @State private var chrome = true
    @State private var showsChapters = false
    @Environment(\.dismiss) private var dismiss
    private let start: MangaReading

    init(reading: MangaReading) {
        start = reading
        _model = State(initialValue: MangaReaderModel(reading))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !model.loaded.isEmpty {
                pages
            } else if let failure = model.failure {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(failure).multilineTextAlignment(.center).frame(maxWidth: 520)
                    HStack {
                        Button(L10n.text("Try Again")) { Task { await model.open(model.position.chapter, page: model.position.page) } }
                        Button(L10n.text("Close")) { close() }
                    }
                    .controlButton()
                }
                .foregroundStyle(.white).padding()
            } else {
                VStack(spacing: 16) {
                    ProgressView().tint(.white).controlSize(.large)
                    MangaWaitNote().padding(.horizontal, 32)
                }
            }
            MangaReaderChrome(model: model, visible: chrome, showsChapters: $showsChapters, close: close)
        }
        .environment(\.colorScheme, .dark)
        #if os(iOS)
        .statusBarHidden(!chrome)
        .persistentSystemOverlays(chrome ? .automatic : .hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        #if os(macOS)
        .toolbar(.hidden, for: .windowToolbar)
        .navigationBarBackButtonHidden()
        #endif
        #if os(tvOS)
        .onExitCommand { if chrome { close() } else { withAnimation { chrome = true } } }
        #endif
        .sheet(isPresented: $showsChapters) {
            MangaChapterPicker(model: model) { index in showsChapters = false; Task { await model.open(index) } }
        }
        .task {
            await model.open(start.chapter, page: start.page)
            try? await Task.sleep(for: .seconds(2))
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "qaMangaChrome") { return }
            #endif
            withAnimation(.smooth) { chrome = false }
        }
        .onDisappear { model.save(force: true) }
        .environment(\.mangaToggleChrome, MangaChromeToggle { withAnimation(.smooth(duration: 0.2)) { chrome.toggle() } })
    }

    @ViewBuilder private var pages: some View {
        switch model.mode {
        case .vertical: MangaVerticalReader(model: model)
        case .leftToRight, .rightToLeft: MangaPagedReader(model: model)
        }
    }

    private func close() {
        model.save(force: true)
        dismiss()
    }
}

struct MangaChromeToggle { let toggle: () -> Void; func callAsFunction() { toggle() } }
extension EnvironmentValues { @Entry var mangaToggleChrome: MangaChromeToggle? = nil }

// MARK: - One page

/// A page image, fetched the way its source asks and scaled for the screen; a placeholder keeps its place.
struct MangaPageImage: View {
    let model: MangaReaderModel
    let chapter: Int
    let index: Int
    let url: String
    /// The width to decode for, in pixels.
    let pixelWidth: CGFloat
    var fitsScreen = false
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
                    .aspectRatio(CGFloat(image.width) / CGFloat(max(image.height, 1)), contentMode: .fit)
            } else {
                Color.white.opacity(0.04)
                    .aspectRatio(model.aspects[url] ?? 0.7, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 12) {
                            Text("\(index + 1)").font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.25))
                            if let message = failure {
                                Text(message).font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal)
                                Button(L10n.text("Try Again")) { self.failure = nil; attempt += 1 }.controlButton()
                            } else { ProgressView().tint(.white.opacity(0.6)) }
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fitsScreen ? .infinity : nil)
        .task(id: "\(url)#\(attempt)#\(Int(pixelWidth))") { await load() }
    }

    private func load() async {
        guard pixelWidth > 0 else { return }
        do {
            let data = try await MangaImages.shared.data(source: model.comic.sourceKey, url: url, kind: .page, comic: model.comic.id, chapter: model.chapterID(chapter))
            let width = pixelWidth
            let decoded = await Task.detached(priority: .userInitiated) { MangaImages.bitmap(data, width: width) }.value
            guard !Task.isCancelled else { return }
            if let decoded {
                model.aspects[url] = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
                image = decoded
            } else { failure = L10n.text("This page could not be shown.") }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { failure = error.mangaMessage }
        }
    }
}

// MARK: - Vertical

/// Pages one under another, read on into the next chapter; pinch or double-tap to zoom.
struct MangaVerticalReader: View {
    let model: MangaReaderModel
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @Environment(\.displayScale) private var scale
    @Environment(\.mangaToggleChrome) private var toggleChrome

    var body: some View {
        // The pages run edge to edge, under the Dynamic Island; the outer reader keeps the safe area so the
        // Previous Chapter button at the top can sit below it.
        GeometryReader { outer in
        let top = outer.safeAreaInsets.top
        GeometryReader { proxy in
            let width = proxy.size.width * zoom * pinch
            ScrollViewReader { reader in
                ScrollView(zoom > 1 ? [.vertical, .horizontal] : .vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        if model.hasPrevious, model.loaded.first?.index == model.position.chapter, let first = model.loaded.first {
                            Button { Task { await model.open(first.index - 1, page: -1) } } label: {
                                Label(L10n.text("Previous Chapter"), systemImage: "chevron.up").padding(.vertical, 24).frame(maxWidth: .infinity)
                                    .padding(.top, top)
                            }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                            .id("previous")
                        }
                        ForEach(model.loaded) { chapter in
                            ForEach(Array(chapter.pages.enumerated()), id: \.offset) { index, url in
                                MangaPageImage(model: model, chapter: chapter.index, index: index, url: url, pixelWidth: min(proxy.size.width * scale * 1.5, 2400))
                                    .id(MangaReaderModel.Position(chapter: chapter.index, page: index))
                                    .onAppear { model.seen(.init(chapter: chapter.index, page: index)) }
                                    #if os(tvOS)
                                    .focusable()
                                    #endif
                            }
                            MangaChapterEnd(model: model, chapter: chapter.index)
                        }
                    }
                    .frame(width: width)
                }
                .onChange(of: model.target) { _, target in
                    guard let target else { return }
                    reader.scrollTo(target, anchor: .top)
                    model.target = nil
                }
                .onAppear {
                    if let target = model.target { reader.scrollTo(target, anchor: .top); model.target = nil }
                    #if DEBUG
                    if UserDefaults.standard.bool(forKey: "qaMangaScrollTop") {
                        Task { try? await Task.sleep(for: .seconds(4)); reader.scrollTo("previous", anchor: .top) }
                    }
                    #endif
                }
                #if os(iOS) || os(macOS)
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in pinch = value.magnification }
                    .onEnded { value in zoom = min(4, max(1, zoom * value.magnification)); pinch = 1 })
                .onTapGesture(count: 2) { withAnimation(.smooth) { zoom = zoom > 1 ? 1 : 2 } }
                .onTapGesture { toggleChrome?() }
                #endif
            }
        }
        .ignoresSafeArea()
        }
    }
}

/// The break between two chapters in vertical mode: what comes next, or the end of the comic.
private struct MangaChapterEnd: View {
    let model: MangaReaderModel
    let chapter: Int
    var body: some View {
        VStack(spacing: 10) {
            if chapter + 1 < model.chapters.count {
                Text(L10n.text("End of %@", model.title(chapter))).font(.footnote).foregroundStyle(.white.opacity(0.5))
                Text(L10n.text("Next: %@", model.title(chapter + 1))).font(.headline).foregroundStyle(.white.opacity(0.85))
                if model.loadingNext { ProgressView().tint(.white) }
            } else {
                Image(systemName: "checkmark.circle").font(.title).foregroundStyle(.white.opacity(0.6))
                Text(model.single ? L10n.text("The End") : L10n.text("You're all caught up")).font(.headline).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.vertical, 48).frame(maxWidth: .infinity)
        .onAppear { Task { await model.loadNext() } }
    }
}

// MARK: - Paged

/// One page at a time. Taps on the sides turn pages (the leading side goes back, mirrored for right-to-left),
/// the middle shows the controls; the remote's arrows and the keyboard's turn them too.
struct MangaPagedReader: View {
    let model: MangaReaderModel
    @Environment(\.displayScale) private var scale
    @Environment(\.mangaToggleChrome) private var toggleChrome
    @State private var page = 0
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    private var rtl: Bool { model.mode == .rightToLeft }
    private var count: Int { model.currentPages.count }

    var body: some View {
        GeometryReader { proxy in
            let pixelWidth = min(max(proxy.size.width, proxy.size.height) * scale, 3000)
            Group {
                #if os(iOS)
                TabView(selection: $page) {
                    ForEach(Array(model.currentPages.enumerated()), id: \.offset) { index, url in
                        MangaZoomablePage { MangaPageImage(model: model, chapter: model.position.chapter, index: index, url: url, pixelWidth: pixelWidth, fitsScreen: true) }
                            .tag(index)
                    }
                    MangaPagedEnd(model: model).tag(count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .overlay { tapZones(proxy.size) }
                #else
                ZStack {
                    if page < count {
                        MangaPageImage(model: model, chapter: model.position.chapter, index: page, url: model.currentPages[page], pixelWidth: pixelWidth, fitsScreen: true)
                            .id("\(model.position.chapter)-\(page)")
                            .transition(.opacity)
                    } else { MangaPagedEnd(model: model) }
                    // The next page decodes out of sight, so turning shows it at once.
                    if page + 1 < count {
                        MangaPageImage(model: model, chapter: model.position.chapter, index: page + 1, url: model.currentPages[page + 1], pixelWidth: pixelWidth, fitsScreen: true)
                            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                #if os(macOS)
                .overlay { tapZones(proxy.size) }
                .focusable().focusEffectDisabled()
                .onKeyPress(.leftArrow) { turn(rtl ? 1 : -1); return .handled }
                .onKeyPress(.rightArrow) { turn(rtl ? -1 : 1); return .handled }
                .onKeyPress(.space) { turn(1); return .handled }
                #else
                .focusable().focused($focused)
                .onAppear { focused = true }
                .onMoveCommand { direction in
                    switch direction {
                    case .left: turn(rtl ? 1 : -1)
                    case .right: turn(rtl ? -1 : 1)
                    case .down: Task { if model.hasNext { await model.open(model.position.chapter + 1) } }
                    case .up: Task { if model.hasPrevious { await model.open(model.position.chapter - 1) } }
                    default: break
                    }
                }
                .onPlayPauseCommand { toggleChrome?() }
                .onTapGesture { toggleChrome?() }
                #endif
                #endif
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear { page = model.position.page }
        .onChange(of: page) { _, value in
            if value < count { model.seen(.init(chapter: model.position.chapter, page: value)) }
            else if model.hasNext { Task { await model.open(model.position.chapter + 1) } }
        }
        .onChange(of: model.target) { _, target in
            guard let target else { return }
            page = target.page
            model.target = nil
        }
    }

    private func turn(_ step: Int) {
        let next = page + step
        if next < 0 {
            if model.hasPrevious { Task { await model.open(model.position.chapter - 1, page: -1) } }
            return
        }
        guard next <= count else { return }
        withAnimation(.smooth(duration: 0.18)) { page = next }
    }

    #if !os(tvOS)
    /// A third on each side turns the page; the middle shows the controls.
    private func tapZones(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).frame(width: size.width * 0.3).onTapGesture { turn(rtl ? 1 : -1) }
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleChrome?() }
            Color.clear.contentShape(Rectangle()).frame(width: size.width * 0.3).onTapGesture { turn(rtl ? -1 : 1) }
        }
        // Pinches and drags reach the page under the zones.
        .allowsHitTesting(true)
    }
    #endif
}

/// After a chapter's last page: the next chapter, or the end.
private struct MangaPagedEnd: View {
    let model: MangaReaderModel
    var body: some View {
        VStack(spacing: 14) {
            if model.hasNext {
                Text(L10n.text("End of %@", model.title(model.position.chapter))).font(.footnote).foregroundStyle(.white.opacity(0.5))
                Text(L10n.text("Next: %@", model.title(model.position.chapter + 1))).font(.title3.weight(.semibold))
                ProgressView().tint(.white)
            } else {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                Text(model.single ? L10n.text("The End") : L10n.text("You're all caught up")).font(.title3.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(iOS)
/// A page that zooms with a pinch or a double tap, then pans; at 1× drags fall through to the page turner.
struct MangaZoomablePage<Content: View>: UIViewRepresentable {
    @ViewBuilder let content: Content

    func makeCoordinator() -> Coordinator { Coordinator(UIHostingController(rootView: content)) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator
        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = true
        scroll.addSubview(host.view)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
        DispatchQueue.main.async {
            if scroll.zoomScale == 1 { context.coordinator.host.view.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>
        init(_ host: UIHostingController<Content>) { self.host = host }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true); return }
            let point = gesture.location(in: host.view)
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
#endif

// MARK: - Controls

private struct MangaReaderChrome: View {
    /// Dark glass: the chrome sits on white pages as often as dark ones, and its labels are white.
    static let glass = GlassStyle.regular.tint(.black.opacity(0.45)).interactive()
    let model: MangaReaderModel
    let visible: Bool
    @Binding var showsChapters: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            top
            Spacer(minLength: 0)
            bottom
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.smooth(duration: 0.2), value: visible)
    }

    private var top: some View {
        HStack(spacing: 14) {
            #if !os(tvOS)
            Button(action: close) { Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36) }
                .buttonStyle(.plain).glassSurface(MangaReaderChrome.glass, in: Circle())
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L10n.text("Close"))
            #endif
            VStack(alignment: .leading, spacing: 1) {
                Text(model.comic.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !model.single { Text(model.title(model.position.chapter)).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .glassSurface(MangaReaderChrome.glass, in: Capsule())
            .layoutPriority(-1)
            Spacer(minLength: 0)
            #if !os(tvOS)
            Menu {
                Picker(L10n.text("Reading Mode"), selection: Binding(get: { model.mode }, set: { mode in
                    let position = model.position
                    model.mode = mode
                    model.target = position
                })) {
                    ForEach(MangaReaderMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            } label: { Image(systemName: model.mode.symbol).font(.headline).frame(width: 36, height: 36) }
            .menuStyle(.button).buttonStyle(.plain).glassSurface(MangaReaderChrome.glass, in: Circle())
            .accessibilityLabel(L10n.text("Reading Mode"))
            if !model.single {
                Button { showsChapters = true } label: { Image(systemName: "list.bullet").font(.headline).frame(width: 36, height: 36) }
                    .buttonStyle(.plain).glassSurface(MangaReaderChrome.glass, in: Circle())
                    .accessibilityLabel(L10n.text("Chapters"))
            }
            #endif
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    private var bottom: some View {
        let count = model.currentPages.count
        return HStack(spacing: 12) {
            #if !os(tvOS)
            Button { Task { await model.open(model.position.chapter - 1) } } label: { Image(systemName: "backward.end.fill").frame(width: 32, height: 32) }
                .buttonStyle(.plain).disabled(!model.hasPrevious).opacity(model.hasPrevious ? 1 : 0.35)
                .accessibilityLabel(L10n.text("Previous Chapter"))
            if count > 1 {
                Slider(value: Binding(get: { Double(min(model.position.page, count - 1)) },
                                      set: { value in model.target = .init(chapter: model.position.chapter, page: Int(value.rounded())) }),
                       in: 0...Double(count - 1), step: 1)
                    .tint(.white)
                    .environment(\.layoutDirection, model.mode == .rightToLeft ? .rightToLeft : .leftToRight)
            } else { Spacer() }
            #else
            Spacer()
            #endif
            Text("\(min(model.position.page + 1, max(count, 1))) / \(max(count, 1))").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            #if !os(tvOS)
            Button { Task { await model.open(model.position.chapter + 1) } } label: { Image(systemName: "forward.end.fill").frame(width: 32, height: 32) }
                .buttonStyle(.plain).disabled(!model.hasNext).opacity(model.hasNext ? 1 : 0.35)
                .accessibilityLabel(L10n.text("Next Chapter"))
            #endif
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassSurface(MangaReaderChrome.glass, in: Capsule())
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

/// The comic's chapters, the one being read marked; picking one opens it.
private struct MangaChapterPicker: View {
    let model: MangaReaderModel
    let pick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                List(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button { pick(index) } label: {
                        HStack {
                            Text(chapter.title).foregroundStyle(.primary)
                            Spacer()
                            if index == model.position.chapter { Image(systemName: "book.fill").foregroundStyle(Brand.cyan) }
                        }
                    }
                    .id(index)
                }
                .onAppear { reader.scrollTo(model.position.chapter, anchor: .center) }
            }
            .navigationTitle(L10n.text("Chapters"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
        #endif
        .presentationDetents([.medium, .large])
    }
}
