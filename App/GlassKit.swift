import SwiftUI
import ImageIO
import CoreImage
import TVCore

extension View {
    @ViewBuilder func catalogSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(tvOS)
        // The system search, as in the TV app and Global Search: a large search line over the keyboard row.
        // A text field of our own sat in a corner the remote could not reach from the content below.
        searchable(text: text, prompt: Text(prompt))
        #elseif os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text(prompt))
        #else
        searchable(text: text, prompt: Text(prompt))
        #endif
    }
}

/// A Liquid Glass recipe. On macOS 26, iOS 26 and tvOS it is real glass; on macOS 15 and iOS 17–18,
/// which have no glass, `glassSurface` draws a material with the same tint instead.
struct GlassStyle {
    var tint: Color?
    var isInteractive = false
    var isVisible = true
    static let regular = GlassStyle()
    static let identity = GlassStyle(isVisible: false)
    func tint(_ color: Color) -> GlassStyle { var style = self; style.tint = color; return style }
    func interactive() -> GlassStyle { var style = self; style.isInteractive = true; return style }
    @available(macOS 26, iOS 26, tvOS 26, *)
    var glass: Glass {
        guard isVisible else { return .identity }
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        return isInteractive ? glass.interactive() : glass
    }
}

/// `GlassEffectContainer` where it exists, so nearby glass shapes blend; a plain group before OS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder func glassSurface(_ style: GlassStyle = .regular, in shape: some Shape) -> some View {
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            glassEffect(style.glass, in: shape)
        } else if style.isVisible {
            background {
                shape.fill(.ultraThinMaterial).overlay { if let tint = style.tint { shape.fill(tint) } }
            }
        } else {
            self
        }
    }

    #if !os(tvOS)
    /// A bar pinned to the top that content scrolls under: a soft scroll edge on OS 26, a bar material before.
    @ViewBuilder func topBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        let bar = bar()
        if #available(macOS 26, iOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top).safeAreaBar(edge: .top, spacing: 0) { bar }
        } else {
            safeAreaInset(edge: .top, spacing: 0) { bar.background(.bar) }
        }
    }
    #endif

    #if os(iOS)
    @ViewBuilder func minimizesTabBarOnScroll() -> some View {
        if #available(iOS 26, *) { tabBarMinimizeBehavior(.onScrollDown) } else { self }
    }
    #endif
}

// iOS 17 stand-ins for iOS 18 APIs. macOS 15 and tvOS 26 always take the first branch.

extension View {
    /// Calls `action` when someone starts scrolling by hand. Before iOS 18 there is no scroll phase,
    /// so a drag on the scroll view stands in.
    @ViewBuilder func onScrollByHand(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollPhaseChange { _, phase in if phase == .interacting { action() } }
        } else {
            #if os(tvOS)
            self
            #else
            simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in action() })
            #endif
        }
    }

    /// `onScrollVisibilityChange`; before iOS 18 the visible share comes from the view's bounds
    /// against its scroll view's.
    @ViewBuilder func onScrolledIntoView(threshold: Double, _ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollVisibilityChange(threshold: threshold, action)
        } else {
            onGeometryChange(for: Bool.self) { geometry in
                let own = CGRect(origin: .zero, size: geometry.size)
                guard own.width * own.height > 0, let viewport = geometry.bounds(of: .scrollView) else { return false }
                let shown = own.intersection(viewport)
                return !shown.isNull && shown.width * shown.height >= own.width * own.height * threshold
            } action: { action($0) }
        }
    }

    /// The breathing symbol effect; iOS 17 has no breathe, so the symbol pulses instead.
    @ViewBuilder func breathingSymbol() -> some View {
        if #available(iOS 18, *) {
            symbolEffect(.breathe, options: .repeat(.periodic(delay: 2.5)))
        } else {
            symbolEffect(.pulse, options: .repeating.speed(0.4))
        }
    }
}

extension Color {
    /// `mix(with:by:)`; before iOS 18 a plain blend in sRGB.
    func blend(with other: Color, by fraction: Double) -> Color {
        if #available(iOS 18, *) { return mix(with: other, by: fraction) }
        let environment = EnvironmentValues()
        let from = resolve(in: environment), to = other.resolve(in: environment)
        // Resolved components are linear; blending gamma-encoded values looks closer to mix's perceptual default.
        func encoded(_ linear: Float) -> Double { Double(pow(max(0, linear), 1 / 2.2)) }
        func mixed(_ a: Float, _ b: Float) -> Double { encoded(a) + (encoded(b) - encoded(a)) * fraction }
        return Color(.sRGB, red: mixed(from.red, to.red), green: mixed(from.green, to.green), blue: mixed(from.blue, to.blue),
                     opacity: Double(from.opacity + (to.opacity - from.opacity) * Float(fraction)))
    }
}

// Content-first surfaces: neutral backgrounds, quiet controls, and strong selection contrast.

/// The icon's navy canvases with neutral controls: the active state is light on dark (dark on light),
/// never a hue, so it reads the same on Liquid Glass.
enum Brand {
    /// Selection, prominent actions and progress. A fixed grey rather than `.primary`: as a tint,
    /// `.primary` turned prominent buttons white-on-white. On Apple TV no button is filled with it,
    /// so it never sits beside the white focus.
    static let accent = Color(light: Color(white: 0.12), dark: Color(white: 0.92))
    /// Label colour on an accent fill.
    static let onAccent = Color(light: .white, dark: Color(white: 0.06))
    /// The icon's cyan, for decoration only (icon tiles, charts, artwork placeholders), not for state.
    static let cyan = Color(red: 0.30, green: 0.78, blue: 1.0)
    static let indigo = Color(red: 0.42, green: 0.50, blue: 1.0)
    static let teal = Color(red: 0.20, green: 0.84, blue: 0.80)
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
    /// Space between a page's sections, between a section header and its content, and between cards.
    /// The TV needs room for the focus lift, so a focused card never touches its neighbours.
    #if os(tvOS)
    static let sectionSpacing: CGFloat = 72, headerSpacing: CGFloat = 24, cardSpacing: CGFloat = 40
    #elseif os(macOS)
    static let sectionSpacing: CGFloat = 40, headerSpacing: CGFloat = 14, cardSpacing: CGFloat = 16
    #else
    static let sectionSpacing: CGFloat = 32, headerSpacing: CGFloat = 12, cardSpacing: CGFloat = 12
    #endif
    static var cardColumns: [GridItem] {
        [GridItem(.adaptive(minimum: cardMin), spacing: cardSpacing)]
    }
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
        // Flat canvas (the icon's navy / cool white); artwork supplies the rest of the colour.
        (scheme == .dark ? Color(red: 0.020, green: 0.035, blue: 0.090) : Color(red: 0.955, green: 0.965, blue: 0.985)).ignoresSafeArea()
    }
}

struct Surface: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color(red: 0.075, green: 0.105, blue: 0.19) : Color(red: 0.915, green: 0.935, blue: 0.965))
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

    /// A tab's root page: titled on iPhone, iPad and Mac, untitled on tvOS, where the tab bar already
    /// names the page and a second title under it only repeats it.
    @ViewBuilder func tabTitle(_ title: String) -> some View {
        #if os(tvOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        screenTitle(title)
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
        glassSurface(.regular, in: RoundedRectangle(cornerRadius: max(cornerRadius, 14), style: .continuous))
    }

    @ViewBuilder func cardButton() -> some View {
        #if os(tvOS)
        buttonStyle(TVCardStyle())
        #else
        buttonStyle(LiftButtonStyle())
        #endif
    }

    /// For cards that paint their own focus state (source cards).
    @ViewBuilder func tileButton() -> some View {
        #if os(tvOS)
        buttonStyle(TVTileStyle())
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
                #if os(macOS)
                .pointerStyle(.link)
                #endif
        }
    }
}

struct IconTile: View {
    let symbol: String
    var tint: Color = Brand.cyan
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
        .glassSurface(.regular.tint(tint.opacity(0.15)), in: Capsule())
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
        .glassSurface(.regular.tint(tint.opacity(0.12)), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .glassSurface(selected ? .regular.tint(Brand.accent).interactive() : .regular.interactive(), in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
#endif

#if os(tvOS)
/// Liquid Glass filter chip: clear glass at rest, a lighter glass for the selection, and a bright
/// white glass lift on focus, as in the TV app.
private struct TVChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration, selected: selected) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 22).padding(.vertical, 13)
                .frame(minHeight: 58)
                .glassSurface(glass, in: Capsule())
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.06 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 16, y: 10)
                .animation(.easeOut(duration: 0.18), value: focused)
                .animation(.smooth(duration: 0.2), value: selected)
        }
        private var glass: GlassStyle {
            if focused { return .regular.tint(.white.opacity(0.9)).interactive() }
            if selected { return .regular.tint(.white.opacity(0.28)).interactive() }
            return .regular.interactive()
        }
    }
}

extension View {
    /// A Liquid Glass capsule that turns white on focus, like the chips.
    func glassPill() -> some View { buttonStyle(TVChipStyle(selected: false)) }
}

/// The query as a glass pill after a magnifying glass, as in the TV app's search. The remote's
/// keyboard has no return key, so this is what runs a typed search.
struct SearchQueryButton: View {
    let query: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Label(query, systemImage: "magnifyingglass").lineLimit(1) }
            .glassPill()
            .accessibilityLabel(L10n.text("Search %@", query))
    }
}
#endif

/// Neutral filters reserve high contrast for the current selection.
/// Set by `ScrollStrip` while the user drags it, so the chip under the pointer ignores the mouse-up.
@MainActor final class StripDrag { var active = false }
extension EnvironmentValues { @Entry var stripDrag: StripDrag? = nil }

/// A horizontal chip row: a `ScrollStrip` (drag and arrows on Mac), or a plain focus-driven
/// scroll view on tvOS.
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        #if os(tvOS)
        // Unclipped so a focused chip's lift and glow aren't cut at the row's ends.
        ScrollView(.horizontal, showsIndicators: false) { content.padding(.vertical, 8) }.scrollClipDisabled()
        #else
        // Room inside the strip's clip for the glass chips' edges and hover growth, given back
        // outside so the first chip still lines up with the page.
        ScrollStrip { content.padding(.horizontal, 6) }.padding(.horizontal, -6)
        #endif
    }
}

struct Chip: View {
    let title: String
    var selected = false
    var fill = false
    /// Leads with the Bilibili mark.
    var mark = false
    /// A status dot after the title, such as a source's health.
    var dot: Color? = nil
    let action: () -> Void
    @Environment(\.stripDrag) private var drag
    var body: some View {
        let button = Button { if drag?.active != true { action() } } label: {
            HStack(spacing: 5) {
                if mark { BilibiliGlyph(size: 22).foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(BilibiliMark.blue)) }
                Text(title).lineLimit(1)
                if let dot { Image(systemName: "circle.fill").font(.system(size: 12)).foregroundStyle(dot) }
            }.padding(.horizontal, 4).frame(maxWidth: fill ? .infinity : nil)
        }.accessibilityAddTraits(selected ? [.isSelected] : [])
        #if os(tvOS)
        button.buttonStyle(TVChipStyle(selected: selected))
        #else
        button.buttonStyle(FilterChipStyle(selected: selected))
        #endif
    }
}

/// A page with nothing in it yet: a symbol, what the page is for, and one way forward. The button is
/// also the remote's focus target; a tvOS page with nothing to focus strands it.
struct EmptyPage<Footer: View>: View {
    let symbol: String
    let title: String
    let message: String
    let action: String
    let actionSymbol: String
    let perform: () -> Void
    @ViewBuilder var footer: Footer
    #if os(tvOS)
    private let icon: CGFloat = 132, titleSize: CGFloat = 46, text: CGFloat = 28, spacing: CGFloat = 30, width: CGFloat = 960
    #else
    private let icon: CGFloat = 84, titleSize: CGFloat = 24, text: CGFloat = 15, spacing: CGFloat = 18, width: CGFloat = 420
    #endif
    var body: some View {
        VStack(spacing: spacing) {
            Image(systemName: symbol)
                .font(.system(size: icon * 0.42, weight: .bold))
                .foregroundStyle(Brand.accent)
                .frame(width: icon, height: icon)
                .background(Brand.accent.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: spacing * 0.4) {
                Text(title).font(.system(size: titleSize, weight: .bold))
                // No vertical fixedSize: on the Mac it made the page's minimum height that of the
                // message wrapped at zero width, which stretched the split view past the window.
                Text(message)
                    .font(.system(size: text)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: width)
            Button(action: perform) { Label(action, systemImage: actionSymbol).padding(.horizontal, 8) }
                .controlButton(prominent: true).controlSize(.large)
            footer.font(.system(size: text * 0.8)).monospacedDigit().foregroundStyle(.tertiary)
        }
        .padding(Layout.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyPage where Footer == EmptyView {
    init(symbol: String, title: String, message: String, action: String, actionSymbol: String, perform: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, message: message, action: action, actionSymbol: actionSymbol, perform: perform) { EmptyView() }
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

/// A cover's average colour, for backdrops tinted by the artwork, as the music player has. It
/// shares the posters' cache, so a cover already on screen costs no download.
enum PosterPalette {
    static func average(_ url: URL, headers: [String: String] = [:]) async -> Color? {
        guard let bitmap = try? await PosterLoader.shared.load(PosterResource(url: url, headers: headers)) else { return nil }
        let image = CIImage(cgImage: bitmap.image)
        guard let output = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])?.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                               format: .RGBA8, colorSpace: nil)
        return Color(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }

    /// The cover itself, from the same cache, for the Lock Screen and Control Center.
    static func image(_ url: URL, headers: [String: String] = [:]) async -> CGImage? {
        try? await PosterLoader.shared.load(PosterResource(url: url, headers: headers)).image
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
    private var revision = MediaCache.shared.revision
    init() { cache.countLimit = 96; cache.totalCostLimit = 48 * 1024 * 1024 }

    func load(_ resource: PosterResource) async throws -> PosterBitmap {
        let current = MediaCache.shared.revision
        if revision != current { cache.removeAllObjects(); revision = current }
        let key = resource.cacheKey as NSString
        if let image = cache.object(forKey: key) { return image }
        if let task = pending[resource] { return try await task.value }
        let task = Task {
            let disk = MediaCache.shared
            let ticket = disk.ticket()
            let scope = PosterResource.artworkScope(resource.url)
            let cached = disk.data(for: resource.cacheKey, kind: .artwork, scope: scope)
            let data: Data
            if let cached { data = cached }
            // Saved songs keep their covers, for listening with no connection.
            else if let saved = try? Data(contentsOf: MusicDownloadLibrary.artworkFile(for: resource.url)) { data = saved }
            else { data = try await HTTPClient().get(resource.url, headers: resource.headers).0 }
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 720,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                throw NSError(domain: "PosterLoader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid poster image"])
            }
            if cached == nil {
                disk.store(data, for: resource.cacheKey, kind: .artwork, scope: scope, ttl: 30 * 86400, ticket: ticket)
            }
            return PosterBitmap(image)
        }
        pending[resource] = task
        do {
            let bitmap = try await task.value
            pending[resource] = nil
            if current == MediaCache.shared.revision { cache.setObject(bitmap, forKey: key, cost: bitmap.image.bytesPerRow * bitmap.image.height) }
            return bitmap
        } catch { pending[resource] = nil; throw error }
    }
}

struct PosterImage: View {
    let url: URL?
    var headers: [String: String] = [:]
    /// Shown until the image loads, and when there is none.
    var symbol = "film"
    @State private var bitmap: PosterBitmap?
    private var resource: PosterResource? { url.map { PosterResource(url: $0, headers: headers) } }
    var body: some View {
        ZStack {
            Color(white: 0.20)
            Image(systemName: symbol).font(.title2).foregroundStyle(.white.opacity(0.55))
            if let bitmap { Color.clear.overlay { Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill() } }
        }
        // A filled cover is wider than its frame; clip its drawing and its hit area, or the overflow
        // lies over the neighbouring cards and takes their clicks.
        .clipped()
        .contentShape(.rect)
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
                            .glassSurface(.regular.tint(.black.opacity(0.45)), in: Capsule()).padding(8)
                    }
                }
            // One line, cut with an ellipsis: a title that wrapped made its card taller than the rest of the row.
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.tail)
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
    /// `takeFocus` claims focus for pages with nothing else to focus (a video page's header).
    @ViewBuilder func loadingFocus(takeFocus: Bool = false, onExit: @escaping () -> Void) -> some View {
        #if os(tvOS)
        modifier(LoadingFocus(takeFocus: takeFocus, onExit: onExit))
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// tvOS does not move focus onto a plain focusable view in a newly pushed page, so the view takes
/// it once the push settles. Without focus the Back press never reaches `onExitCommand`.
private struct LoadingFocus: ViewModifier {
    let takeFocus: Bool
    let onExit: () -> Void
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focusable().focused($focused).onExitCommand(perform: onExit)
            .task {
                guard takeFocus else { return }
                try? await Task.sleep(for: .milliseconds(300))
                focused = true
            }
    }
}
#endif

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
        .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
    static let background = Color(red: 0.020, green: 0.035, blue: 0.090)
    static let surface = Color(red: 0.09, green: 0.125, blue: 0.22)
    static let raised = Color(red: 0.13, green: 0.175, blue: 0.29)
}
/// Tiles that draw their own surface and light it up on focus (`\.isFocused` reaches the label),
/// so there is no second plate around them: just the lift.
private struct TVTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Tile(configuration: configuration) }
    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.05 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: 24, y: 14)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
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
    /// A round icon button in the player's top bar.
    @ViewBuilder func chromeButton() -> some View {
        #if os(iOS)
        buttonStyle(ChromeButtonStyle())
        #else
        controlButton().buttonBorderShape(.circle).controlSize(.large)
        #endif
    }

    /// Solid, high-contrast controls. Glass styles take their fill from the tint, which made
    /// prominent labels vanish against a white fill.
    @ViewBuilder func controlButton(prominent: Bool = false) -> some View {
        #if os(tvOS)
        // On tvOS the only highlight is focus: a coloured primary button beside a white focused one
        // left people unsure which was focused, so every control looks the same until focused.
        buttonStyle(TVControlStyle())
        #else
        buttonStyle(ContentControlStyle(prominent: prominent))
        #endif
    }
    @ViewBuilder func controlBackdrop() -> some View {
        #if os(tvOS)
        background(Color.clear.glassSurface(.regular, in: .rect))
        #else
        background(.bar)
        #endif
    }
}
#if os(tvOS)
private struct TVControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Control(configuration: configuration) }
    private struct Control: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 24).padding(.vertical, 15)
                .frame(minHeight: 62)
                // Focus is white, as everywhere on tvOS.
                .background(focused ? Color.white : TVStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .opacity(enabled ? 1 : 0.35)
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.02 : 1)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif

#if os(tvOS)
/// A list row on tvOS: the focused row floats on a Liquid Glass capsule, never a square plate, padded so
/// its leading content never meets the edge. It grows from the leading edge so rows stay in line;
/// scroll views holding these rows pad their content (`glassRowInsets`) so the lift isn't clipped.
struct GlassRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .padding(.horizontal, 28).padding(.vertical, 12)
                .glassSurface(focused ? .regular.tint(.white.opacity(0.22)).interactive() : .identity, in: Capsule())
                .opacity(enabled ? 1 : 0.5)
                .scaleEffect(configuration.isPressed ? 0.99 : focused ? 1.02 : 1, anchor: .leading)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}
#endif

extension View {
    /// List-row buttons: the Liquid Glass row on tvOS, plain elsewhere.
    @ViewBuilder func glassRow() -> some View {
        #if os(tvOS)
        buttonStyle(GlassRowStyle())
        #else
        buttonStyle(.plain)
        #endif
    }
    /// Room around rows using `glassRow()` inside a scroll view, for the focused row's lift.
    @ViewBuilder func glassRowInsets() -> some View {
        #if os(tvOS)
        padding(.horizontal, 40).padding(.vertical, 24)
        #else
        self
        #endif
    }
}

extension View {
    @ViewBuilder func tvDefaultControls() -> some View {
        #if os(tvOS)
        buttonStyle(TVControlStyle())
        #else
        self
        #endif
    }
}

#if !os(tvOS)
#if os(iOS)
/// 44-point glass circles: `ContentControlStyle` ignores the border shape, so its "circles" were
/// capsules too wide for a phone's player bar.
private struct ChromeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .glassSurface(.regular.interactive(), in: Circle())
            .contentShape(Circle())
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
    }
}
#endif

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
