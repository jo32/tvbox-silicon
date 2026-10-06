import SwiftUI
import TVCore

struct HomeView: View {
    @Environment(Store.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if store.subscription == nil { hero }
                if let config = store.subscription {
                    RecommendationsView(config: config)
                    if !store.favorites.isEmpty { favorites }
                    if !config.lives.isEmpty { playlists(config) }
                } else if store.importing {
                    LoadingCard { .server(URL(string: store.subscriptionAddress)?.host(), title: L10n.text("Importing…")) }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.tileMin), spacing: 16)], spacing: 16) {
                        ForEach(0..<3, id: \.self) { _ in SkeletonBlock(cornerRadius: 26).frame(height: 82) }
                    }
                } else {
                    Label(L10n.text("You can also enter another TVBox JSON subscription URL in Settings."), systemImage: "link")
                        .foregroundStyle(.secondary)
                }
            }
            .pageContainer()
        }
        .screenBackdrop()
        .screenTitle(L10n.text("Watch Now"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L10n.text("Yingxia / TVBOX"), systemImage: "sparkles.tv")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.16), in: Capsule())
            Text(L10n.text("Your cinema,\non every screen."))
                .font(.system(size: Layout.heroTitle, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Connect your subscription to watch on Mac, iPhone, iPad, and Apple TV."))
                .font(.title3).foregroundStyle(.white.opacity(0.78))
                .frame(maxWidth: Layout.heroTitle * 16, alignment: .leading)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    if store.subscription == nil {
                        Button { Task { await store.importSubscription() } } label: {
                            Label(store.importing ? L10n.text("Importing…") : L10n.text("Import Subscription"), systemImage: "plus.circle.fill").font(.headline)
                        }.controlButton(prominent: true).tint(Brand.accent).disabled(store.importing)
                    } else {
                        Button { store.section = .search } label: {
                            Label(L10n.text("Global Search"), systemImage: "magnifyingglass").font(.headline)
                        }.controlButton(prominent: true).tint(Brand.accent)
                        Button { store.section = .sites } label: {
                            Label(L10n.text("Sources"), systemImage: "square.grid.2x2.fill").font(.headline)
                        }.controlButton()
                    }
                }
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(Layout.gutter + 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { heroArt }
        .overlay(alignment: .topTrailing) {
            Image(systemName: "play.tv.fill")
                .resizable().scaledToFit().frame(width: Layout.heroTitle * 3.2)
                .foregroundStyle(.white.opacity(0.10)).rotationEffect(.degrees(-9))
                .padding(Layout.gutter).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
        
    }

    private var heroArt: some View {
        Color(red: 0.12, green: 0.09, blue: 0.07)
    }

    // MARK: Sections

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.text("Favorites")) { store.section = .favorites }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(store.favorites.prefix(12)) { ChannelCard(channel: $0).frame(width: Layout.cardMin) }
                }.padding(.vertical, 6)
            }
        }
    }

    private func playlists(_ config: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: L10n.text("Live TV")) { store.section = .live }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 14)], spacing: 14) {
                ForEach(config.lives.prefix(6)) { SourceCard(source: $0) }
            }
        }
    }

}
