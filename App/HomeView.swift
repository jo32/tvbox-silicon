import SwiftUI
import TVCore

struct HomeView: View {
    @Environment(Store.self) private var store
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    #if os(tvOS)
    @FocusState private var importFocused: Bool
    #endif

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                    if let config = store.subscription {
                        RecommendationsView(config: config)
                        if !store.favorites.isEmpty { favorites }
                        if !config.lives.isEmpty { playlists(config).id("live") }
                    } else {
                        welcome
                    }
                }
                .pageContainer()
            }
            #if DEBUG
            .task { if let target = QALaunch.scrollTarget { try? await Task.sleep(for: .seconds(8)); reader.scrollTo(target, anchor: .bottom) } }
            #endif
        }
        .screenBackdrop()
        #if os(tvOS)
        // The tab sidebar already names this page; a second heading just repeats it.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .screenTitle(L10n.text("Watch Now"))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Welcome

    /// First run: one clear action, a way to bring your own URL, and artwork so the empty
    /// screen reads as an invitation rather than a missing page.
    private var welcome: some View {
        HStack(alignment: .center, spacing: Layout.gutter) {
            welcomeCopy.frame(maxWidth: .infinity, alignment: .leading)
            if showsPosterWall {
                PosterWall().frame(maxWidth: .infinity).accessibilityHidden(true)
            }
        }
        .containerRelativeFrame(.vertical, alignment: .center) { height, _ in height * 0.82 }
        #if os(tvOS)
        // Moving right out of the sidebar lands on the primary action, not the secondary one.
        .defaultFocus($importFocused, true, priority: .userInitiated)
        #endif
    }

    private var welcomeCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                AppMark(size: Layout.heroTitle * 1.4)
                Text(L10n.text("Yingxia")).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)
            Text(L10n.text("Your cinema,\non every screen."))
                .font(.system(size: Layout.heroTitle, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 18)
            Text(L10n.text("Connect your subscription to watch on Mac, iPhone, iPad, and Apple TV."))
                .font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: Layout.heroTitle * 10, alignment: .leading)
                .padding(.bottom, 40)
            HStack(spacing: 16) {
                Button { Task { await store.importSubscription() } } label: {
                    Label(store.importing ? L10n.text("Importing…") : L10n.text("Import Subscription"), systemImage: "plus.circle.fill")
                }
                .controlButton(prominent: true).tint(Brand.accent).disabled(store.importing)
                #if os(tvOS)
                .focused($importFocused)
                #endif
                Button { store.section = .settings } label: {
                    Label(L10n.text("Use Another URL"), systemImage: "link")
                }
                .controlButton()
            }
            .controlSize(.large)
            if store.importing {
                LoadingCard { .server(URL(string: store.subscriptionAddress)?.host(), title: L10n.text("Importing…")) }
                    .frame(maxWidth: Layout.heroTitle * 9)
                    .padding(.top, 24)
            }
        }
    }

    private var showsPosterWall: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }

    // MARK: Sections

    private var favorites: some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Favorites")) { store.section = .favorites }
            ChipRow {
                HStack(spacing: Layout.cardSpacing) {
                    ForEach(store.favorites.prefix(12)) { ChannelCard(channel: $0).frame(width: Layout.cardMin) }
                }.padding(.vertical, 6)
            }
        }
    }

    private func playlists(_ config: Subscription) -> some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            SectionHeader(title: L10n.text("Live TV")) { store.section = .live }
            LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                ForEach(config.lives.prefix(6)) { SourceCard(source: $0) }
            }
        }
    }

}

/// The app icon artwork, masked like a home-screen icon.
private struct AppMark: View {
    var size: CGFloat
    var body: some View {
        Image("YingxiaLogo").resizable().interpolation(.high).scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .shadow(color: Color(red: 0.1, green: 0.55, blue: 1).opacity(0.35), radius: size * 0.22, y: size * 0.06)
    }
}

/// Decorative poster tiles: staggered columns in the brand's warm hues, fading into the canvas.
private struct PosterWall: View {
    private static let hues: [Color] = [Brand.accent, Brand.terracotta, Brand.amber, Brand.rose]
    private static let symbols = ["film", "sparkles.tv", "theatermasks", "music.note.tv", "popcorn", "star"]
    var body: some View {
        GeometryReader { proxy in
            let spacing = proxy.size.width * 0.045
            let width = (proxy.size.width - spacing * 2) / 3
            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<3, id: \.self) { column in
                    VStack(spacing: spacing) {
                        ForEach(0..<4, id: \.self) { row in tile(column * 4 + row, width: width) }
                    }
                    .offset(y: column == 1 ? -width * 0.55 : column == 2 ? -width * 0.15 : 0)
                }
            }
            .rotationEffect(.degrees(-6))
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .background { EllipticalGradient(colors: [Brand.accent.opacity(0.3), .clear], endRadiusFraction: 0.5) }
            // An ellipse that reaches clear at the frame's edges, so no tile meets a hard clip.
            .mask { EllipticalGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.75), location: 0.45), .init(color: .clear, location: 1)], endRadiusFraction: 0.5) }
        }
    }

    private func tile(_ index: Int, width: CGFloat) -> some View {
        let hue = Self.hues[index % Self.hues.count]
        let lit = index % 3 != 1
        return RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
            .fill(LinearGradient(colors: lit ? [hue.opacity(0.7), hue.opacity(0.28)] : [PosterSurface.raised, PosterSurface.base],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                Image(systemName: Self.symbols[index % Self.symbols.count])
                    .font(.system(size: width * 0.26, weight: .semibold))
                    .foregroundStyle(.white.opacity(lit ? 0.55 : 0.18))
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: width * 0.04) {
                    Capsule().frame(width: width * 0.55, height: width * 0.05)
                    Capsule().frame(width: width * 0.32, height: width * 0.05)
                }
                .foregroundStyle(.white.opacity(lit ? 0.35 : 0.12))
                .padding(width * 0.09)
            }
            .frame(width: width, height: width * 1.45)
    }
}

/// Neutral tile fills that track the canvas on every platform.
private enum PosterSurface {
    static let base = Color(light: Color(red: 0.93, green: 0.90, blue: 0.86), dark: Color(red: 0.14, green: 0.11, blue: 0.085))
    static let raised = Color(light: Color(red: 0.89, green: 0.85, blue: 0.80), dark: Color(red: 0.22, green: 0.17, blue: 0.13))
}
