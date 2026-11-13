import SwiftUI
import AVFoundation
import CoreText
import TVCore

/// Bullet comments over the video. Positions come from the player's clock on every frame, so the
/// comments pause, seek and change speed with the video; each comment's text is drawn once.
struct DanmakuOverlay: View {
    let player: AVPlayer
    let comments: [Danmaku]
    var opacity = 0.9
    var revision = ""
    @State private var jumps = 0

    var body: some View {
        DanmakuCanvas(comments: comments, revision: revision, opacity: opacity, jumps: jumps) { player.currentTime().seconds }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.timeJumpedNotification)) { notification in
                guard let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
                jumps += 1
            }
    }
}

/// Comments drawn at the moment `clock` gives, in the look and with the filters chosen in Settings › Danmaku and the
/// player's danmaku menus: one set for every track (matched or imported comments, Bilibili videos, live rooms). Both
/// the player's overlay and that page's moving preview, so the preview shows exactly what the player will draw.
struct DanmakuCanvas: View {
    let comments: [Danmaku]
    var revision = ""
    var opacity = DanmakuStyle.standardOpacity
    /// Changes when the player jumps: its time-jump notification catches small seeks that look like ordinary frames.
    var jumps = 0
    let clock: () -> Double
    @AppStorage(DanmakuArea.key) private var area = DanmakuArea.standard
    @AppStorage(DanmakuStyle.fontSizeKey) private var fontSize = DanmakuStyle.standardFontSize
    @AppStorage(DanmakuStyle.speedKey) private var speed = DanmakuStyle.standardSpeed
    @AppStorage(DanmakuStyle.scrollKey) private var scroll = true
    @AppStorage(DanmakuStyle.topKey) private var top = true
    @AppStorage(DanmakuStyle.bottomKey) private var bottom = true
    @AppStorage(DanmakuFilter.colorsKey) private var colors = true
    @AppStorage(DanmakuFilter.wordsKey) private var blockedWords = ""
    @State private var engine = DanmakuEngine()
    @Environment(\.displayScale) private var scale

    private struct Load: Equatable {
        let revision: String, count: Int, filter: DanmakuFilter
    }

    private var filter: DanmakuFilter { DanmakuFilter(colors: colors, words: DanmakuFilter.words(blockedWords)) }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                // Reading the timeline's date makes every tick a new drawing; the clock itself is the caller's.
                _ = timeline.date
                let time = clock()
                guard time.isFinite else { return }
                for sprite in engine.frame(time: time, size: size, scale: scale, area: area, textScale: DanmakuStyle.textScale(fontSize),
                                           speed: speed, scroll: scroll, top: top, bottom: bottom) {
                    context.draw(Image(decorative: sprite.image, scale: scale), in: sprite.frame)
                }
            }
        }
        .opacity(opacity)
        // No `ignoresSafeArea` here: it would win over the caller's, and the iPhone keeps comments below the Dynamic Island.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: Load(revision: revision, count: comments.count, filter: filter)) {
            // Filtering keeps the order and drops comments in place, so a live track still only grows at the end.
            let filter = filter
            engine.load(filter.apply(comments), revision: "\(revision)|\(filter.colors)|\(DanmakuFilter.stored(filter.words))")
        }
        .onChange(of: jumps) { engine.reset() }
    }
}

/// Whether comments are shown, from Settings and the player's own toggle.
enum DanmakuPreference {
    static let key = "danmakuEnabled"
}

#if !os(tvOS)
// The player's menus and sheets on iPhone, iPad and Mac; the TV has its transport menu and Settings › Danmaku.
/// Rows shared by global settings and the playback panel; no comment track needs to be loaded.
struct DanmakuDisplaySettings: View {
    @AppStorage(DanmakuArea.key) private var area = DanmakuArea.standard
    @AppStorage(DanmakuStyle.fontSizeKey) private var fontSize = DanmakuStyle.standardFontSize
    @AppStorage(DanmakuStyle.opacityKey) private var opacity = DanmakuStyle.standardOpacity

    var body: some View {
        Picker(selection: $area) {
            ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: { Label(L10n.text("Danmaku Area"), systemImage: "rectangle.tophalf.inset.filled") }
        .pickerStyle(.menu)
        .accessibilityIdentifier("danmaku.area")
        DanmakuTextStylePickers(fontSize: $fontSize, opacity: $opacity)
        DanmakuMotionPickers()
    }
}

#if !os(tvOS)
/// Display controls beside the area in the player's menu, for whatever comments are playing.
struct DanmakuStylePickers: View {
    @Bindable var model: CatalogDanmakuModel

    var body: some View {
        DanmakuTextStylePickers(fontSize: $model.fontSize, opacity: $model.opacity)
        DanmakuMotionPickers()
    }
}
#endif

private struct DanmakuTextStylePickers: View {
    @Binding var fontSize: Double
    @Binding var opacity: Double

    var body: some View {
        Picker(selection: $fontSize) {
            ForEach(DanmakuStyle.fontSizes(including: fontSize), id: \.self) { Text(verbatim: "\(Int($0.rounded()))").tag($0) }
        } label: { Label(L10n.text("Text Size"), systemImage: "textformat.size") }
        .pickerStyle(.menu)
        .accessibilityIdentifier("danmaku.fontSize")
        Picker(selection: $opacity) {
            ForEach(DanmakuStyle.opacities(including: opacity), id: \.self) { Text(verbatim: "\(Int(($0 * 100).rounded()))%").tag($0) }
        } label: { Label(L10n.text("Opacity"), systemImage: "circle.lefthalf.filled") }
        .pickerStyle(.menu)
        .accessibilityIdentifier("danmaku.opacity")
    }
}

private struct DanmakuMotionPickers: View {
    @AppStorage(DanmakuStyle.speedKey) private var speed = DanmakuStyle.standardSpeed
    @AppStorage(DanmakuStyle.scrollKey) private var scroll = true
    @AppStorage(DanmakuStyle.topKey) private var top = true
    @AppStorage(DanmakuStyle.bottomKey) private var bottom = true
    @AppStorage(DanmakuFilter.colorsKey) private var colors = true

    var body: some View {
        Picker(selection: Binding(get: { DanmakuStyle.clampedSpeed(speed) }, set: { speed = $0 })) {
            ForEach(DanmakuStyle.speeds(including: speed), id: \.self) { Text(verbatim: "\($0.formatted(.number.precision(.fractionLength(0...2))))×").tag($0) }
        } label: { Label(L10n.text("Scroll Speed"), systemImage: "speedometer") }
        .pickerStyle(.menu)
        .accessibilityIdentifier("danmaku.speed")
        Toggle(L10n.text("Scrolling Comments"), isOn: $scroll).settingsSwitch().accessibilityIdentifier("danmaku.scroll")
        Toggle(L10n.text("Top Comments"), isOn: $top).settingsSwitch().accessibilityIdentifier("danmaku.top")
        Toggle(L10n.text("Bottom Comments"), isOn: $bottom).settingsSwitch().accessibilityIdentifier("danmaku.bottom")
        Toggle(L10n.text("Colored Comments"), isOn: $colors).settingsSwitch().accessibilityIdentifier("danmaku.colors")
    }
}
#endif

final class DanmakuEngine: @unchecked Sendable {
    struct Sprite { let image: CGImage; let frame: CGRect }
    private struct Active { let placement: DanmakuLayout.Placement; let image: CGImage; let size: CGSize }
    private let lock = NSLock()
    private var comments: [Danmaku] = []
    private var revision = ""
    private var layout: DanmakuLayout?
    private var size = CGSize.zero
    private var area = DanmakuArea.standard
    private var textScale = 1.0
    private var speed = DanmakuStyle.standardSpeed
    private var scroll = true, top = true, bottom = true
    private var fontSize: CGFloat = 24
    private var next = 0
    private var active: [Active] = []
    private var lastTime = -1.0
    /// Rendered text, reused: busy tracks repeat the same few words, and drawing text is the costly part.
    private var images: [String: CGImage] = [:]
    /// Dense tracks (Dandanplay merges several sites, up to 30,000 comments) would otherwise measure and draw
    /// dozens of comments in one frame and stall it; the rest wait a frame, and those a second late are dropped.
    private static let perFrame = 4, onScreen = 150

    func load(_ comments: [Danmaku], revision: String = "") {
        lock.withLock {
            // Live comments only grow at the end: keep the layout and what is already on screen.
            // A new track or time offset supplies a new revision even when its first comment is unchanged.
            if revision == self.revision, !self.comments.isEmpty, comments.count > self.comments.count,
               comments.first == self.comments.first, comments[self.comments.count - 1] == self.comments.last {
                self.comments = comments; return
            }
            self.comments = comments; self.revision = revision; layout = nil
        }
    }

    /// The player's time-jump notification catches small seeks that look like ordinary frame advances.
    func reset() { lock.withLock { layout = nil } }

    func frame(time: Double, size: CGSize, scale: CGFloat, area: DanmakuArea = .standard, textScale: Double = 1,
               speed: Double = DanmakuStyle.standardSpeed, scroll: Bool = true, top: Bool = true, bottom: Bool = true) -> [Sprite] {
        lock.withLock {
            guard time.isFinite, !comments.isEmpty, size.width > 0, size.height > 0 else { return [] }
            let speed = DanmakuStyle.clampedSpeed(speed)
            // Changes restart at the player's current time; past comments never replay with a new style.
            // Moving back more than a moment, or a large forward jump between frames, also clears the old placements; the
            // player's clock can step back a few milliseconds after a stall or a rate change, and seeks reset it anyway.
            let restarted = layout == nil || size != self.size || area != self.area || textScale != self.textScale
                || speed != self.speed || scroll != self.scroll || top != self.top || bottom != self.bottom
                || time < lastTime - 0.3 || time > lastTime + 2
            if restarted {
                restart(at: time, size: size, area: area, textScale: textScale, speed: speed, scroll: scroll, top: top, bottom: bottom)
            }
            // Repeated paused frames draw the same placements without draining a dense track's queue.
            let advances = restarted || time > lastTime
            if !advances, next < comments.count, comments[next].time <= time {
                // Discard the rest of a burst while paused, so resuming cannot replay that backlog.
                next = comments.partitioningIndex { $0.time > time }
            }
            lastTime = time
            var budget = Self.perFrame
            while advances, next < comments.count, comments[next].time <= time {
                let comment = comments[next]
                let shown: Bool
                switch comment.position {
                case .scroll: shown = scroll
                case .top: shown = top
                case .bottom: shown = bottom
                }
                // Filtering precedes measurement, drawing and the frame budget, so hidden types reserve no lanes.
                // Comments passed over (a stall, a skipped frame, a burst) are not shown late.
                guard shown, time - comment.time < 1, active.count < Self.onScreen, var layout else { next += 1; continue }
                guard budget > 0 else { break }
                budget -= 1; next += 1
                let font = fontSize * comment.scale
                let width = DanmakuText.width(comment.text, size: font)
                // Placed at `time`, not the comment's own time, so a comment that waited a frame doesn't start off-screen.
                guard let placement = layout.place(comment, width: width, at: time),
                      let image = image(comment, size: font, scale: scale) else { self.layout = layout; continue }
                self.layout = layout
                active.append(Active(placement: placement, image: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)))
            }
            guard let layout else { return [] }
            active.removeAll { time - $0.placement.start > layout.duration($0.placement) }
            let lane = layout.laneHeight
            let top = size.height * 0.04
            // Bottom comments rest at the foot of the picture, or of the area when it stops above the lower quarter.
            // A few counted lines have no foot apart from their rows, which bottom comments share with top ones.
            let bottom = area.share < DanmakuArea.threeQuarters.share ? top + max(lane, size.height * 0.96 * area.share) : size.height * 0.92
            return active.map { item in
                let placement = item.placement
                let x: Double, y: Double
                switch placement.comment.position {
                case .scroll: x = layout.width - (time - placement.start) * placement.speed; y = top + Double(placement.lane) * lane
                case .bottom where !layout.bottomSharesTop:
                    x = (layout.width - item.size.width) / 2; y = bottom - Double(placement.lane + 1) * lane
                case .top, .bottom: x = (layout.width - item.size.width) / 2; y = top + Double(placement.lane) * lane
                }
                return Sprite(image: item.image, frame: CGRect(x: x, y: y + (lane - item.size.height) / 2, width: item.size.width, height: item.size.height))
            }
        }
    }

    /// About 43pt on a 1080p TV, 22pt in a small Mac window. From the shorter side: an upright iPhone's full-screen
    /// player is tall and narrow, and its height made the text twice the size it is when the phone is turned.
    /// The chosen text size scales that, and the lanes with it, so larger comments don't overlap.
    static func fontSize(in size: CGSize, textScale: Double) -> CGFloat {
        min(44, max(15, min(size.width, size.height) * 0.04)) * textScale
    }

    /// The part of a picture `size` big that comments use in `area`: from just under the top edge down through its
    /// rows. Settings › Danmaku outlines it on the preview.
    static func areaFrame(in size: CGSize, area: DanmakuArea, textScale: Double) -> CGRect {
        let lane = fontSize(in: size, textScale: textScale) * 1.35, top = size.height * 0.04, height = size.height * 0.96
        let rows = area.lines ?? max(1, Int(height * area.share / lane))
        return CGRect(x: 0, y: top, width: size.width, height: min(height, CGFloat(rows) * lane))
    }

    private func image(_ comment: Danmaku, size: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(comment.color):\(size):\(scale):\(comment.text)"
        if let image = images[key] { return image }
        guard let image = DanmakuText.image(comment.text, color: comment.color, size: size, scale: scale) else { return nil }
        if images.count >= 400 { images.removeAll(keepingCapacity: true) }
        images[key] = image
        return image
    }

    private func restart(at time: Double, size: CGSize, area: DanmakuArea, textScale: Double,
                         speed: Double, scroll: Bool, top: Bool, bottom: Bool) {
        self.size = size; self.area = area; self.textScale = textScale
        self.speed = speed; self.scroll = scroll; self.top = top; self.bottom = bottom
        fontSize = Self.fontSize(in: size, textScale: textScale)
        layout = DanmakuLayout(width: size.width, height: size.height * 0.96, laneHeight: fontSize * 1.35, scrollArea: area.share,
                               lines: area.lines, scrollDuration: 9 * DanmakuStyle.scrollDurationMultiplier(speed))
        active = []
        var low = 0, high = comments.count
        while low < high { let mid = (low + high) / 2; if comments[mid].time < time { low = mid + 1 } else { high = mid } }
        next = low
    }
}

/// Comment text as an image: semibold system type with a thin contrasting outline, as Bilibili draws it.
enum DanmakuText {
    // NSCache is thread-safe; comments are drawn on the main thread anyway.
    nonisolated(unsafe) private static let fonts = NSCache<NSNumber, CTFont>()
    /// Creating the font is far slower than laying out a line, and every comment is measured: keep one per size.
    private static func font(_ size: CGFloat) -> CTFont {
        if let font = fonts.object(forKey: size as NSNumber) { return font }
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        fonts.setObject(font, forKey: size as NSNumber)
        return font
    }
    private static func line(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    private static let padding: CGFloat = 3

    static func width(_ text: String, size: CGFloat) -> Double {
        Double(CTLineGetTypographicBounds(line(text, [.init(kCTFontAttributeName as String): font(size)]), nil, nil, nil)) + Double(padding * 2)
    }

    static func image(_ text: String, color: UInt32, size: CGFloat, scale: CGFloat) -> CGImage? {
        let font = font(size)
        let red = CGFloat(color >> 16 & 0xFF) / 255, green = CGFloat(color >> 8 & 0xFF) / 255, blue = CGFloat(color & 0xFF) / 255
        // Dark comments get a light outline so they stay readable.
        let dark = 0.299 * red + 0.587 * green + 0.114 * blue < 0.25
        let fill = line(text, [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)])
        let outline = line(text, [.init(kCTFontAttributeName as String): font, .init(kCTStrokeWidthAttributeName as String): 6,
                                  .init(kCTStrokeColorAttributeName as String): CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.8 : 0.7)])
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(fill, &ascent, &descent, nil)
        let pixelsWide = Int(((width + padding * 2) * scale).rounded(.up)), pixelsHigh = Int(((ascent + descent + padding * 2) * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setLineJoin(.round)
        for drawn in [outline, fill] {
            context.textPosition = CGPoint(x: padding, y: padding + descent)
            CTLineDraw(drawn, context)
        }
        return context.makeImage()
    }
}

/// Every comment in time order, following the video. Choosing one plays from just before it.
/// On iPhone and Mac: a dark sheet with the comment count, a density strip of the whole episode
/// (tap it to jump), a search field, and rows marked with each comment's own colour. A playhead line
/// sits among the rows at the current moment, comments still to come are dimmed, and the list keeps up
/// with playback until you scroll it yourself.
struct DanmakuListView: View {
    let player: AVPlayer
    let comments: [Danmaku]
    var chosen: () -> Void = {}
    @State private var query = ""
    @State private var now: Double = 0
    @State private var following = true
    @State private var anchor: Int?
    private var shown: [(offset: Int, element: Danmaku)] {
        let all = Array(comments.enumerated())
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? all : all.filter { $0.element.text.localizedCaseInsensitiveContains(text) }
    }

    #if os(tvOS)
    /// The rows that exist: a page around the current moment, grown a page at a time at either end. A lazy stack
    /// alone still kept an identity for every comment (thousands in a busy episode) and, to open at the current
    /// moment, sized every row above it.
    @State private var window: Range<Int> = 0..<0
    /// Rows are added above only once the list has opened at the current moment.
    @State private var placed = false
    private static let page = 100

    var body: some View {
        ScrollViewReader { proxy in
            // Not a List: tvOS puts a square focus background behind list cells. Not glass rows either: the list sits
            // over the playing video and its moving comments, so a glass row blurred a changing picture on every frame
            // and every press of the remote lagged. A plain white plate, as in the TV's own lists.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(window, id: \.self) { index in
                        Button { jump(to: comments[index].time) } label: { tvRow(comments[index]) }
                            .buttonStyle(TVDanmakuRowStyle())
                            .id(index)
                            .onAppear { grow(reaching: index, proxy) }
                    }
                }
                .padding(.horizontal, 40).padding(.vertical, 24)
            }
            // Readable over a bright picture.
            .background(.black.opacity(0.55))
            // A TV scroll view draws its rows past its edges; these would run outside the panel.
            .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .onAppear {
                let now = player.currentTime().seconds
                let start = now.isFinite ? comments.firstIndex { $0.time >= now - 1 } ?? max(0, comments.count - 1) : 0
                window = max(0, start - 20)..<min(comments.count, start + Self.page)
                Task { @MainActor in
                    proxy.scrollTo(start, anchor: .top)
                    placed = true
                }
            }
        }
    }

    private func grow(reaching index: Int, _ proxy: ScrollViewProxy) {
        if index == window.upperBound - 1, window.upperBound < comments.count {
            window = window.lowerBound..<min(comments.count, window.upperBound + Self.page)
        } else if placed, index == window.lowerBound, window.lowerBound > 0 {
            // Rows added above push the ones shown down: keep the first one where it was.
            let first = window.lowerBound
            window = max(0, first - Self.page)..<window.upperBound
            Task { @MainActor in proxy.scrollTo(first, anchor: .top) }
        }
    }

    private struct TVDanmakuRowStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
        private struct Row: View {
            let configuration: ButtonStyleConfiguration
            @Environment(\.isFocused) private var focused
            var body: some View {
                configuration.label
                    .foregroundStyle(focused ? Color.black : Color.white)
                    .padding(.horizontal, 28).padding(.vertical, 10)
                    .background { if focused { Capsule().fill(.white) } }
                    .scaleEffect(configuration.isPressed ? 0.99 : 1)
            }
        }
    }

    private func tvRow(_ comment: Danmaku) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Self.clock(comment.time)).monospacedDigit().foregroundStyle(.secondary)
            Circle().fill(Self.tint(comment.color)).frame(width: 10, height: 10)
            Text(comment.text).lineLimit(2).foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
    #else
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 22)
            DanmakuDensity(bins: density, progress: duration > 0 ? now / duration : 0) { fraction in
                following = true
                jump(to: fraction * duration, dismiss: false)
            }
            .padding(.horizontal, 20).padding(.top, 16)
            search.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            list
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .task {
            // The playhead, twice a second: highlights what is on screen and keeps the list with it.
            while !Task.isCancelled {
                let time = player.currentTime().seconds
                if time.isFinite { now = time }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Danmaku")).font(.title2.weight(.bold))
                Text(L10n.text("%d comments", comments.count)).font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button(action: chosen) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.14), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Close"))
            #if os(macOS)
            .keyboardShortcut(.cancelAction)
            #endif
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
            TextField(L10n.text("Filter comments"), text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Clear"))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.white.opacity(0.1), in: Capsule())
    }

    private var list: some View {
        let items = shown
        let playhead = query.isEmpty ? nowIndex : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.offset) { item in
                        if item.offset == playhead { nowLine }
                        Button { jump(to: item.element.time) } label: { row(item.element, upcoming: item.element.time > now + 0.5) }
                            .buttonStyle(DanmakuRowStyle())
                            .id(item.offset)
                    }
                    if playhead == comments.count { nowLine }
                }
                .padding(.horizontal, 10).padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            // Rows fade out under the search field instead of being cut off.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 16)
                    Color.black
                }
            }
            // Scrolling by hand stops following the video until “Back to Now”.
            .onScrollByHand { following = false }
            .overlay {
                if items.isEmpty {
                    EmptyResults.search(query)
                }
            }
            .overlay(alignment: .bottom) {
                if !following, query.isEmpty {
                    Button {
                        following = true
                        follow(proxy, animated: true)
                    } label: {
                        Label(L10n.text("Back to Now"), systemImage: "arrow.down.to.line")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.white, in: Capsule())
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: following)
            .onAppear { follow(proxy, animated: false) }
            .onChange(of: now) { _, _ in if following { follow(proxy, animated: true) } }
            .onChange(of: query) { _, text in if text.isEmpty { follow(proxy, animated: false) } }
        }
    }

    private func row(_ comment: Danmaku, upcoming: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.clock(comment.time))
                .font(.footnote.monospacedDigit().weight(.medium))
                .foregroundStyle(.white.opacity(0.45))
                .frame(minWidth: 44, alignment: .leading)
                .padding(.top, 2)
            RoundedRectangle(cornerRadius: 1.5).fill(Self.tint(comment.color)).frame(width: 3)
            Text(comment.text)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .opacity(upcoming ? 0.42 : 1)
        .contentShape(Rectangle())
    }

    private var nowLine: some View { DanmakuNowLine(time: now) }

    /// Where the playhead falls among the comments: the first one still to come.
    private var nowIndex: Int { comments.partitioningIndex { $0.time > now + 0.5 } }

    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        guard query.isEmpty, !comments.isEmpty else { return }
        // The row just after the playhead line, a third of the way down: recent comments above, the next few below.
        let target = min(comments.count - 1, nowIndex)
        guard target != anchor || !animated else { return }
        anchor = target
        if animated { withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.4)) } }
        else { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.4)) }
    }

    private var duration: Double {
        let length = player.currentItem?.duration.seconds ?? .nan
        return length.isFinite && length > 0 ? length : (comments.last?.time ?? 0) + 1
    }

    /// Comments per stretch of the episode, scaled to the busiest one.
    private var density: [Double] {
        let count = 64
        guard duration > 0, !comments.isEmpty else { return Array(repeating: 0, count: count) }
        var bins = Array(repeating: 0.0, count: count)
        for comment in comments { bins[min(count - 1, max(0, Int(comment.time / duration * Double(count))))] += 1 }
        let peak = bins.max() ?? 1
        return bins.map { ($0 / max(1, peak)).squareRoot() }
    }
    #endif

    static func clock(_ time: Double) -> String {
        Duration.seconds(Int(time)).formatted(.time(pattern: time >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// The comment's own colour; the usual white as a quiet grey so coloured ones stand out.
    static func tint(_ color: UInt32) -> Color {
        let red = Double(color >> 16 & 0xFF) / 255, green = Double(color >> 8 & 0xFF) / 255, blue = Double(color & 0xFF) / 255
        return min(red, green, blue) > 0.88 ? Color.white.opacity(0.28) : Color(red: red, green: green, blue: blue)
    }

    private func jump(to time: Double, dismiss: Bool = true) {
        player.seek(to: CMTime(seconds: max(0, time - 1), preferredTimescale: 600))
        if dismiss {
            player.play()
            chosen()
        }
    }
}

#if !os(tvOS)
/// Where the comments gather across the episode, with the playhead; tap or drag to jump there.
private struct DanmakuDensity: View {
    let bins: [Double]
    let progress: Double
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(bins.indices, id: \.self) { index in
                    let played = (Double(index) + 0.5) / Double(bins.count) <= progress
                    Capsule()
                        .fill(played ? Brand.cyan : Color.white.opacity(0.22))
                        .frame(height: max(3, bins[index] * height))
                }
            }
            .frame(width: width, height: height, alignment: .bottom)
            .overlay(alignment: .bottomLeading) {
                Capsule().fill(.white).frame(width: 2, height: height + 6)
                    .offset(x: min(width - 2, max(0, progress * width - 1)), y: 3)
                    .shadow(color: .black.opacity(0.4), radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in seek(min(1, max(0, value.location.x / width))) })
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("Danmaku"))
        .accessibilityValue("\(Int(progress * 100))%")
    }
}

/// The playhead among the comments: everything above it has been on screen.
private struct DanmakuNowLine: View {
    let time: Double
    var body: some View {
        HStack(spacing: 10) {
            Text(DanmakuListView.clock(time))
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Brand.cyan, in: Capsule())
            Capsule().fill(Brand.cyan).frame(height: 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

private struct DanmakuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    /// The danmaku list as a sheet over the player: dark, half height first, pulled up for more.
    func danmakuListPresentation() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.ultraThinMaterial)
            .presentationCornerRadius(28)
            .preferredColorScheme(.dark)
        #else
        self.frame(width: 520, height: 640)
            .background(Color(white: 0.09))
            .preferredColorScheme(.dark)
        #endif
    }
}
#endif

private extension Array {
    /// The first index where `belongs` becomes true, for an array already sorted by it.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if belongs(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
