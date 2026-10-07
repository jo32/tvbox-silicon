import SwiftUI
import ImageIO
import TVCore

extension View {
    @ViewBuilder func catalogSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(tvOS)
        safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass").font(.system(size: 26)).foregroundStyle(.secondary)
                TextField(prompt, text: text).submitLabel(.search).font(.system(size: 28))
            }
            .padding(20).background(TVStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, Layout.gutter).padding(.bottom, 24)
            .background(TVStyle.background)
        }
        #elseif os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
        #else
        searchable(text: text, prompt: Text(prompt))
        #endif
    }
}

// Content-first surfaces: neutral backgrounds, quiet controls, and strong selection contrast.

/// Warm palette: an apricot accent on espresso and cream canvases.
enum Brand {
    /// Apricot on dark canvases; a deeper burnt orange on light ones so text and links keep contrast.
    /// A real hue, not `.primary`: as a tint, `.primary` turned prominent buttons white-on-white.
    static let accent = Color(light: Color(red: 0.76, green: 0.33, blue: 0.06), dark: Color(red: 1.0, green: 0.62, blue: 0.30))
    /// Label colour on an accent fill.
    static let onAccent = Color(light: .white, dark: Color(red: 0.20, green: 0.09, blue: 0.02))
    static let terracotta = Color(red: 0.86, green: 0.40, blue: 0.30)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.30)
    static let rose = Color(red: 0.95, green: 0.38, blue: 0.42)
    /// Yingxia's own credit. Third-party notices keep their authors' copyright lines unchanged.
    static let copyright = "© 2026 getmegaportal.com"
    static let website = URL(string: "https://www.getmegaportal.com")!
}

enum Layout {
    #if os(tvOS)
    static let gutter: CGFloat = 64, posterMin: CGFloat = 240, cardMin: CGFloat = 480, tileMin: CGFloat = 340
    static let heroTitle: CGFloat = 68, detailPoster: CGFloat = 300, episodeMin: CGFloat = 200
    #elseif os(macOS)
    static let gutter: CGFloat = 24, posterMin: CGFloat = 174, cardMin: CGFloat = 280, tileMin: CGFloat = 220
    static let heroTitle: CGFloat = 48, detailPoster: CGFloat = 210, episodeMin: CGFloat = 120
    #else
    static let gutter: CGFloat = 16, posterMin: CGFloat = 104, cardMin: CGFloat = 280, tileMin: CGFloat = 160
    static let heroTitle: CGFloat = 34, detailPoster: CGFloat = 130, episodeMin: CGFloat = 90
    #endif
    /// Poster grid gaps: three columns on a phone need tighter spacing than a TV wall.
    #if os(tvOS)
    static let gridSpacing: CGFloat = 40, gridRowSpacing: CGFloat = 48
    #elseif os(macOS)
    static let gridSpacing: CGFloat = 18, gridRowSpacing: CGFloat = 22
    #else
    static let gridSpacing: CGFloat = 10, gridRowSpacing: CGFloat = 18
    #endif
    static var posterColumns: [GridItem] {
        [GridItem(.adaptive(minimum: posterMin), spacing: gridSpacing, alignment: .top)]
    }
    #if os(tvOS)
    static let maxWidth: CGFloat = 1800
    static let settingsWidth: CGFloat = 1200
    #else
    static let maxWidth: CGFloat = 1240
    static let settingsWidth: CGFloat = 760
    #endif
}

/// Shared opaque surfaces keep content and controls legible in both appearances.
struct Backdrop: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // Flat warm canvas (espresso / cream); artwork supplies the rest of the colour.
        (scheme == .dark ? Color(red: 0.086, green: 0.063, blue: 0.047) : Color(red: 0.98, green: 0.965, blue: 0.94)).ignoresSafeArea()
    }
}

struct Surface: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color(red: 0.17, green: 0.13, blue: 0.10) : Color(red: 0.955, green: 0.93, blue: 0.895))
    }
}

extension View {
    /// Fills the screen first: applied to a bare `ContentUnavailableView` the backdrop would
    /// otherwise shrink to that view and show as a box.
    func screenBackdrop() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity).background { Backdrop() }
    }

    @ViewBuilder func screenTitle(_ title: String, width: CGFloat = Layout.maxWidth) -> some View {
        #if os(tvOS)
        navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(title).font(.system(size: 38, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: width, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Layout.gutter).padding(.top, 16).padding(.bottom, 12)
                    .background(TVStyle.background)
            }
        #else
        navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        #endif
    }

    @ViewBuilder func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    @ViewBuilder func pageContainer() -> some View {
        #if os(tvOS)
        padding(.horizontal, Layout.gutter).padding(.vertical, 28)
            .frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        #else
        padding(Layout.gutter).frame(maxWidth: Layout.maxWidth).frame(maxWidth: .infinity)
        #endif
    }

    func glassPanel(cornerRadius: CGFloat = 16, tint: Color? = nil) -> some View {
        contentPanel(cornerRadius: min(cornerRadius, 16))
    }

    func contentPanel(cornerRadius: CGFloat = 12) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: max(cornerRadius, 14), style: .continuous))
    }

    @ViewBuilder func cardButton() -> some View {
        #if os(tvOS)
        buttonStyle(TVCardStyle())
        #else
        buttonStyle(LiftButtonStyle())
        #endif
    }
}

/// Pointer-aware press and hover feedback for content cards.
struct LiftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { LiftBody(configuration: configuration) }
    struct LiftBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.72 : (hovering ? 0.88 : 1))
                .animation(.smooth(duration: 0.22), value: hovering)
                .animation(.smooth(duration: 0.15), value: configuration.isPressed)
                #if !os(tvOS)
                .onHover { hovering = $0 }
                #endif
        }
    }
}

struct IconTile: View {
    let symbol: String
    var tint: Color = Brand.accent
    var size: CGFloat = 44
    var body: some View {
        #if os(tvOS)
        let size = max(size, 56)
        #endif
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

struct Pill: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular.tint(tint.opacity(0.15)), in: Capsule())
    }
}

/// Multi-line notices are separate from short metadata badges.
struct StatusNotice: View {
    let text: String
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = Brand.amber
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#if !os(tvOS)
private struct FilterChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? Brand.onAccent : .primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .glassEffect(selected ? .regular.tint(Brand.accent).interactive() : .regular.interactive(), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
#endif

/// Neutral filters reserve high contrast for the current selection.
struct Chip: View {
    let title: String
    var selected = false
    var fill = false
    let action: () -> Void
    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 5) {
                if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                Text(title).lineLimit(1)
            }.padding(.horizontal, 4).frame(maxWidth: fill ? .infinity : nil)
        }.accessibilityAddTraits(selected ? [.isSelected] : [])
        #if os(tvOS)
        button.controlButton(prominent: selected)
        #else
        button.buttonStyle(FilterChipStyle(selected: selected))
        #endif
    }
}

/// Two-line card title that always takes two lines of height (so cards in a grid row match)
/// but centres a one-line title instead of leaving a gap under it.
struct CardTitle: View {
    let text: String
    var body: some View {
        Text(text).lineLimit(2, reservesSpace: true).hidden()
            .overlay(alignment: .leading) {
                Text(text).lineLimit(2).foregroundStyle(.primary)
            }
            .font(.headline).multilineTextAlignment(.leading)
            .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

struct SectionHeader: View {
    private var sectionFont: Font {
        #if os(tvOS)
        .system(size: 30, weight: .semibold)
        #else
        .title2.weight(.bold)
        #endif
    }
    let title: String
    var action: (() -> Void)?
    var body: some View {
        if let action {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title).font(sectionFont)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    #if !os(tvOS)
                    Spacer(minLength: 0)
                    #endif
                }.contentShape(Rectangle()).foregroundStyle(.primary)
            }.buttonStyle(.plain)
            #if os(tvOS)
            // The focus highlight hugs the title instead of spanning the screen.
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        } else {
            Text(title).font(sectionFont)
        }
    }
}

private final class PosterBitmap: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private actor PosterLoader {
    static let shared = PosterLoader()
    private let cache = NSCache<NSString, PosterBitmap>()
    private var pending: [PosterResource: Task<PosterBitmap, Error>] = [:]
    init() { cache.countLimit = 96; cache.totalCostLimit = 48 * 1024 * 1024 }

    func load(_ resource: PosterResource) async throws -> PosterBitmap {
        let key = (resource.url.absoluteString + resource.headers.sorted { $0.key < $1.key }.map { "\n\($0.key):\($0.value)" }.joined()) as NSString
        if let image = cache.object(forKey: key) { return image }
        if let task = pending[resource] { return try await task.value }
        let task = Task {
            let (data, _) = try await HTTPClient().get(resource.url, headers: resource.headers)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 720,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                throw NSError(domain: "PosterLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid poster image"])
            }
            return PosterBitmap(image)
        }
        pending[resource] = task
        do {
            let bitmap = try await task.value
            pending[resource] = nil
            cache.setObject(bitmap, forKey: key, cost: bitmap.image.bytesPerRow * bitmap.image.height)
            return bitmap
        } catch { pending[resource] = nil; throw error }
    }
}

struct PosterImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    @State private var bitmap: PosterBitmap?
    private var resource: PosterResource? { url.map { PosterResource(url: $0, headers: headers) } }
    var body: some View {
        ZStack {
            Color(white: 0.20)
            Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.55))
            if let bitmap { Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill() }
        }
        .task(id: resource) {
            bitmap = nil
            guard let resource else { return }
            if let image = try? await PosterLoader.shared.load(resource), !Task.isCancelled { bitmap = image }
        }
    }
}

struct PosterCard: View {
    let name: String
    let poster: URL?
    let headers: [String: String]
    let remarks: String
    init(video: Video) {
        name = video.name; poster = video.poster; headers = video.posterHeaders; remarks = video.remarks
    }
    init(recommendation: Recommendation) {
        name = recommendation.name; poster = recommendation.poster?.url
        headers = recommendation.poster?.headers ?? [:]; remarks = recommendation.remarks
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { PosterImage(url: poster, headers: headers) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if !remarks.isEmpty {
                        Text(remarks).font(.caption2.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                            .glassEffect(.regular.tint(.black.opacity(0.45)), in: Capsule()).padding(8)
                    }
                }
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
        }
    }
}

extension View {
    /// Text selection where the platform supports it (not tvOS).
    @ViewBuilder func selectable() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}

// MARK: Skeleton loading

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content.overlay {
            if !reduceMotion {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .white.opacity(0.20), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: -proxy.size.width * 0.6 + phase * proxy.size.width * 1.6)
                }
                .allowsHitTesting(false)
            }
        }
        .onAppear { withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.09))
            .modifier(Shimmer())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct PosterSkeletonGrid: View {
    var count = 12
    var body: some View {
        LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
            ForEach(0..<count, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).overlay { SkeletonBlock(cornerRadius: 20) }
                    SkeletonBlock(cornerRadius: 6).frame(height: 14)
                    SkeletonBlock(cornerRadius: 6).frame(width: 70, height: 12)
                }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("Loading…"))
    }
}

struct ChannelSkeletonGrid: View {
    var count = 12
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 12)], spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 14) {
                    SkeletonBlock(cornerRadius: 14).frame(width: 50, height: 50)
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(cornerRadius: 6).frame(maxWidth: 170).frame(height: 14)
                        SkeletonBlock(cornerRadius: 6).frame(width: 90, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12).contentPanel()
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("Loading channels…"))
    }
}

struct ChipSkeletonRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([64, 88, 72, 100, 76, 84], id: \.self) { width in
                SkeletonBlock(cornerRadius: 18).frame(width: CGFloat(width), height: 36)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).accessibilityHidden(true)
    }
}

extension View {
    /// While a page is still loading it may have no focusable control. tvOS then sends
    /// the Menu/Back press to the system, which leaves the app instead of going back.
    @ViewBuilder func loadingFocus(onExit: @escaping () -> Void) -> some View {
        #if os(tvOS)
        focusable().onExitCommand(perform: onExit)
        #else
        self
        #endif
    }
}

struct DetailSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                SkeletonBlock(cornerRadius: 6).frame(height: 14)
                SkeletonBlock(cornerRadius: 6).frame(height: 14)
                SkeletonBlock(cornerRadius: 6).frame(maxWidth: 260).frame(height: 14)
            }
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBlock(cornerRadius: 6).frame(width: 110, height: 18)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.episodeMin), spacing: 10)], spacing: 10) {
                    ForEach(0..<10, id: \.self) { _ in SkeletonBlock(cornerRadius: 20).frame(height: 40) }
                }
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.text("Loading details…"))
    }
}

/// What a loading card shows. `reason` explains a slow load and appears after `LoadingCard.patience`.
struct LoadingProgress {
    var title: String
    var detail: String? = nil
    var fraction: Double? = nil
    var reason: String? = nil
}

extension LoadingProgress {
    /// A source request: the plugin's live stage and the server it waits on, or the site's server.
    static func source(_ site: Site, origin: URL, title: String) -> LoadingProgress {
        if site.runtime == .jar {
            guard let state = PluginPreparation.snapshot(site: site, origin: origin) else { return LoadingProgress(title: title) }
            return LoadingProgress(title: state.stage == .loading ? title : state.stage.title,
                                   detail: state.detail, fraction: state.fraction, reason: state.reason)
        }
        return server(URL(string: site.api)?.host(), title: title)
    }

    /// A plain request to one server.
    static func server(_ host: String?, title: String) -> LoadingProgress {
        guard let host, !host.isEmpty else { return LoadingProgress(title: title) }
        return LoadingProgress(title: title, detail: L10n.text("Waiting for %@", host),
                               reason: L10n.text("%@ is responding slowly. The server may be busy or far away; you can keep waiting or try another source.", host))
    }
}

/// Time since this view appeared, for inline waits too small for a `LoadingCard`.
struct ElapsedTime: View {
    @State private var started = Date()
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(Duration.seconds(max(0, Int(timeline.date.timeIntervalSince(started)))).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Every wait shows how long it has run; past `patience` seconds it also says why it is still
/// loading. A compact card in the page column, re-polled twice a second.
struct LoadingCard: View {
    static let patience: TimeInterval = 10
    /// Hides the card for waits shorter than this, such as the brief stall after every seek.
    var appearAfter: TimeInterval = 0
    let progress: () -> LoadingProgress
    @State private var started = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(started))
            if elapsed >= appearAfter {
                card(progress(), elapsed: Int(elapsed))
            }
        }
    }

    private func card(_ state: LoadingProgress, elapsed: Int) -> some View {
        let explains = Double(elapsed) >= Self.patience && state.reason != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.callout.weight(.semibold)).lineLimit(1)
                    if let detail = state.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 16)
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let fraction = state.fraction {
                ProgressView(value: fraction).progressViewStyle(.linear).tint(Brand.accent)
            }
            if explains, let reason = state.reason {
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: 620, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .animation(.smooth(duration: 0.25), value: state.title)
        .animation(.smooth(duration: 0.25), value: explains)
    }
}

/// Keeps recovery actions prominent while preserving diagnostics on demand.
struct ErrorStateCard: View {
    let title: String
    let message: String
    let details: String
    var retry: (() -> Void)?
    var goBack: (() -> Void)?
    var busy = false
    var backTitle = L10n.text("Back to sources")
    @State private var showsDetails = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "rectangle.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Brand.accent)
                .frame(width: 76, height: 76)
                .background(Brand.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 25))
                .overlay { RoundedRectangle(cornerRadius: 25).strokeBorder(Brand.accent.opacity(0.18)) }
                .accessibilityHidden(true)
            VStack(spacing: 10) {
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                Text(message).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions }
                VStack(spacing: 12) { actions }
            }
            .controlSize(.large)
            VStack(spacing: 14) {
                Divider().overlay(Color.primary.opacity(0.04))
                Button {
                    showsDetails.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.text(showsDetails ? "Hide details" : "Show details"))
                        Image(systemName: showsDetails ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 6).contentShape(Rectangle())
                }
                #if os(tvOS)
                .controlButton()
                #else
                .buttonStyle(.plain)
                #endif
                if showsDetails {
                    ScrollView {
                        Text(details).font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true).selectable().padding(14)
                    }
                    .frame(height: detailsHeight)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(28)
        .frame(maxWidth: recoveryWidth)
        .contentPanel(cornerRadius: 28)
        .frame(maxWidth: .infinity)
        .onChange(of: details) { showsDetails = false }
    }

    private var recoveryWidth: CGFloat {
        #if os(tvOS)
        900
        #else
        560
        #endif
    }
    private var detailsHeight: CGFloat {
        #if os(tvOS)
        240
        #else
        180
        #endif
    }

    @ViewBuilder private var actions: some View {
        if let retry {
            Button(action: retry) {
                Label(L10n.text("Retry"), systemImage: "arrow.clockwise").padding(.horizontal, 12)
            }
            .controlButton(prominent: true).tint(Brand.accent).disabled(busy)
        }
        if let goBack {
            Button(action: goBack) { Text(backTitle).padding(.horizontal, 8) }
                .controlButton().tint(.secondary)
        }
    }
}

#if os(tvOS)
enum TVStyle {
    static let background = Color(red: 0.086, green: 0.063, blue: 0.047)
    static let surface = Color(red: 0.18, green: 0.14, blue: 0.11)
    static let raised = Color(red: 0.25, green: 0.195, blue: 0.15)
}
private struct TVCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Card(configuration: configuration) }
    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        /// The focus plate bleeds into the grid gutter so the title gets inner padding
        /// without the card's layout size changing.
        private let inset: CGFloat = 14
        var body: some View {
            let plate = RoundedRectangle(cornerRadius: 10 + inset, style: .continuous)
            configuration.label
                .padding(inset)
                .background { plate.fill(TVStyle.raised.opacity(focused ? 1 : 0)) }
                .overlay { plate.strokeBorder(.white.opacity(focused ? 1 : 0), lineWidth: 3) }
                .padding(-inset)
                .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.02 : 1)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 12)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif

extension View {
    /// Solid, high-contrast controls. Glass styles take their fill from the tint, which made
    /// prominent labels vanish against a white fill.
    @ViewBuilder func controlButton(prominent: Bool = false) -> some View {
        #if os(tvOS)
        buttonStyle(TVControlStyle(prominent: prominent))
        #else
        buttonStyle(ContentControlStyle(prominent: prominent))
        #endif
    }
    @ViewBuilder func controlBackdrop() -> some View {
        #if os(tvOS)
        background(Color.clear.glassEffect(.regular, in: .rect))
        #else
        background(.bar)
        #endif
    }
}
#if os(tvOS)
private struct TVControlStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View { Control(configuration: configuration, prominent: prominent) }
    private struct Control: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? Color.black : prominent ? Brand.onAccent : Color.white)
                .padding(.horizontal, 24).padding(.vertical, 15)
                .frame(minHeight: 62)
                // Focus stays white, as everywhere on tvOS; the primary action wears the brand cyan.
                .background(focused ? Color.white : prominent ? Brand.accent : TVStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .opacity(enabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.02 : 1)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif

extension View {
    @ViewBuilder func tvDefaultControls() -> some View {
        #if os(tvOS)
        buttonStyle(TVControlStyle(prominent: false))
        #else
        self
        #endif
    }
}

#if !os(tvOS)
private struct ContentControlStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size == .large ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Brand.onAccent : Color.primary)
            .padding(.horizontal, size == .large ? 20 : 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            // Secondary fill is relative to the page so it stays visible on light and dark canvases.
            .background(prominent ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
    }
}
#endif

extension Color {
    /// A colour that follows the current light/dark appearance.
    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #endif
    }
}
