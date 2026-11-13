#if DEBUG
import SwiftUI
import TVCore

/// Launch flags for screenshots and simulator checks of the Novels section (`-qaSection novels` plus
/// `-qaSubscription <Legado list>` to add a list through the normal subscription path):
/// - `-qaNovelOnly <name,name>` switches on only the sources whose names contain one of these (faster QA searches).
/// - `-qaNovelPage search|sources|shelf` opens that page; `-qaNovelQuery <text>` searches on the search page.
/// - `-qaNovelOpen <source key>|<book url>|<name>` opens a book's page; with `-qaNovelRead 1` it reads on;
///   `-qaNovelChrome 1` keeps the reader bars up; `-qaNovelTheme <NovelTheme>` sets the page colour;
///   `-qaNovelTurns <n>` turns n pages; `-qaNovelPanel text|theme|contents` opens a reader panel;
///   `-qaNovelJumps 300,20,187` lets go of the chapter slider at those places, 4 s apart; `-qaNovelTOC 1` opens the
///   book's table of contents.
/// - `-qaNovelAutoScroll <delay>` (iOS) scrolls the page up and down for 20 s like a finger and writes the late frames
///   to Library/Caches/qa-scroll.txt.
@MainActor enum NovelQA {
    private static var started = false

    static func start(openRoute: RouteOpener?) async {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        let store = NovelStore.shared
        if let only = defaults.string(forKey: "qaNovelOnly") {
            let names = only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let all = store.sources.map(\.key)
            let wanted = store.sources.filter { source in names.contains { source.name.contains($0) } }.map(\.key)
            store.setEnabled(false, all)
            store.setEnabled(true, wanted)
        }
        #if os(iOS)
        // `-qaNovelAutoScroll <delay>` scrolls the page as a finger would, frame by frame, and writes the slow frames to
        // Library/Caches/qa-scroll.txt.
        let delay = defaults.double(forKey: "qaNovelAutoScroll")
        if delay > 0 {
            Task { try? await Task.sleep(for: .seconds(delay)); QAScroller.shared.start() }
        }
        #endif
        if let theme = defaults.string(forKey: "qaNovelTheme").flatMap(NovelTheme.init(rawValue:)) { store.theme = theme }
        guard let openRoute else { return }
        switch defaults.string(forKey: "qaNovelPage") {
        case "search": openRoute(Route { AnyView(NovelSearchView()) })
        case "sources": openRoute(Route { AnyView(NovelSourcesView()) })
        case "shelf": openRoute(Route { AnyView(NovelShelfView()) })
        default: break
        }
        if let target = defaults.string(forKey: "qaNovelOpen") {
            let parts = target.split(separator: "|", maxSplits: 2).map(String.init)
            if parts.count >= 2 {
                let book = NovelBook(sourceKey: parts[0], url: parts[1], name: parts.count > 2 ? parts[2] : "")
                openRoute(Route { AnyView(NovelDetailView(book: book)) })
                // `-qaNovelTOC 1` opens its table of contents over it.
                if defaults.bool(forKey: "qaNovelTOC"), let filled = try? await NovelBooks.shared.details(book),
                   let list = try? await NovelBooks.shared.chapters(filled, refresh: false) {
                    openRoute(Route { AnyView(NovelTOCView(book: filled, chapters: list)) })
                }
            }
        }
    }
}

#if os(iOS)
/// Moves the page's biggest scroll view down and back up for a while at a finger's speed, a step every frame, and
/// counts the frames that came late.
@MainActor final class QAScroller: NSObject {
    static let shared = QAScroller()
    private var link: CADisplayLink?
    private weak var view: UIScrollView?
    private var last: CFTimeInterval = 0
    private var started: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private var frames: [Double] = []

    func start() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height * 1.5, scroll.window != nil { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        windows.forEach(walk)
        view = found.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        guard view != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let view else { stop(); return }
        if started == 0 { started = link.timestamp; last = link.timestamp; return }
        frames.append((link.timestamp - last) * 1000)
        last = link.timestamp
        let maxY = max(0, view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
        var y = view.contentOffset.y + direction * 1500 * CGFloat(link.duration)
        if y >= maxY { y = maxY; direction = -1 } else if y <= -view.adjustedContentInset.top { y = -view.adjustedContentInset.top; direction = 1 }
        view.contentOffset.y = y
        if link.timestamp - started > 20 { stop() }
    }

    private func stop() {
        link?.invalidate(); link = nil
        let late = frames.filter { $0 > 25 }
        var text = "frames \(frames.count) late>25ms \(late.count) late>50ms \(frames.filter { $0 > 50 }.count) worst \(Int(frames.max() ?? 0))ms\n"
        text += frames.enumerated().filter { $0.element > 25 }.map { "#\($0.offset) \(Int($0.element))ms" }.joined(separator: "\n")
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("qa-scroll.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
#endif
