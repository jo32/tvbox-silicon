import SwiftUI
import TVCore

/// The reading state: loaded chapters (vertical mode reads on from one into the next), where the viewer is,
/// prefetching ahead, and the saved progress.
@MainActor @Observable final class MangaReaderModel {
    struct Chapter: Identifiable {
        let index: Int
        let pages: [String]
        /// Read a while ago: its rows stay in the column, as tall as they were, without their pictures.
        var released = false
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
    private var released = Date.distantPast

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
            release()
        }
    }

    /// Long reads keep the pictures of a few chapters, not of the whole comic: the chapter being read and the two
    /// before it. Older chapters keep their rows, each as tall as its page was, so nothing below them moves. Taking
    /// a chapter out of the column instead moved every later page up by its height, and the reader, near the end of
    /// a chapter, was suddenly a chapter or more ahead (#879).
    private func release() {
        for at in loaded.indices {
            let old = loaded[at].index < position.chapter - 2
            guard loaded[at].released != old else { continue }
            loaded[at].released = old
            if old { released = Date() }
        }
    }

    /// A released chapter scrolled back into view takes its pictures back. Not right after a release: a row swapped
    /// for its placeholder out of sight may report appearing.
    func restore(_ chapter: Int) {
        guard Date().timeIntervalSince(released) > 1, let at = loaded.firstIndex(where: { $0.index == chapter && $0.released }) else { return }
        loaded[at].released = false
    }

    private func fetch(_ chapter: Int) async throws -> [String] {
        try await MangaRuntime.shared.pages(comic.sourceKey, comic: comic.id, chapter: chapters.indices.contains(chapter) ? chapters[chapter].id : nil)
    }

    func seen(_ position: Position) {
        guard position != self.position else { return }
        let turned = position.chapter != self.position.chapter
        self.position = position
        if turned { release() }
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
    #if os(macOS)
    @Environment(Store.self) private var store
    #endif
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
                ErrorState(title: L10n.text("Unable to Load"), message: failure, details: "",
                           retry: { Task { await model.open(model.position.chapter, page: model.position.page) } },
                           goBack: { close() }, backTitle: L10n.text("Close"))
                    .padding().environment(\.colorScheme, .dark)
            } else {
                VStack(spacing: 16) {
                    ProgressView().tint(.white).appControlSize(.large)
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
        .onAppear { store.hidesSidebar = true }
        .onDisappear { store.hidesSidebar = false }
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

/// Where a page was, as tall as the page, without its picture.
private struct MangaPagePlace: View {
    let model: MangaReaderModel
    let url: String
    var body: some View {
        Color.clear.aspectRatio(model.aspects[url] ?? 0.7, contentMode: .fit).frame(maxWidth: .infinity)
    }
}

// MARK: - Vertical

/// Pages one under another, read on into the next chapter; pinch or double-tap to zoom.
struct MangaVerticalReader: View {
    let model: MangaReaderModel
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    #if os(iOS)
    @State private var zoomer = MangaZoomController()
    #endif
    @Environment(\.displayScale) private var scale
    @Environment(\.mangaToggleChrome) private var toggleChrome

    var body: some View {
        // The pages run edge to edge, under the Dynamic Island; the outer reader keeps the safe area so the
        // Previous Chapter button at the top can sit below it.
        GeometryReader { outer in
        let top = outer.safeAreaInsets.top
        GeometryReader { proxy in
            #if os(iOS)
            // UIKit zooms the whole column, so the spot between the fingers stays under them (see MangaZoomView).
            MangaPinchZoom(controller: zoomer) {
                column(proxy.size, top: top)
                    .onTapGesture(count: 2, coordinateSpace: .local) { zoomer.toggle(at: $0) }
                    .onTapGesture { toggleChrome?() }
                    .environment(\.colorScheme, .dark)
            }
            #else
            column(proxy.size, top: top)
                #if os(macOS)
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in pinch = value.magnification }
                    .onEnded { value in zoom = min(4, max(1, zoom * value.magnification)); pinch = 1 })
                .onTapGesture(count: 2) { withAnimation(.smooth) { zoom = zoom > 1 ? 1 : 2 } }
                .onTapGesture { toggleChrome?() }
                #endif
            #endif
        }
        .ignoresSafeArea()
        }
    }

    private func column(_ size: CGSize, top: CGFloat) -> some View {
        let width = size.width * zoom * pinch
        return ScrollViewReader { reader in
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
                            if chapter.released {
                                // The page's place, exactly as tall as the page was (see `MangaReaderModel.release`).
                                MangaPagePlace(model: model, url: url)
                                    .id(MangaReaderModel.Position(chapter: chapter.index, page: index))
                                    .onAppear { model.restore(chapter.index) }
                            } else {
                                MangaPageImage(model: model, chapter: chapter.index, index: index, url: url, pixelWidth: min(size.width * scale * 1.5, 2400))
                                    .id(MangaReaderModel.Position(chapter: chapter.index, page: index))
                                    .onAppear { model.seen(.init(chapter: chapter.index, page: index)) }
                                    #if os(tvOS)
                                    .focusable()
                                    #endif
                            }
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
                        // The page takes its own taps: a SwiftUI overlay over it would swallow the pinch.
                        MangaZoomablePage(tapped: tapped) { MangaPageImage(model: model, chapter: model.position.chapter, index: index, url: url, pixelWidth: pixelWidth, fitsScreen: true) }
                            .tag(index)
                    }
                    MangaPagedEnd(model: model)
                        .overlay { tapZones(proxy.size).environment(\.layoutDirection, .leftToRight) }
                        .tag(count)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
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
                    // Left is the previous page and Right the next in every reading mode, as on any TV list: pages fade
                    // here rather than slide, and a remote's Left going forward in right-to-left comics read as backwards.
                    switch direction {
                    case .left: turn(-1)
                    case .right: turn(1)
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
    /// A tap `across` the screen (0 left, 1 right): a third on each side turns the page; the middle shows the controls.
    private func tapped(_ across: CGFloat) {
        if across < 0.3 { turn(rtl ? 1 : -1) } else if across > 0.7 { turn(rtl ? -1 : 1) } else { toggleChrome?() }
    }

    private func tapZones(_ size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in tapped(point.x / max(size.width, 1)) }
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
    /// A single tap, with where it landed across the page: 0 at the left edge, 1 at the right.
    let tapped: (CGFloat) -> Void
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
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTapped(_:)))
        tap.require(toFail: doubleTap)
        // A failed page's Try Again button still gets its tap.
        tap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(tap)
        context.coordinator.tapped = tapped
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
        context.coordinator.tapped = tapped
        DispatchQueue.main.async {
            if scroll.zoomScale == 1 { context.coordinator.host.view.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let host: UIHostingController<Content>
        var tapped: (CGFloat) -> Void = { _ in }
        init(_ host: UIHostingController<Content>) { self.host = host }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
        @objc func singleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, scroll.bounds.width > 0 else { return }
            tapped((gesture.location(in: scroll).x - scroll.bounds.minX) / scroll.bounds.width)
        }
        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true); return }
            let point = gesture.location(in: host.view)
            let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// Lets SwiftUI taps reach the vertical reader's zoom.
@MainActor final class MangaZoomController {
    fileprivate weak var view: MangaZoomView?
    /// Double tap: zooms in around `point` (in the column's own, unzoomed space), or back out.
    func toggle(at point: CGPoint) {
        guard let view else { return }
        view.toggleZoom(at: view.content.convert(point, to: view))
    }
}

/// Zooms the vertical reader's whole scrolling column, the way Mihon's webtoon reader does, so its pages stay lazy.
struct MangaPinchZoom<Content: View>: UIViewRepresentable {
    let controller: MangaZoomController
    @ViewBuilder let content: Content

    func makeCoordinator() -> UIHostingController<Content> { UIHostingController(rootView: content) }

    func makeUIView(context: Context) -> MangaZoomView {
        let host = context.coordinator
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        let view = MangaZoomView(content: host.view)
        controller.view = view
        return view
    }

    func updateUIView(_ view: MangaZoomView, context: Context) {
        context.coordinator.rootView = content
        controller.view = view
    }
}

/// Scales and moves `content` with a transform, like a photo: the spot between the fingers stays under them while
/// they pinch and move; one finger pans sideways when zoomed (the column's own scroll view keeps scrolling it down),
/// and past its top or bottom moves the zoomed view up or down. Zoom past the limits gives a little, then springs back.
final class MangaZoomView: UIView, UIGestureRecognizerDelegate {
    let content: UIView
    let maxScale: CGFloat = 4
    private(set) var scale: CGFloat = 1
    /// The content's centre, from the view's centre.
    private var offset = CGPoint.zero
    /// The last pinch centre, from the view's centre.
    private var focal = CGPoint.zero
    private var touches = 0
    private let pinch = UIPinchGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    private weak var foundScroll: UIScrollView?

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(content)
        pinch.addTarget(self, action: #selector(pinched(_:)))
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        for recognizer in [pinch, pan] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.center = CGPoint(x: bounds.midX, y: bounds.midY)
        offset = clamped(offset, scale: scale)
        apply()
    }

    /// The column's own scroll view (SwiftUI's ScrollView is a UIScrollView underneath).
    private var scroll: UIScrollView? {
        if let foundScroll, foundScroll.isDescendant(of: content) { return foundScroll }
        var queue = [content]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView { foundScroll = scroll; return scroll }
            queue += view.subviews
        }
        return nil
    }

    private func apply() {
        content.transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
        // Zoomed, the edges move the view instead of stretching the column.
        scroll?.bounces = scale <= 1.01
    }

    private func centred(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY) }

    /// Keeps the zoomed content covering the view.
    private func clamped(_ offset: CGPoint, scale: CGFloat) -> CGPoint {
        let x = max(0, (scale - 1) * bounds.width / 2), y = max(0, (scale - 1) * bounds.height / 2)
        return CGPoint(x: min(x, max(-x, offset.x)), y: min(y, max(-y, offset.y)))
    }

    /// The offset that puts the content point now under `from` under `to` at `newScale`.
    private func anchored(_ from: CGPoint, at to: CGPoint, scale newScale: CGFloat) -> CGPoint {
        let point = CGPoint(x: (from.x - offset.x) / scale, y: (from.y - offset.y) / scale)
        return CGPoint(x: to.x - point.x * newScale, y: to.y - point.y * newScale)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let location = centred(gesture.location(in: self))
        switch gesture.state {
        case .began:
            focal = location
            touches = gesture.numberOfTouches
            // Two fingers both pinch and move; the column must not scroll with them as well.
            scroll?.panGestureRecognizer.isEnabled = false
            fallthrough
        case .changed:
            // A finger lifted or landed moves the centre point; start from there without a jump.
            if gesture.numberOfTouches != touches { touches = gesture.numberOfTouches; focal = location; gesture.scale = 1; return }
            // Past the limits the zoom gives less and less.
            let step = scale > maxScale || scale < 1 ? pow(gesture.scale, 0.35) : gesture.scale
            let newScale = min(maxScale * 1.6, max(0.6, scale * step))
            gesture.scale = 1
            offset = clamped(anchored(focal, at: location, scale: newScale), scale: newScale)
            scale = newScale
            focal = location
            apply()
        case .ended, .cancelled, .failed:
            scroll?.panGestureRecognizer.isEnabled = true
            let settled = min(maxScale, max(1, scale))
            zoom(to: settled, offset: anchored(focal, at: focal, scale: settled))
        default: break
        }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let move = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard pinch.state != .began, pinch.state != .changed else { return }
        var next = offset
        next.x += move.x
        // The column scrolls itself; only at its top or bottom does the zoomed view move up or down.
        if let scroll {
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
            if (move.y > 0 && scroll.contentOffset.y <= top + 1) || (move.y < 0 && scroll.contentOffset.y >= bottom - 1) { next.y += move.y }
        }
        offset = clamped(next, scale: scale)
        apply()
        if gesture.state == .ended {
            // Glide on sideways, as a scroll view would.
            let velocity = gesture.velocity(in: self).x
            let target = clamped(CGPoint(x: offset.x + velocity * 0.25, y: offset.y), scale: scale)
            guard target.x != offset.x else { return }
            offset = target
            UIView.animate(withDuration: 0.5, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) { self.apply() }
        }
    }

    func toggleZoom(at point: CGPoint) {
        if scale > 1.01 { zoom(to: 1, offset: .zero); return }
        let location = centred(point)
        zoom(to: 2.5, offset: anchored(location, at: location, scale: 2.5))
    }

    private func zoom(to newScale: CGFloat, offset newOffset: CGPoint) {
        scale = newScale <= 1.01 ? 1 : newScale
        offset = clamped(newOffset, scale: scale)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) { self.apply() }
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        gesture === pan ? scale > 1.01 : super.gestureRecognizerShouldBegin(gesture)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif

// MARK: - Controls

private struct MangaReaderChrome: View {
    /// Dark glass: the chrome sits on white pages as often as dark ones, and its labels are white.
    static let glass = GlassStyle.regular.tint(.black.opacity(0.45)).interactive()
    #if os(tvOS)
    private static let titleFont = Font.system(size: 29, weight: .semibold), chapterFont = Font.system(size: 23)
    private static let pillInset: CGFloat = 26, pillHeight: CGFloat = 76
    #else
    private static let titleFont = Font.subheadline.weight(.semibold), chapterFont = Font.caption
    private static let pillInset: CGFloat = 14, pillHeight: CGFloat = 40
    #endif
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
        #if os(macOS)
        .ignoresSafeArea(.container, edges: .top)
        .background { MangaHidesWindowButtons() }
        #endif
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
                Text(model.comic.title).font(Self.titleFont).lineLimit(1)
                if !model.single { Text(model.title(model.position.chapter)).font(Self.chapterFont).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Self.pillInset).frame(minHeight: Self.pillHeight)
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
        #if os(macOS)
        // Up in the title bar, lined up with the bottom bar. Under the 52 pt title bar the top bar sat much further
        // from the top edge than the bottom bar sits from the bottom.
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
        #else
        .padding(.horizontal, 16).padding(.vertical, 10)
        #endif
        .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    #if os(tvOS)
    /// Apple TV has no slider and the remote turns the pages, so the bar only says where you are: a short track and the
    /// page count in one pill, centred, like the TV app's scrubber.
    private var bottom: some View {
        let count = max(model.currentPages.count, 1)
        let page = min(model.position.page + 1, count)
        let track: CGFloat = 420
        return HStack(spacing: 24) {
            // Fills from the left in every reading mode, as progress bars do on the TV: filled from the right for
            // right-to-left comics, page 1 was a tick at the far end and read as the last page. The empty track stays dark
            // so it doesn't pass for filled over a white page.
            Capsule().fill(.black.opacity(0.35)).frame(width: track, height: 8)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: max(track * CGFloat(page) / CGFloat(count), 8), height: 8)
                }
            Text("\(page) / \(count)").font(.system(size: 26, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 32).padding(.vertical, 18)
        .glassSurface(MangaReaderChrome.glass, in: Capsule())
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(page) / \(count)")
    }
    #else
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
    #endif
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

#if os(macOS)
/// Hides the window's close, minimise and zoom buttons while the reader is open, so its top bar can sit in the title bar
/// lined up with the bottom bar: with the toolbar hidden, macOS fades them in when the pointer comes near, over the bar's
/// close button. The reader's own close button, Esc and Command-W still close it; the buttons come back with it.
private struct MangaHidesWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            show(true, in: window)
            show(false, in: newWindow)
        }
        private func show(_ shown: Bool, in window: NSWindow?) {
            for kind in Self.kinds { window?.standardWindowButton(kind)?.isHidden = !shown }
        }
    }
}
#endif
