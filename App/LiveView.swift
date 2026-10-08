import SwiftUI
import TVCore

struct LiveView: View {
    @Environment(Store.self) private var store
    var body: some View {
        Group {
            if let config = store.subscription, !config.lives.isEmpty {
                ScrollView {
                    LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                        ForEach(config.lives) { SourceCard(source: $0) }
                    }.pageContainer()
                }
            } else { ContentUnavailableView(L10n.text("Connect a Live Subscription"), systemImage: "dot.radiowaves.left.and.right", description: Text(L10n.text("Import a TVBox configuration containing live playlists in Settings first."))) }
        }
        .screenBackdrop()
        .screenTitle(L10n.text("Live TV"))
    }
}

struct SourceCard: View {
    let source: LiveSource
    var body: some View {
        RouteLink { ChannelListView(source: source) } label: {
            HStack(spacing: 14) {
                IconTile(symbol: "antenna.radiowaves.left.and.right", tint: Brand.accent, size: 46)
                CardTitle(text: source.name)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .contentPanel()
        }.cardButton()
    }
}

struct ChannelListView: View {
    let source: LiveSource
    @Environment(\.dismiss) private var dismiss
    @State private var channels: [Channel] = []
    @State private var query = ""
    @State private var group: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var error: String?
    private var waiting: Bool { channels.isEmpty && error == nil && (loading || !loaded) }
    private var groups: [String] { Array(Set(channels.map(\.group))).sorted() }
    private var filtered: [Channel] {
        channels.filter { (group == nil || $0.group == group) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        #if os(tvOS)
        TVChannelGuide(source: source, channels: channels, query: $query, group: $group,
                       loading: waiting, refreshing: loading, error: error,
                       reload: { Task { await load() } })
            .task(id: source.id) { if !loaded { await load() } }
        #else
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                #if os(tvOS)
                HStack {
                    Spacer()
                    Button { Task { await load() } } label: { Label(L10n.text("Refresh"), systemImage: "arrow.clockwise") }
                        .controlButton().disabled(loading)
                }
                #endif
                if !channels.isEmpty { filterBar } else if waiting { ChipSkeletonRow() }
                if waiting {
                    LoadingCard { .server(source.url.host(), title: L10n.text("Loading channels…")) }
                    ChannelSkeletonGrid()
                }
                if let error {
                    ErrorStateCard(
                        title: L10n.text("Unable to Load Channels"),
                        message: L10n.text("Try again, or choose another source to keep watching."),
                        details: error,
                        retry: { Task { await load() } },
                        goBack: { dismiss() },
                        busy: loading
                    ).padding(.vertical, 24).tvFocusSection()
                }
                if !waiting && error == nil && filtered.isEmpty {
                    ContentUnavailableView(L10n.text("No Matching Channels"), systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                }
                if !filtered.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { ChannelCard(channel: $0) }
                    }
                }
            }.pageContainer()
        }
        .screenBackdrop()
        .catalogSearchable(text: $query, prompt: L10n.text("Search channels")).screenTitle(source.name)
        .toolbar { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading).accessibilityLabel(L10n.text("Refresh")) }
        .task(id: source.id) { if !loaded { await load() } }
        #endif
    }
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChipRow {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Chip(title: L10n.text("All"), selected: group == nil) { group = nil }
                        ForEach(groups, id: \.self) { value in
                            Chip(title: value.isEmpty ? L10n.text("Ungrouped") : value, selected: group == value) { group = value }
                        }
                    }
                }.padding(.vertical, 4)
            }
            Text(L10n.text("Channels: %lld", filtered.count)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false; if !Task.isCancelled { loaded = true } }
        do { channels = try await HTTPClient().channels(source); if let group, !groups.contains(group) { self.group = nil } }
        catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}

#if os(tvOS)
/// Channel-only adaptation of a living-room guide. Programme data is not supplied by playlists.
private struct TVChannelGuide: View {
    let source: LiveSource
    let channels: [Channel]
    @Binding var query: String
    @Binding var group: String?
    let loading: Bool
    let refreshing: Bool
    let error: String?
    let reload: () -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedChannel: String?
    @State private var showingSearch = false
    private var groups: [String] { Array(Set(channels.map(\.group))).sorted() }
    private var filtered: [Channel] {
        channels.filter { (group == nil || $0.group == group) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    }
    private var highlighted: Channel? { filtered.first { $0.id == focusedChannel } ?? filtered.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 18) {
                Text(source.name).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                Spacer()
                Button { showingSearch = true } label: {
                    Label(query.isEmpty ? L10n.text("Search channels") : query, systemImage: "magnifyingglass")
                        .lineLimit(1)
                }.controlButton()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark") }
                        .controlButton().accessibilityLabel(L10n.text("Clear search"))
                }
                Button(action: reload) { Image(systemName: "arrow.clockwise") }
                    .controlButton().disabled(refreshing).accessibilityLabel(L10n.text("Refresh"))
            }.tvFocusSection()

            if let channel = highlighted {
                HStack(alignment: .center, spacing: 48) {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(L10n.text("Live TV"), systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 21, weight: .semibold)).foregroundStyle(.secondary)
                        Text(channel.name).font(.system(size: 52, weight: .bold)).lineLimit(2)
                        HStack(spacing: 18) {
                            Text(channel.displayGroup)
                            if store.isFavorite(channel) { Image(systemName: "heart.fill") }
                        }.font(.system(size: 24)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    TVGuideLogo(channel: channel, size: 112)
                        .frame(width: 350, height: 198)
                        .background(TVStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                }.frame(height: 218)
            }

            if !channels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        category(L10n.text("All"), value: nil)
                        ForEach(groups, id: \.self) { value in
                            category(value.isEmpty ? L10n.text("Ungrouped") : value, value: value)
                        }
                    }.padding(4)
                }.scrollClipDisabled().tvFocusSection()
            }

            if loading {
                LoadingCard { .server(source.url.host(), title: L10n.text("Loading channels…")) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ErrorStateCard(title: L10n.text("Unable to Load Channels"),
                               message: L10n.text("Try again, or choose another source to keep watching."),
                               details: error, retry: reload, goBack: { dismiss() }, busy: refreshing)
                Spacer()
            } else if filtered.isEmpty {
                ContentUnavailableView(L10n.text("No Matching Channels"), systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L10n.text("Channels: %lld", filtered.count))
                        Spacer()
                        Text(L10n.text("Live TV"))
                    }.font(.system(size: 20)).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filtered) { channel in
                                channelRow(channel)
                                    .focused($focusedChannel, equals: channel.id)
                            }
                        }.padding(4)
                    }.scrollClipDisabled().tvFocusSection()
                }
            }
        }
        .padding(.horizontal, Layout.gutter).padding(.top, 24).padding(.bottom, 24)
        .screenBackdrop()
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showingSearch) {
            NavigationStack {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filtered) { channel in
                            Button {
                                showingSearch = false
                                store.playing = channel
                            } label: {
                                HStack(spacing: 24) {
                                    TVGuideLogo(channel: channel, size: 54)
                                    Text(channel.name)
                                    Spacer()
                                    Image(systemName: "play.fill")
                                }.padding(20)
                            }.buttonStyle(TVGuideRowStyle())
                        }
                        if filtered.isEmpty { Text(L10n.text("No Matching Channels")) }
                    }.padding(48)
                }
                .searchable(text: $query, prompt: Text(L10n.text("Search channels")))
                .screenBackdrop()
            }.onExitCommand { showingSearch = false }
        }
    }

    private func category(_ title: String, value: String?) -> some View {
        Button { group = value; focusedChannel = nil } label: { Text(title) }
            .buttonStyle(TVGuideCategoryStyle(selected: group == value))
            .accessibilityAddTraits(group == value ? [.isSelected] : [])
    }

    private func channelRow(_ channel: Channel) -> some View {
        Button { store.playing = channel } label: {
            HStack(spacing: 26) {
                TVGuideLogo(channel: channel, size: 52).frame(width: 100)
                Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 48)
                Text(channel.name).font(.system(size: 28, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 20)
                Text(channel.displayGroup).font(.system(size: 22)).opacity(0.65).lineLimit(1)
                if store.isFavorite(channel) { Image(systemName: "heart.fill").font(.system(size: 20)) }
                Image(systemName: "play.fill").font(.system(size: 20)).frame(width: 44)
            }.padding(.horizontal, 22).frame(height: 90)
        }
        .buttonStyle(TVGuideRowStyle())
        .contextMenu {
            Button { store.toggleFavorite(channel) } label: {
                Label(store.isFavorite(channel) ? L10n.text("Remove %@ from favorites", channel.name) : L10n.text("Add %@ to favorites", channel.name),
                      systemImage: store.isFavorite(channel) ? "heart.slash" : "heart")
            }
        }
        .accessibilityLabel("\(channel.name), \(channel.displayGroup), \(L10n.text("Play"))")
    }
}

private struct TVGuideLogo: View {
    let channel: Channel
    let size: CGFloat
    var body: some View {
        ZStack {
            Text(String(channel.name.prefix(1))).font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(Color.white)
            if let url = channel.logo {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(5).background(TVStyle.raised)
                    }
                }
            }
        }.frame(width: size, height: size)
            .background(TVStyle.raised, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct TVGuideRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(focused ? Color.white : TVStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(configuration.isPressed ? 0.99 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

private struct TVGuideCategoryStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View { Category(configuration: configuration, selected: selected) }
    private struct Category: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label.font(.system(size: 23, weight: .semibold))
                .padding(.horizontal, 24).padding(.vertical, 13)
                .foregroundStyle(selected ? Brand.onAccent : Color.white)
                .background(selected ? Brand.accent : TVStyle.raised, in: Capsule())
                .overlay { Capsule().strokeBorder(focused ? Color.white : .clear, lineWidth: 3).padding(-5) }
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
        }
    }
}
#endif

struct FavoritesView: View {
    @Environment(Store.self) private var store
    var body: some View {
        Group {
            if store.favorites.isEmpty { ContentUnavailableView(L10n.text("No Favorites Yet"), systemImage: "heart", description: Text(L10n.text("Tap the heart next to a live channel to save it on this device."))) }
            else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 12)], spacing: 12) {
                        ForEach(store.favorites) { ChannelCard(channel: $0) }
                    }.pageContainer()
                }
            }
        }
        .screenBackdrop()
        .screenTitle(L10n.text("Favorites"))
    }
}

struct ChannelLogo: View {
    let channel: Channel
    var size: CGFloat = 50
    private static let palette: [[Color]] = [
        [Brand.accent, Color(red: 0.80, green: 0.36, blue: 0.10)], [Brand.terracotta, Color(red: 0.62, green: 0.24, blue: 0.18)],
        [Brand.rose, Color(red: 0.75, green: 0.20, blue: 0.40)], [Brand.amber, Color(red: 0.85, green: 0.42, blue: 0.15)],
        [Color(red: 0.85, green: 0.65, blue: 0.40), Color(red: 0.55, green: 0.36, blue: 0.20)],
    ]
    private var colors: [Color] {
        Self.palette[channel.name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.palette.count]
    }
    var body: some View {
        #if os(tvOS)
        let size: CGFloat = 72
        #endif
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(channel.name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded)).foregroundStyle(.white)
            if let logo = channel.logo {
                AsyncImage(url: logo) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(size * 0.12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.95))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct ChannelCard: View {
    @Environment(Store.self) private var store
    @Environment(\.stripDrag) private var drag
    let channel: Channel
    var body: some View {
        let favorite = store.isFavorite(channel)
        HStack(spacing: 10) {
            Button { if drag?.active != true { store.playing = channel } } label: {
                HStack(spacing: 14) {
                    ChannelLogo(channel: channel)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(channel.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(channel.displayGroup).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.cardButton()
            Button { if drag?.active != true { store.toggleFavorite(channel) } } label: {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.title3).foregroundStyle(favorite ? Brand.rose : .secondary)
                    .frame(width: 44, height: 44).contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? L10n.text("Remove %@ from favorites", channel.name) : L10n.text("Add %@ to favorites", channel.name))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel()
    }
}
