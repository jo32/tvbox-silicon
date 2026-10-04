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

enum Brand {
    static let accent = Color.primary
    static let indigo = Color(white: 0.38)
    static let amber = Color(red: 1.0, green: 0.66, blue: 0.28)
    static let rose = Color(red: 1.0, green: 0.36, blue: 0.48)
}

enum Layout {
    #if os(tvOS)
    static let gutter: CGFloat = 64, posterMin: CGFloat = 240, cardMin: CGFloat = 480, tileMin: CGFloat = 340
    static let heroTitle: CGFloat = 68, detailPoster: CGFloat = 300, episodeMin: CGFloat = 200
    #elseif os(macOS)
    static let gutter: CGFloat = 24, posterMin: CGFloat = 174, cardMin: CGFloat = 280, tileMin: CGFloat = 220
    static let heroTitle: CGFloat = 48, detailPoster: CGFloat = 210, episodeMin: CGFloat = 120
    #else
    static let gutter: CGFloat = 16, posterMin: CGFloat = 140, cardMin: CGFloat = 280, tileMin: CGFloat = 160
    static let heroTitle: CGFloat = 34, detailPoster: CGFloat = 130, episodeMin: CGFloat = 90
    #endif
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
        ZStack {
            (scheme == .dark ? Color(white: 0.06) : Color(white: 0.97))
            RadialGradient(colors: [Color(red: 0.25, green: 0.55, blue: 0.95).opacity(scheme == .dark ? 0.30 : 0.20), .clear], center: .topLeading, startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color(red: 0.62, green: 0.35, blue: 0.95).opacity(scheme == .dark ? 0.26 : 0.16), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 560)
        }.ignoresSafeArea()
    }
}

struct Surface: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        (scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
    }
}

extension View {
    func screenBackdrop() -> some View { background { Backdrop() } }

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
            .toolbarBackground(.visible, for: .navigationBar)
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
            .glassEffect(.regular.tint(tint.opacity(0.18)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(selected ? (scheme == .dark ? Color.black : .white) : .primary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 44)
            .glassEffect(selected ? .regular.tint(scheme == .dark ? .white.opacity(0.9) : .black.opacity(0.85)).interactive() : .regular.interactive(), in: Capsule())
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
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).foregroundStyle(.primary)
            }.buttonStyle(.plain)
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
                .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.posterMin), spacing: 18, alignment: .top)], spacing: 22) {
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

struct LoadingPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .frame(maxWidth: .infinity)
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
    static let background = Color(white: 0.06)
    static let surface = Color(white: 0.14)
}
private struct TVCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Card(configuration: configuration) }
    private struct Card: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(focused ? 1 : 0), lineWidth: 3) }
                .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.02 : 1)
                .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: 20, y: 12)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif

extension View {
    @ViewBuilder func controlButton(prominent: Bool = false) -> some View {
        if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
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
                .foregroundStyle(focused || prominent ? Color.black : Color.white)
                .padding(.horizontal, 24).padding(.vertical, 15)
                .frame(minHeight: 62)
                .background(focused ? Color.white : prominent ? Color(white: 0.86) : TVStyle.surface, in: RoundedRectangle(cornerRadius: 14))
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? (scheme == .dark ? Color.black : Color.white) : Color.primary)
            .padding(.horizontal, size == .large ? 20 : 14)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background {
                if prominent {
                    (scheme == .dark ? Color.white : Color(white: 0.06)).clipShape(Capsule())
                } else {
                    Surface().clipShape(Capsule())
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
    }
}
#endif
