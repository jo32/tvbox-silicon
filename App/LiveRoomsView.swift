import SwiftUI
import TVCore

/// A built-in live platform: its areas as chips over a grid of rooms, like the platform's own live
/// home, more rooms as the grid scrolls, and its search.
struct LivePlatformView: View {
    let platform: LivePlatform
    var initialQuery = ""
    @Environment(\.dismiss) private var dismiss
    @State private var areas: [LiveArea] = []
    @State private var area: LiveArea?
    @State private var rooms: [LiveRoom] = []
    @State private var page = 0
    @State private var exhausted = false
    @State private var loader: Task<Void, Never>?
    @State private var error: String?
    @State private var query = ""
    /// Read again on appearing: Douyin becomes searchable once signed in.
    @State private var searchable = true
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if trimmed.isEmpty { browse } else { LiveRoomSearch(platform: platform, query: trimmed) }
            }.pageContainer()
        }
        .screenBackdrop()
        .liveSearchable(searchable, text: $query, prompt: L10n.text("Search %@", platform.name))
        .screenTitle(platform.name)
        .onAppear { searchable = platform.searchable }
        #if !os(tvOS)
        .toolbar { Button { reload() } label: { Image(systemName: "arrow.clockwise") }.disabled(loader != nil).accessibilityLabel(L10n.text("Refresh")) }
        #endif
        .task {
            if query.isEmpty, !initialQuery.isEmpty { query = initialQuery }
            if areas.isEmpty { reload() }
        }
        .onDisappear { loader?.cancel(); loader = nil }
    }

    @ViewBuilder private var browse: some View {
        if platform == .douyin && !searchable { DouyinSignInBanner() }
        if areas.count > 1 {
            ChipRow {
                GlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(areas) { value in
                            Chip(title: value.name, selected: area == value) { select(value) }
                        }
                    }
                }.padding(.vertical, 4)
            }
        } else if areas.isEmpty && loader != nil { ChipSkeletonRow() }
        if let error {
            ErrorStateCard(title: L10n.text("Unable to Load Channels"), message: L10n.text("Try again, or choose another source to keep watching."),
                           details: error, retry: { reload() }, goBack: { dismiss() }, busy: loader != nil)
                .padding(.vertical, 24).tvFocusSection()
        }
        LiveRoomGrid(rooms: rooms) { room in if room.id == rooms.last?.id { more() } }
        if loader != nil && rooms.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60) }
        if loader == nil && error == nil && page > 0 && rooms.isEmpty {
            ContentUnavailableView(L10n.text("No Live Rooms"), systemImage: "dot.radiowaves.left.and.right")
                .frame(maxWidth: .infinity)
        }
    }

    private func reload() {
        loader?.cancel()
        areas = []; rooms = []; page = 0; exhausted = false; error = nil
        loader = Task {
            do {
                let found = try await LiveCatalog.areas(platform)
                guard !Task.isCancelled else { return }
                areas = found
                var chosen = found.first
                #if DEBUG
                // `-qaLiveArea <name>` opens that area, for screenshots.
                if let name = UserDefaults.standard.string(forKey: "qaLiveArea"), let match = found.first(where: { $0.name == name }) { chosen = match }
                #endif
                area = chosen
                loader = nil
                more()
            } catch {
                guard !Task.isCancelled else { return }
                Diagnostics.shared.failure("live", "\(platform.rawValue) areas", error)
                self.error = error.localizedDescription; loader = nil
            }
        }
    }

    private func select(_ value: LiveArea) {
        guard value != area else { return }
        loader?.cancel(); loader = nil
        area = value; rooms = []; page = 0; exhausted = false; error = nil
        more()
    }

    /// The next page of the selected area.
    private func more() {
        guard loader == nil, !exhausted, let area else { return }
        let next = page + 1
        loader = Task {
            do {
                let found = try await LiveCatalog.rooms(platform, area: area, page: next)
                guard !Task.isCancelled else { return }
                var seen = Set(rooms.map(\.id))
                let fresh = found.filter { seen.insert($0.id).inserted }
                rooms += fresh; page = next
                // A page of only rooms already shown means the list has started over.
                if fresh.isEmpty { exhausted = true }
            } catch {
                guard !Task.isCancelled else { return }
                Diagnostics.shared.failure("live", "\(platform.rawValue) rooms page=\(next)", error)
                if rooms.isEmpty { self.error = error.localizedDescription } else { exhausted = true }
            }
            loader = nil
        }
    }
}

/// Search results for one platform, as a grid.
private struct LiveRoomSearch: View {
    let platform: LivePlatform
    let query: String
    @State private var rooms: [LiveRoom] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView(L10n.text("Search Failed"), systemImage: "exclamationmark.magnifyingglass", description: Text(error))
                    .frame(maxWidth: .infinity)
            } else if rooms.isEmpty {
                if searching { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60) }
                else { ContentUnavailableView.search(text: query).frame(maxWidth: .infinity) }
            } else {
                LiveRoomGrid(rooms: rooms)
            }
        }
        .task(id: query) {
            searching = true; error = nil
            // Wait for the typing to pause.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            do { rooms = try await LiveCatalog.search(platform, keyword: query) }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                Diagnostics.shared.failure("live", "\(platform.rawValue) search", error)
                self.error = error.localizedDescription; rooms = []
            }
            if !Task.isCancelled { searching = false }
        }
    }
}

struct LiveRoomGrid: View {
    let rooms: [LiveRoom]
    var appeared: (LiveRoom) -> Void = { _ in }
    var body: some View {
        // Search results can list a room twice.
        var seen = Set<String>()
        let unique = rooms.filter { seen.insert($0.id).inserted }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.tileMin), spacing: Layout.cardSpacing)], spacing: Layout.gridRowSpacing) {
            ForEach(unique) { room in LiveRoomCard(room: room).onAppear { appeared(room) } }
        }
    }
}

/// The Live tab's search: rooms from each built-in platform that can search, then the matching
/// channels of the subscription's live playlists.
struct LiveSearchResults: View {
    let query: String
    let sources: [LiveSource]
    @State private var found: [LivePlatform: [LiveRoom]] = [:]
    @State private var failures: [LivePlatform: String] = [:]
    @State private var playlists: [String: [Channel]] = [:]
    @State private var loadingPlaylists = true
    private var platforms: [LivePlatform] { sources.compactMap(\.platform).filter(\.searchable) }
    private var playlistSources: [LiveSource] { sources.filter { !$0.isBuiltIn } }
    private var channels: [Channel] {
        var seen = Set<String>()
        return playlistSources.flatMap { playlists[$0.id] ?? [] }
            .filter { $0.name.localizedCaseInsensitiveContains(query) && seen.insert($0.id).inserted }
    }
    private var finished: Bool { !loadingPlaylists && platforms.allSatisfy { found[$0] != nil || failures[$0] != nil } }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            ForEach(platforms) { platform in
                if found[platform]?.isEmpty != true || failures[platform] != nil { section(platform) }
            }
            if !channels.isEmpty {
                VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                    SectionHeader(title: L10n.text("Live Channels"))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Layout.cardMin), spacing: 12)], spacing: 12) {
                        ForEach(channels.prefix(60)) { ChannelCard(channel: $0) }
                    }
                }
            }
            if finished && channels.isEmpty && platforms.allSatisfy({ found[$0]?.isEmpty != false }) {
                ContentUnavailableView.search(text: query).frame(maxWidth: .infinity)
            }
        }
        .task(id: query) {
            found = [:]; failures = [:]
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await withTaskGroup(of: (LivePlatform, Result<[LiveRoom], Error>).self) { group in
                for platform in platforms {
                    group.addTask { await (platform, Result { try await LiveCatalog.search(platform, keyword: query) }) }
                }
                for await (platform, result) in group where !Task.isCancelled {
                    switch result {
                    case .success(let rooms): found[platform] = rooms
                    case .failure(let error): failures[platform] = error.localizedDescription
                    }
                }
            }
        }
        .task {
            // Playlists load once; searching them is a filter.
            guard playlists.isEmpty else { return }
            await withTaskGroup(of: (String, [Channel]).self) { group in
                for source in playlistSources {
                    group.addTask { (source.id, (try? await HTTPClient().channels(source)) ?? []) }
                }
                for await (id, list) in group { playlists[id] = list }
            }
            loadingPlaylists = false
        }
    }

    private func section(_ platform: LivePlatform) -> some View {
        VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            RouteLink { LivePlatformView(platform: platform, initialQuery: query) } label: {
                HStack(spacing: 10) {
                    LivePlatformMark(platform: platform, size: 28)
                    SectionHeader(title: platform.name)
                    Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    #if !os(tvOS)
                    Spacer(minLength: 0)
                    #endif
                }.contentShape(Rectangle()).foregroundStyle(.primary)
            }.buttonStyle(.plain)
            if let rooms = found[platform] {
                LiveRoomGrid(rooms: Array(rooms.prefix(8)))
            } else if let failure = failures[platform] {
                Text(failure).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            }
        }
    }
}

/// A live room: its 16:9 cover with a live badge and the audience, then the title and the streamer.
struct LiveRoomCard: View {
    @Environment(Store.self) private var store
    let room: LiveRoom

    var body: some View {
        let favorite = store.isFavorite(room.channel)
        Button { store.playing = room.channel } label: {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { PosterImage(url: room.cover, headers: [:]) }
                    .posterClip(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .coverOverlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            Image(systemName: "dot.radiowaves.left.and.right").font(.caption2.weight(.bold))
                            Text(L10n.text("LIVE")).font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Brand.rose, in: Capsule()).padding(8)
                    }
                    .coverOverlay(alignment: .bottomTrailing) {
                        if room.online > 0 {
                            Label(room.online.formatted(.number.notation(.compactName)), systemImage: "person.2.fill")
                                .font(.caption2.weight(.semibold)).foregroundStyle(.white).labelStyle(.titleAndIcon)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .glassSurface(.regular.tint(.black.opacity(0.45)), in: Capsule()).padding(8)
                        }
                    }
                    .coverOverlay(alignment: .bottomLeading) {
                        if favorite {
                            Image(systemName: "heart.fill").font(.caption).foregroundStyle(Brand.rose)
                                .padding(6).glassSurface(.regular.tint(.black.opacity(0.45)), in: Circle()).padding(8)
                        }
                    }
                Text(room.title.isEmpty ? room.host : room.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail).cardCaption()
                Text([room.host, room.area].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .cardCaption()
            }
            // Cards in a row share its height; a one-line title leaves the space below, not between.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .cardButton()
        .contextMenu {
            Button(favorite ? L10n.text("Remove %@ from favorites", room.host) : L10n.text("Add %@ to favorites", room.host),
                   systemImage: favorite ? "heart.slash" : "heart") { store.toggleFavorite(room.channel) }
        }
        .accessibilityLabel("\(room.host), \(room.title)")
    }
}

extension LivePlatform {
    /// The platform's brand colour, behind its mark and its card.
    var tint: Color {
        switch self {
        case .bilibili: Color(red: 0.98, green: 0.45, blue: 0.60)
        case .douyu: Color(red: 1.0, green: 0.42, blue: 0.10)
        case .huya: Color(red: 1.0, green: 0.62, blue: 0.0)
        case .douyin: Color(red: 0.07, green: 0.07, blue: 0.09)
        }
    }
}

/// A room each built-in platform is showing now, for its card: the busiest room with a cover in the
/// first of its areas that has one (a signed-out "Following" list is empty), asked again after ten
/// minutes. The fetch outlives the card's appearance: a slow platform would otherwise never finish.
@MainActor @Observable final class LivePreviews {
    static let shared = LivePreviews()
    private(set) var rooms: [LivePlatform: LiveRoom] = [:]
    @ObservationIgnored private var asked: [LivePlatform: Date] = [:]

    func load(_ platform: LivePlatform) {
        if let date = asked[platform], Date.now.timeIntervalSince(date) < 600 { return }
        asked[platform] = .now
        Task {
            let areas = (try? await LiveCatalog.areas(platform)) ?? []
            for area in areas.prefix(3) {
                let found = (try? await LiveCatalog.rooms(platform, area: area, page: 1)) ?? []
                if let room = found.filter({ $0.cover != nil }).max(by: { $0.online < $1.online }) {
                    rooms[platform] = room
                    return
                }
            }
            // Nothing to show: ask again next time the card shows.
            asked[platform] = nil
        }
    }
}

/// A built-in platform as a 16:9 card: its mark and name over a room it is showing now, or over its
/// brand colour until that loads. Use with `tileButton()`: on tvOS the card draws its own focus ring.
struct LivePlatformCard: View {
    let platform: LivePlatform
    @Environment(\.isFocused) private var isFocused
    #if os(tvOS)
    private var focused: Bool { isFocused }
    private let mark: CGFloat = 56, padding: CGFloat = 22, radius: CGFloat = 26
    private let titleFont = Font.system(size: 30, weight: .bold), detailFont = Font.system(size: 22, weight: .medium)
    #else
    private let focused = false
    private let mark: CGFloat = 28, padding: CGFloat = 10, radius: CGFloat = 16
    private let titleFont = Font.subheadline.weight(.semibold), detailFont = Font.caption2
    #endif
    private var room: LiveRoom? { LivePreviews.shared.rooms[platform] }
    #if os(iOS)
    private static let compact = true
    #else
    private static let compact = false
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
            .background { backdrop }
            // Shade under the caption so white text reads on any cover.
            .overlay { LinearGradient(stops: [.init(color: .black.opacity(0.15), location: 0), .init(color: .clear, location: 0.3), .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom) }
            .overlay(alignment: .topTrailing) { if room != nil { badge.padding(padding) } }
            .overlay(alignment: .bottomLeading) { caption.padding(padding) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(focused ? 0.95 : 0.1), lineWidth: focused ? 4 : 1) }
            .animation(.easeOut(duration: 0.3), value: room)
            .onAppear { LivePreviews.shared.load(platform) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(platform.name)
    }

    @ViewBuilder private var backdrop: some View {
        ZStack {
            platform.tint
            LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if platform == .douyin {
                RadialGradient(colors: [Color(red: 0.15, green: 0.96, blue: 0.94).opacity(0.35), .clear], center: .topTrailing, startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Color(red: 1.0, green: 0.17, blue: 0.33).opacity(0.35), .clear], center: .bottomLeading, startRadius: 0, endRadius: 260)
            }
            if let cover = room?.cover {
                AsyncImage(url: cover) { phase in
                    if let image = phase.image { image.resizable().scaledToFill().transition(.opacity) }
                }
            }
        }
    }

    private var caption: some View {
        HStack(spacing: padding * 0.7) {
            LivePlatformMark(platform: platform, size: mark)
            details
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(platform.name).font(titleFont).lineLimit(1)
            HStack(spacing: 10) {
                if let room {
                    // A phone's card has room for the audience only.
                    if !Self.compact || room.online == 0 { Text(room.host.isEmpty ? room.title : room.host).lineLimit(1) }
                    if room.online > 0 {
                        Label(room.online.formatted(.number.notation(.compactName)), systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon).lineLimit(1).layoutPriority(1)
                    }
                } else {
                    Text(L10n.text("Built-in"))
                }
            }
            .font(detailFont).foregroundStyle(.white.opacity(0.8))
        }
    }

    private var badge: some View {
        HStack(spacing: 5) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text(L10n.text("LIVE"))
        }
        .font(.caption2.weight(.bold)).foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Brand.rose, in: Capsule())
    }
}

/// A built-in platform's icon: Bilibili's own mark; the others as their initial on the platform's colour.
struct LivePlatformMark: View {
    let platform: LivePlatform
    var size: CGFloat = 44

    var body: some View {
        #if os(tvOS)
        let size = size >= 44 ? max(size, 56) : size
        #endif
        switch platform {
        case .bilibili: BilibiliMark(size: size)
        case .douyu: tile("斗", platform.tint, size: size)
        case .huya: tile("虎", platform.tint, size: size)
        // Douyin's glyph with its cyan and red offsets, on black.
        case .douyin: tile("抖", platform.tint, size: size, split: true)
        }
    }

    private func tile(_ glyph: String, _ color: Color, size: CGFloat, split: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        let offset = split ? size * 0.03 : 0
        return Text(glyph).font(.system(size: size * 0.52, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            .background { Text(glyph).font(.system(size: size * 0.52, weight: .heavy, design: .rounded)).foregroundStyle(Color(red: 0.15, green: 0.96, blue: 0.94)).offset(x: -offset, y: -offset).opacity(split ? 1 : 0) }
            .background { Text(glyph).font(.system(size: size * 0.52, weight: .heavy, design: .rounded)).foregroundStyle(Color(red: 1.0, green: 0.17, blue: 0.33)).offset(x: offset, y: offset).opacity(split ? 1 : 0) }
            .frame(width: size, height: size)
            .background(color, in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

extension View {
    /// The system search, on platforms that can search.
    @ViewBuilder func liveSearchable(_ enabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if enabled && !Self.hidesSearchForScreenshots { catalogSearchable(text: text, prompt: prompt) } else { self }
    }
    /// `-qaHideSearch 1` (debug builds) leaves out the search field, whose tvOS keyboard would fill
    /// the top of website screenshots.
    private static var hidesSearchForScreenshots: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "qaHideSearch")
        #else
        false
        #endif
    }
}
