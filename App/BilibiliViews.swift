import SwiftUI
import ImageIO
import TVCore

// Bilibili's own parts of the source's pages (#256): the UP主 under a video's title, with Follow, and their space;
// the account's like, coins, favourite and watch later on a video; its comments and related videos. Everything here
// loads after the page's own details, so the page never waits for it, and a failure only leaves its part out.

/// The page that lists an UP主's space: the source's category `up_<mid>`, opened as a drive's folder is.
@MainActor func bilibiliSpace(mid: Int, name: String, client: CatalogClient) -> some View {
    SiteView(site: client.site, origin: client.origin, jarURL: client.jarURL,
             folder: Video(id: "up_\(mid)", name: name, category: "folder"))
}

/// A live room of Bilibili's, as the Live tab plays it.
func bilibiliLiveChannel(room: Int, host: String) -> Channel? {
    let scheme = LivePlatform(rawValue: "bilibili")?.scheme ?? "bilibili-live"
    return URL(string: "\(scheme)://room/\(room)").map { Channel(name: host, group: L10n.text("Bilibili Live"), url: $0) }
}

private enum BilibiliMetrics {
    #if os(tvOS)
    static let avatar: CGFloat = 76, largeAvatar: CGFloat = 132, tile: CGFloat = 380
    #else
    static let avatar: CGFloat = 44, largeAvatar: CGFloat = 76, tile: CGFloat = 220
    #endif
}

/// A short note under a row of Bilibili's controls (a refused like, a sign-in needed), gone after a few seconds.
private struct BilibiliNotice: View {
    @Binding var message: String?
    var body: some View {
        if let message {
            Text(message).font(.footnote).foregroundStyle(.secondary).transition(.opacity)
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { self.message = nil }
                }
        }
    }
}

// MARK: UP主

/// An UP主 as their pages show them, and Follow: the creator row and Apple TV's video page share it.
@MainActor @Observable final class BilibiliCreatorModel {
    private(set) var creator: BilibiliAPI.Creator?
    private(set) var following = false
    private(set) var busy = false
    var message: String?

    func load(_ mid: Int) async {
        guard let found = try? await BilibiliAPI.creator(mid) else { return }
        creator = found; following = found.following
    }

    /// Their followers and uploads; "UP主" until they are in.
    var stats: String {
        guard let creator else { return L10n.text("UP主") }
        var parts = [L10n.text("%@ followers", BilibiliAPI.count(creator.fans))]
        if creator.videos > 0 { parts.append(L10n.text("%@ videos", BilibiliAPI.count(creator.videos))) }
        return parts.joined(separator: " · ")
    }

    func toggleFollow(_ mid: Int) async {
        guard BilibiliAPI.signedIn else { message = L10n.text("Sign in to Bilibili in Settings first."); return }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await BilibiliAPI.follow(mid, !following)
            following.toggle()
            if let fans = creator?.fans { creator?.fans = max(0, fans + (following ? 1 : -1)) }
        } catch {
            message = error.localizedDescription
        }
    }
}

/// The UP主: their picture, name and followers, which open their space, then Follow and, while they are live, Live.
/// `large` is the head of their space itself, with their sign.
struct BilibiliCreatorRow: View {
    @Environment(Store.self) private var store
    let mid: Int
    let name: String
    let client: CatalogClient
    var large = false
    @State private var model = BilibiliCreatorModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if large {
                    identity
                } else {
                    RouteLink { bilibiliSpace(mid: mid, name: model.creator?.name ?? name, client: client) } label: { identity }
                        .rowCardButton()
                        .accessibilityIdentifier("bilibili.creator")
                }
                Spacer(minLength: 8)
                if let room = model.creator?.liveRoom, let channel = bilibiliLiveChannel(room: room, host: model.creator?.name ?? name) {
                    Button { store.playing = channel } label: { Label(L10n.text("Watch Live"), systemImage: "dot.radiowaves.left.and.right") }
                        .controlButton().tint(Brand.rose)
                        .accessibilityIdentifier("bilibili.live")
                }
                followButton
            }
            if large, let sign = model.creator?.sign, !sign.isEmpty {
                Text(sign).font(.subheadline).foregroundStyle(.secondary).lineLimit(3).selectable()
            }
            BilibiliNotice(message: Binding(get: { model.message }, set: { model.message = $0 }))
        }
        .animation(.smooth(duration: 0.25), value: model.creator)
        .task(id: mid) { await model.load(mid) }
    }

    private var identity: some View {
        let size = large ? BilibiliMetrics.largeAvatar : BilibiliMetrics.avatar
        return HStack(spacing: 12) {
            Color.clear.frame(width: size, height: size)
                .overlay { PosterImage(url: model.creator?.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(model.creator?.name ?? name).font(large ? .title2.weight(.bold) : .headline).lineLimit(1)
                Text(model.stats).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if !large { Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(large ? 0 : 6)
        .contentShape(Rectangle())
    }

    private var followButton: some View {
        Button { Task { await model.toggleFollow(mid) } } label: {
            HStack(spacing: 6) {
                if model.busy { ProgressView().controlSize(.small) } else { Image(systemName: model.following ? "checkmark" : "plus") }
                Text(model.following ? L10n.text("Followed") : L10n.text("Follow"))
            }
            .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
        }
        .controlButton(prominent: !model.following).tint(BilibiliMark.pink)
        .disabled(model.busy)
        .accessibilityIdentifier("bilibili.follow")
    }
}

/// The head of an UP主's space: who they are, then their uploads by newest, most played or most favourited, or their
/// collections. `category` is the listing showing; `open` shows another.
struct BilibiliSpaceHeader: View {
    let mid: Int
    let name: String
    let client: CatalogClient
    let category: String
    let open: (String) -> Void
    private var tabs: [(id: String, title: String)] {
        [("up_\(mid)", L10n.text("Newest")), ("up_\(mid)_click", L10n.text("Most Played")),
         ("up_\(mid)_stow", L10n.text("Most Favorited")), ("up_\(mid)_lists", L10n.text("Collections"))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BilibiliCreatorRow(mid: mid, name: name, client: client, large: true)
            ChipRow {
                GlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(tabs, id: \.id) { tab in
                            Chip(title: tab.title, selected: category == tab.id) { if category != tab.id { open(tab.id) } }
                        }
                    }
                }.padding(.vertical, 4)
            }
            .tvFocusSection()
        }
    }
}

// MARK: A video

/// A video's counts and the account's like, coins, favourite and watch later on it: the action bar and Apple TV's video
/// page share it.
@MainActor @Observable final class BilibiliVideoActions {
    private(set) var state: BilibiliAPI.VideoState?
    private var busy = false
    var message: String?

    func load(_ bvid: String) async { state = try? await BilibiliAPI.state(bvid: bvid) }

    /// The coins the account may still give the video.
    var coinsLeft: Int { max(0, (state?.maxCoins ?? 2) - (state?.coined ?? 0)) }

    func signedIn() -> Bool {
        if BilibiliAPI.signedIn { return true }
        message = L10n.text("Sign in to Bilibili in Settings first.")
        return false
    }

    private func perform(_ change: () async throws -> Void) async {
        guard signedIn(), !busy, state != nil else { return }
        busy = true
        defer { busy = false }
        do { try await change() } catch { message = error.localizedDescription }
    }

    func like() async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.like(aid: current.aid, !current.liked)
            state?.liked.toggle()
            state?.likes += current.liked ? -1 : 1
        }
    }

    func coin(_ count: Int) async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.coin(aid: current.aid, count: count, like: true)
            state?.coined += count; state?.coins += count
            if !current.liked { state?.liked = true; state?.likes += 1 }
        }
    }

    func favorite() async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.favorite(aid: current.aid, !current.favorited)
            state?.favorited.toggle()
            state?.favorites += current.favorited ? -1 : 1
        }
    }

    func watchLater() async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.watchLater(aid: current.aid)
            message = L10n.text("Added to Watch Later.")
        }
    }

    func triple() async {
        await perform {
            guard let current = state else { return }
            let done = try await BilibiliAPI.triple(aid: current.aid)
            if done.like, !current.liked { state?.liked = true; state?.likes += 1 }
            if done.coins, current.coined < current.maxCoins { state?.coins += current.maxCoins - current.coined; state?.coined = current.maxCoins }
            if done.favorite, !current.favorited { state?.favorited = true; state?.favorites += 1 }
            message = L10n.text("Liked, coined and favorited.")
        }
    }
}

/// The account's like, coins, favourite and watch later on a video, with its counts, and its comments.
struct BilibiliActionBar: View {
    let bvid: String
    @State private var model = BilibiliVideoActions()
    @State private var choosingCoins = false
    @State private var showsComments = false

    var body: some View {
        let state = model.state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: actionSpacing) {
                action("hand.thumbsup", on: state?.liked == true, count: state?.likes, title: L10n.text("Like")) { await model.like() }
                    .contextMenu {
                        Button { Task { await model.triple() } } label: { Label(L10n.text("Like, Coin and Favorite"), systemImage: "sparkles") }
                    }
                    .accessibilityIdentifier("bilibili.like")
                action("bitcoinsign.circle", on: (state?.coined ?? 0) > 0, count: state?.coins, title: L10n.text("Coin")) {
                    guard model.signedIn() else { return }
                    choosingCoins = true
                }
                .accessibilityIdentifier("bilibili.coin")
                action("star", on: state?.favorited == true, count: state?.favorites, title: L10n.text("Favorite")) { await model.favorite() }
                    .accessibilityIdentifier("bilibili.favorite")
                action("clock", on: false, count: nil, title: L10n.text("Watch Later")) { await model.watchLater() }
                    .accessibilityIdentifier("bilibili.later")
                action("text.bubble", on: false, count: state?.replies, title: L10n.text("Comments")) { showsComments = true }
                    .accessibilityIdentifier("bilibili.comments")
            }
            .disabled(state == nil)
            .tvFocusSection()
            BilibiliNotice(message: Binding(get: { model.message }, set: { model.message = $0 }))
        }
        .task(id: bvid) { await model.load(bvid) }
        .confirmationDialog(L10n.text("Coin"), isPresented: $choosingCoins, titleVisibility: .visible) {
            ForEach(Array(1...max(1, model.coinsLeft)), id: \.self) { count in
                Button(count == 1 ? L10n.text("1 Coin") : L10n.text("%lld Coins", count)) { Task { await model.coin(count) } }
            }
        } message: {
            Text(L10n.text("Coins also like the video."))
        }
        #if os(tvOS)
        .fullScreenCover(isPresented: $showsComments) { comments }
        #else
        .sheet(isPresented: $showsComments) { comments }
        #endif
    }

    @ViewBuilder private var comments: some View {
        if let state = model.state { BilibiliCommentsView(aid: state.aid, total: state.replies) }
    }

    private var actionSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        8
        #endif
    }

    private func action(_ symbol: String, on: Bool, count: Int?, title: String, _ run: @escaping @MainActor () async -> Void) -> some View {
        Button { Task { await run() } } label: {
            VStack(spacing: 4) {
                Image(systemName: on ? symbol + ".fill" : symbol).font(.title3)
                    .foregroundStyle(on ? AnyShapeStyle(BilibiliMark.pink) : AnyShapeStyle(.primary))
                Text(count.map { $0 > 0 ? BilibiliAPI.count($0) : title } ?? title).font(.caption).monospacedDigit().lineLimit(1)
            }
            .frame(minWidth: 56).padding(.vertical, 6).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        #if os(tvOS)
        .controlButton()
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(title)
    }
}

/// A video's comments, most liked or newest first, with the replies under each on request.
struct BilibiliCommentsView: View {
    @Environment(\.dismiss) private var dismiss
    let aid: Int
    let total: Int
    @State private var newest = false
    @State private var comments: [BilibiliAPI.Comment] = []
    @State private var next: String?
    @State private var ended = false
    @State private var loading = false
    @State private var error: String?
    @State private var replies: [Int: (list: [BilibiliAPI.Comment], page: Int, more: Bool)] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Picker(L10n.text("Order"), selection: $newest) {
                        Text(L10n.text("Hot")).tag(false)
                        Text(L10n.text("Newest")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    ForEach(comments) { comment in
                        row(comment)
                            .onAppear { if comment.id == comments.last?.id { Task { await load() } } }
                    }
                    if loading { ProgressView().frame(maxWidth: .infinity).padding() }
                    if let error {
                        VStack(spacing: 10) {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            Button(L10n.text("Try Again")) { Task { await load() } }.controlButton()
                        }.frame(maxWidth: .infinity)
                    } else if ended, comments.isEmpty {
                        Text(L10n.text("No comments yet.")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(total > 0 ? L10n.text("Comments (%@)", BilibiliAPI.count(total)) : L10n.text("Comments"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if !os(tvOS)
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 560, idealHeight: 720)
        #endif
        .task(id: newest) {
            comments = []; next = nil; ended = false; replies = [:]; error = nil
            await load()
        }
    }

    private func load() async {
        guard !loading, !ended else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let page = try await BilibiliAPI.comments(aid: aid, newest: newest, cursor: next)
            let known = Set(comments.map(\.id))
            comments += page.comments.filter { !known.contains($0.id) }
            next = page.next; ended = page.next == nil
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func loadReplies(_ comment: BilibiliAPI.Comment) async {
        let page = (replies[comment.id]?.page ?? 0) + 1
        guard let found = try? await BilibiliAPI.replies(aid: aid, root: comment.id, page: page) else { return }
        let earlier = page == 1 ? [] : replies[comment.id]?.list ?? []
        replies[comment.id] = (earlier + found.replies, page, found.more)
    }

    @ViewBuilder private func row(_ comment: BilibiliAPI.Comment) -> some View {
        let loaded = replies[comment.id]
        VStack(alignment: .leading, spacing: 10) {
            BilibiliCommentRow(comment: comment)
            let shown = loaded?.list ?? comment.replies
            if !shown.isEmpty || comment.replyCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(shown) { BilibiliCommentRow(comment: $0, small: true) }
                    if loaded == nil ? comment.replyCount > shown.count : loaded?.more == true {
                        Button(loaded == nil ? L10n.text("%@ replies", BilibiliAPI.count(comment.replyCount)) : L10n.text("More Replies")) {
                            Task { await loadReplies(comment) }
                        }
                        .font(.subheadline.weight(.semibold))
                        #if os(tvOS)
                        .controlButton()
                        #else
                        .buttonStyle(.plain).foregroundStyle(BilibiliMark.blue)
                        #endif
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.leading, 44)
            }
            Divider()
        }
    }
}

private struct BilibiliCommentRow: View {
    let comment: BilibiliAPI.Comment
    var small = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !small {
                Color.clear.frame(width: 34, height: 34)
                    .overlay { PosterImage(url: comment.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(comment.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Text(comment.date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if comment.likes > 0 {
                        Label(BilibiliAPI.count(comment.likes), systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    }
                }
                Text(comment.text).font(small ? .subheadline : .body).fixedSize(horizontal: false, vertical: true).selectable()
            }
        }
        #if os(tvOS)
        // The remote scrolls the list by moving focus through it.
        .focusable()
        #endif
    }
}

/// The videos Bilibili suggests beside this one.
struct BilibiliRelatedRow: View {
    let bvid: String
    let client: CatalogClient
    @State private var videos: [Video] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !videos.isEmpty {
                Text(L10n.text("Related Videos")).font(.headline)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(videos) { video in
                            RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video) }
                                .cardButton()
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.never)
                .scrollClipDisabled()
                .tvFocusSection()
            }
        }
        .task(id: bvid) { videos = (try? await BilibiliAPI.related(bvid: bvid)) ?? [] }
    }
}

/// A Bilibili video as its site shows one: the 16:9 cover, two lines of title, and its length and UP主.
struct BilibiliVideoTile: View {
    let video: Video
    /// A live room: marked as live on its cover.
    var live = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if live {
                        Text(L10n.text("LIVE")).font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(BilibiliMark.pink, in: Capsule()).padding(8)
                    }
                }
            Text(video.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
            if !video.remarks.isEmpty {
                Text(video.remarks).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: BilibiliMetrics.tile)
    }
}

// MARK: Any source

/// The people a source credits, as TVBox shows them. A name the source links (`[a=cr:…]`) opens the source's
/// listing of their works.
struct SourceCreditsRow: View {
    let credits: [VideoCredit]
    let client: CatalogClient
    var body: some View {
        let groups: [(String, [VideoCredit])] = [(L10n.text("Director"), credits.filter { $0.role == .director }),
                                                 (L10n.text("Cast"), credits.filter { $0.role == .actor })].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.0) { title, people in
                ChipRow {
                    HStack(spacing: 8) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(people, id: \.self) { person in
                            if let category = person.category {
                                RouteLink {
                                    SiteView(site: client.site, origin: client.origin, jarURL: client.jarURL,
                                             folder: Video(id: category, name: person.name, category: "folder"))
                                } label: { Label(person.name, systemImage: "person.crop.circle").lineLimit(1) }
                                .controlButton()
                            } else {
                                Text(person.name).font(.subheadline).lineLimit(1)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .tvFocusSection()
            }
        }
    }
}

// MARK: The source's home

/// The Bilibili source's home as its own apps lay it out: rows of what the account follows, what is live, what it
/// saved for later, and what is popular, above the recommendations. Each row asks the source for the first page of
/// one of its lists once the recommendations are in, so the page never waits for them; See All opens the list.
struct BilibiliShelves: View {
    @Environment(Store.self) private var store
    let client: CatalogClient
    /// The recommendations are in: the rows may ask the source now.
    let ready: Bool
    let open: (String) -> Void
    private struct Shelf: Identifiable { let id: String; let title: String; var videos: [Video] }
    @State private var shelves: [Shelf] = []
    @State private var live: [BilibiliAPI.LiveNow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !live.isEmpty {
                shelf(title: L10n.text("Live Now"), more: nil) {
                    ForEach(live) { room in
                        Button { if let channel = bilibiliLiveChannel(room: room.room, host: room.host) { store.playing = channel } } label: {
                            BilibiliVideoTile(video: Video(id: "live_\(room.room)", name: room.title, poster: room.cover,
                                                           posterHeaders: Bilibili.imageHeaders, remarks: room.host), live: true)
                        }
                        .cardButton()
                    }
                }
            }
            ForEach(shelves) { item in
                if !item.videos.isEmpty {
                    shelf(title: item.title, more: item.id) {
                        ForEach(item.videos) { video in
                            RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video) }
                                .cardButton()
                        }
                    }
                }
            }
            if !shelves.filter({ !$0.videos.isEmpty }).isEmpty || !live.isEmpty {
                Text(L10n.text("Recommendations")).font(.title3.weight(.bold))
            }
        }
        .task(id: ready) { if ready { await load() } }
    }

    private func shelf<Content: View>(title: String, more: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.weight(.bold))
                Spacer(minLength: 8)
                if let more {
                    Button(L10n.text("See All")) { open(more) }
                        #if os(tvOS)
                        .controlButton()
                        #else
                        .buttonStyle(.plain).font(.subheadline.weight(.semibold)).foregroundStyle(BilibiliMark.blue)
                        #endif
                }
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16, content: content).padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
        .tvFocusSection()
    }

    private func load() async {
        guard shelves.isEmpty else { return }
        let signedIn = BilibiliAPI.signedIn
        var wanted: [(String, String)] = []
        if signedIn { wanted += [("my_dynamic", L10n.text("Following")), ("my_later", L10n.text("Watch Later"))] }
        wanted += [("popular", L10n.text("Popular")), ("rank_0", L10n.text("Rankings"))]
        shelves = wanted.map { Shelf(id: $0.0, title: $0.1, videos: []) }
        if signedIn { live = (try? await BilibiliAPI.followedLive()) ?? [] }
        // One after another: the source answers one request at a time, and the page's own come first.
        for (index, item) in wanted.enumerated() {
            guard !Task.isCancelled else { return }
            if let page = try? await client.list(category: item.0, query: "", page: 1) { shelves[index].videos = Array(page.videos.prefix(20)) }
        }
    }
}

#if os(tvOS)
// MARK: Apple TV's video page

private enum BilibiliTVMetrics {
    static let gutter: CGFloat = 96
    /// Play and the four action plates under it.
    static let actionsWidth: CGFloat = 540
    static func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Apple TV's page for a Bilibili video (#256), laid out as Discover's title page. Bilibili's covers are much smaller
/// than TMDB's backdrops, so the cover takes the top trailing corner at about its own size and fades into a blur of
/// itself instead of being stretched across the screen. At the foot of the screen: the title, once; the video's facts
/// in one line; Play with the account's like, coins and favourite (the rest under More) on the leading side, and who
/// made it and what they wrote on the trailing side. Below: its parts when it has several, hot comments, related videos.
struct BilibiliTVVideoPage<Play: View, Parts: View, Status: View>: View {
    @Environment(Store.self) private var store
    let bvid: String
    let title: String
    let cover: URL?
    let coverHeaders: [String: String]
    /// The source's synopsis, until Bilibili's own description is in.
    let synopsis: String
    let creator: (mid: Int, name: String)?
    let client: CatalogClient
    /// In Yingxia's own favourites (the heart elsewhere in the app), not Bilibili's.
    let saved: Bool
    let toggleSaved: () -> Void
    let download: () -> Void
    /// More than one part: the parts row shows.
    let hasParts: Bool
    @ViewBuilder let play: Play
    @ViewBuilder let parts: Parts
    /// The page's notices: a playback that failed, episodes queued for download.
    @ViewBuilder let status: Status
    @State private var actions = BilibiliVideoActions()
    @State private var maker = BilibiliCreatorModel()
    @State private var hotComments: [BilibiliAPI.Comment] = []
    @State private var related: [Video] = []
    @State private var scrolled = false
    @State private var showsComments = false
    @State private var showsDescription = false
    /// Frames from the video for the backdrop's wall, cut while the page is already up.
    @State private var frames: [CGImage] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 60) {
                hero
                if hasParts { parts.padding(.horizontal, BilibiliTVMetrics.gutter).focusSection() }
                if !hotComments.isEmpty { commentsRow }
                if !related.isEmpty { relatedRow }
            }
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
        .modifier(DiscoverTVScrolled(scrolled: $scrolled))
        .background {
            BilibiliTVBackdrop(cover: cover, headers: coverHeaders, frames: frames, frosted: scrolled,
                               drifts: !scrolled && scenePhase == .active && !reduceMotion && !showsComments && !showsDescription)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .animation(.smooth(duration: 0.35), value: actions.state)
        .task(id: bvid) {
            async let suggested = BilibiliAPI.related(bvid: bvid)
            await actions.load(bvid)
            if let aid = actions.state?.aid, let page = try? await BilibiliAPI.comments(aid: aid, newest: false, cursor: nil) {
                hotComments = Array(page.comments.prefix(12))
            }
            related = (try? await suggested) ?? []
        }
        .task(id: bvid) { frames = await BilibiliFrames.load(bvid: bvid, count: 28) }
        .task(id: creator?.mid) { if let mid = creator?.mid { await maker.load(mid) } }
        .fullScreenCover(isPresented: $showsComments) {
            if let state = actions.state { BilibiliCommentsView(aid: state.aid, total: state.replies) }
        }
        .fullScreenCover(isPresented: $showsDescription) { descriptionScreen }
    }

    /// Bilibili's description, else the source's synopsis; Bilibili's "-" stands for none.
    private var summary: String {
        if let text = actions.state?.summary, !text.isEmpty { return text }
        let text = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "-" ? "" : text
    }

    /// 1:15 · 42.8万次播放 · 1240条弹幕 · 2025年3月1日
    private var facts: String {
        guard let state = actions.state else { return "" }
        var parts: [String] = []
        if state.duration > 0 { parts.append(BilibiliTVMetrics.clock(state.duration)) }
        if state.views > 0 { parts.append(L10n.text("%@ views", BilibiliAPI.count(state.views))) }
        if state.danmaku > 0 { parts.append(L10n.text("%@ danmaku", BilibiliAPI.count(state.danmaku))) }
        if let date = state.published { parts.append(date.formatted(.dateTime.year().month().day())) }
        return parts.joined(separator: " · ")
    }

    // MARK: The hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 24) {
            status.frame(maxWidth: 1200, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 64, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
                    .frame(maxWidth: 1300, alignment: .leading)
                    .shadow(color: .black.opacity(0.45), radius: 12)
                // A line kept while the facts load, so the page doesn't move when they come in.
                Text(facts.isEmpty ? " " : facts).font(.system(size: 28, weight: .medium)).lineLimit(1).opacity(0.7)
            }
            HStack(alignment: .top, spacing: 72) {
                videoActions.frame(width: BilibiliTVMetrics.actionsWidth).focusSection()
                about.frame(maxWidth: .infinity, alignment: .leading).focusSection()
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, BilibiliTVMetrics.gutter)
        .frame(maxWidth: .infinity, minHeight: 940, alignment: .bottomLeading)
    }

    /// Play, then the account's like, coins and favourite as glass plates with their counts under them, and More.
    private var videoActions: some View {
        let state = actions.state
        return VStack(alignment: .leading, spacing: 22) {
            play
            HStack(alignment: .top, spacing: 16) {
                plate("hand.thumbsup", on: state?.liked == true, count: state?.likes, title: L10n.text("Like"), id: "bilibili.like") {
                    Task { await actions.like() }
                }
                .disabled(state == nil)
                // A menu, not a dialog: a confirmation dialog on a pushed page hangs tvOS 27 (#272).
                plateMenu("bitcoinsign.circle", on: (state?.coined ?? 0) > 0, caption: caption(state?.coins, L10n.text("Coin")),
                          title: L10n.text("Coin"), id: "bilibili.coin") {
                    Section(L10n.text("Coins also like the video.")) {
                        ForEach(Array(1...max(1, actions.coinsLeft)), id: \.self) { count in
                            Button(count == 1 ? L10n.text("1 Coin") : L10n.text("%lld Coins", count)) { Task { await actions.coin(count) } }
                        }
                    }
                }
                .disabled(state == nil)
                plate("star", on: state?.favorited == true, count: state?.favorites, title: L10n.text("Favorite"), id: "bilibili.favorite") {
                    Task { await actions.favorite() }
                }
                .disabled(state == nil)
                plateMenu("ellipsis", on: false, caption: L10n.text("More"), title: L10n.text("More"), id: "bilibili.more") {
                    Button { Task { await actions.watchLater() } } label: { Label(L10n.text("Watch Later"), systemImage: "clock") }
                    Button { Task { await actions.triple() } } label: { Label(L10n.text("Like, Coin and Favorite"), systemImage: "sparkles") }
                    Divider()
                    Button(action: download) { Label(L10n.text("Download"), systemImage: "arrow.down.circle") }
                    Button(action: toggleSaved) {
                        Label(saved ? L10n.text("Remove from Yingxia Favorites") : L10n.text("Add to Yingxia Favorites"),
                              systemImage: saved ? "heart.slash" : "heart")
                    }
                }
            }
            BilibiliNotice(message: Binding(get: { actions.message }, set: { actions.message = $0 }))
                .font(.system(size: 24))
        }
    }

    private func caption(_ count: Int?, _ title: String) -> String { count.map { $0 > 0 ? BilibiliAPI.count($0) : title } ?? title }

    private func glyph(_ symbol: String, on: Bool) -> some View {
        Group {
            if on { Image(systemName: symbol + ".fill").foregroundStyle(BilibiliMark.pink) } else { Image(systemName: symbol) }
        }
        .frame(maxWidth: .infinity)
    }

    private func plate(_ symbol: String, on: Bool, count: Int?, title: String, id: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Button(action: action) { glyph(symbol, on: on) }
                .buttonStyle(DiscoverTVActionStyle(height: 76, font: 30, corner: 24))
                .accessibilityLabel(title).accessibilityIdentifier(id)
            plateCaption(caption(count, title))
        }
    }

    private func plateMenu<Content: View>(_ symbol: String, on: Bool, caption: String, title: String, id: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Menu(content: content) { glyph(symbol, on: on) }
                .menuStyle(.button).buttonStyle(DiscoverTVActionStyle(height: 76, font: 30, corner: 24))
                .accessibilityLabel(title).accessibilityIdentifier(id)
            plateCaption(caption)
        }
    }

    private func plateCaption(_ text: String) -> some View {
        Text(text).font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).opacity(0.6)
    }

    /// Who made it, with Follow, and what they wrote, which opens in full.
    private var about: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let creator {
                let name = maker.creator?.name ?? creator.name
                HStack(spacing: 18) {
                    RouteLink { bilibiliSpace(mid: creator.mid, name: name, client: client) } label: {
                        HStack(spacing: 18) {
                            Color.clear.frame(width: 64, height: 64)
                                .overlay { PosterImage(url: maker.creator?.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.system(size: 28, weight: .semibold))
                                Text(maker.stats).font(.system(size: 22)).opacity(0.65)
                            }
                            Image(systemName: "chevron.forward").font(.system(size: 22, weight: .semibold)).opacity(0.45)
                        }
                        .padding(.leading, -2).padding(.trailing, 8)
                    }
                    .buttonStyle(DiscoverTVActionStyle(height: 96, font: 28))
                    .accessibilityIdentifier("bilibili.creator")
                    if let room = maker.creator?.liveRoom, let channel = bilibiliLiveChannel(room: room, host: name) {
                        Button { store.playing = channel } label: { Label(L10n.text("Watch Live"), systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(DiscoverTVActionStyle(height: 76, font: 26))
                            .accessibilityIdentifier("bilibili.live")
                    }
                    Button { Task { await maker.toggleFollow(creator.mid) } } label: {
                        HStack(spacing: 10) {
                            if maker.busy { ProgressView() } else { Image(systemName: maker.following ? "checkmark" : "plus") }
                            Text(maker.following ? L10n.text("Followed") : L10n.text("Follow"))
                        }
                    }
                    .buttonStyle(DiscoverTVActionStyle(height: 76, font: 26))
                    .accessibilityIdentifier("bilibili.follow")
                }
                BilibiliNotice(message: Binding(get: { maker.message }, set: { maker.message = $0 })).font(.system(size: 24))
            }
            if !summary.isEmpty {
                Button { showsDescription = true } label: {
                    Text(summary).font(.system(size: 26)).lineSpacing(4).lineLimit(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                .buttonStyle(BilibiliTVPlateStyle())
                // The plate's padding outside the column, so the text lines up with the UP主 above it.
                .padding(.leading, -BilibiliTVPlateStyle.inset)
                .accessibilityIdentifier("bilibili.description")
            }
        }
    }

    // MARK: The rows

    private func row(_ title: String, spacing: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 34, weight: .medium)).opacity(0.6).padding(.horizontal, BilibiliTVMetrics.gutter)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) { content() }
                    .padding(.horizontal, BilibiliTVMetrics.gutter).padding(.vertical, 24)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private var commentsRow: some View {
        let total = actions.state?.replies ?? 0
        return row(total > 0 ? L10n.text("Comments (%@)", BilibiliAPI.count(total)) : L10n.text("Comments"), spacing: 32) {
            ForEach(hotComments) { comment in
                Button { showsComments = true } label: { BilibiliTVCommentCard(comment: comment) }
                    .buttonStyle(BilibiliTVPlateStyle(resting: true))
                    .accessibilityIdentifier("bilibili.comment")
            }
        }
    }

    private var relatedRow: some View {
        row(L10n.text("Related Videos"), spacing: 40) {
            ForEach(related) { video in
                RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video) }
                    .cardButton()
            }
        }
    }

    /// The whole description, over the frosted cover: the hero shows three lines of it.
    private var descriptionScreen: some View {
        ZStack(alignment: .bottomLeading) {
            BilibiliTVBackdrop(cover: cover, headers: coverHeaders, frames: frames, frosted: true, drifts: false)
            VStack(alignment: .leading, spacing: 24) {
                Text(title).font(.system(size: 52, weight: .bold)).lineLimit(2)
                if !facts.isEmpty { Text(facts).font(.system(size: 26)).opacity(0.6) }
                Text(summary).font(.system(size: 30)).lineSpacing(6).lineLimit(16)
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(BilibiliTVMetrics.gutter)
            // Something must hold focus for Menu to close the page.
            .focusable()
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

/// The video page's backdrop: the cover at the top trailing corner, at about the size Bilibili sends it, fading into a
/// wall of the video's own frames (a blur of the cover until they're in, or when Bilibili has none); darker toward the
/// text; frosted once the page scrolls past its hero.
private struct BilibiliTVBackdrop: View {
    let cover: URL?
    let headers: [String: String]
    let frames: [CGImage]
    let frosted: Bool
    /// The wall drifts: the hero is in view and nothing covers it.
    let drifts: Bool
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 0.7
            ZStack(alignment: .topTrailing) {
                Color.black
                if let cover {
                    TMDBArtwork(url: cover, maxPixels: 1600, headers: headers)
                        .blur(radius: 70).scaleEffect(1.25).opacity(0.55)
                }
                if !frames.isEmpty {
                    BilibiliFrameWall(frames: frames, active: drifts).opacity(0.32)
                }
                if let cover {
                    TMDBArtwork(url: cover, maxPixels: 1600, headers: headers)
                        .frame(width: width, height: width * 9 / 16).clipped()
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                                             startPoint: .leading, endPoint: .trailing))
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                }
                LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.45), location: 0.45),
                                       .init(color: .clear, location: 0.75)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .clear, location: 0.25), .init(color: .black.opacity(0.9), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(.regularMaterial).opacity(frosted ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: frosted)
    }
}

/// A hot comment on the video page: who wrote it, its likes and three lines of it. Any of them opens all the comments.
private struct BilibiliTVCommentCard: View {
    let comment: BilibiliAPI.Comment
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 44, height: 44)
                    .overlay { PosterImage(url: comment.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                    .clipShape(Circle())
                Text(comment.name).font(.system(size: 24, weight: .semibold)).lineLimit(1).opacity(0.75)
                Spacer(minLength: 8)
                if comment.likes > 0 {
                    Label(BilibiliAPI.count(comment.likes), systemImage: "hand.thumbsup").font(.system(size: 22)).monospacedDigit().opacity(0.6)
                }
            }
            Text(comment.text).font(.system(size: 26)).lineSpacing(4).lineLimit(3).multilineTextAlignment(.leading)
        }
        .frame(width: 600, height: 165, alignment: .topLeading)
    }
}

/// Text that opens more of itself (the description, a comment): bare, or on a faint plate, until focused; then a
/// lifted white plate with dark text, as Discover's actions turn.
private struct BilibiliTVPlateStyle: ButtonStyle {
    static let inset: CGFloat = 24
    /// A faint plate while unfocused, for cards in a row.
    var resting = false
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration, resting: resting) }
    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        let resting: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(BilibiliTVPlateStyle.inset)
                .background {
                    if focused { shape.fill(.white) } else if resting { shape.fill(.white.opacity(0.08)) }
                }
                .scaleEffect(configuration.isPressed ? 0.98 : focused ? 1.04 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// Frames from a video for its page's wall: about `count` of them, evenly through it, cut from Bilibili's preview sheets
/// off the main thread. Each is copied out of its sheet, so the sheet (a 4800 × 2700 picture) isn't kept.
enum BilibiliFrames {
    static func load(bvid: String, count wanted: Int) async -> [CGImage] {
        guard let shot = try? await BilibiliAPI.videoshot(bvid: bvid), shot.count > 2 else { return [] }
        // The first frame is often a fade from black.
        let usable = shot.count - 1, taken = min(wanted, usable)
        let picks = (0..<taken).map { 1 + $0 * usable / taken }
        let perSheet = shot.columns * shot.rows
        var frames: [CGImage] = []
        for (number, sheet) in shot.sheets.enumerated() {
            let cells = picks.filter { $0 / perSheet == number }.map { $0 % perSheet }
            guard !cells.isEmpty, !Task.isCancelled, let (data, _) = try? await URLSession.shared.data(from: sheet) else { continue }
            let columns = shot.columns, rows = shot.rows
            frames += await Task.detached(priority: .utility) { cut(data, cells: cells, columns: columns, rows: rows) }.value
        }
        return frames
    }

    private static func cut(_ data: Data, cells: [Int], columns: Int, rows: Int) -> [CGImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let width = sheet.width / columns, height = sheet.height / rows
        guard width > 0, height > 0 else { return [] }
        return cells.compactMap { cell in
            let rect = CGRect(x: cell % columns * width, y: cell / columns * height, width: width, height: height)
            guard let frame = sheet.cropping(to: rect),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }
    }
}

/// The video's frames as a wall behind its cover: straight columns of them, every other one set half a frame lower,
/// drifting slowly upward as the person page's wall does (untilted here). Each frame fades in as it's placed.
private struct BilibiliFrameWall: UIViewRepresentable {
    let frames: [CGImage]
    let active: Bool
    func makeUIView(context: Context) -> BilibiliFrameWallView { BilibiliFrameWallView() }
    func updateUIView(_ view: BilibiliFrameWallView, context: Context) { view.update(frames: frames, active: active) }
    static func dismantleUIView(_ view: BilibiliFrameWallView, coordinator: ()) { view.stop() }
}

private final class BilibiliFrameWallView: UIView {
    private static let tile = CGSize(width: 320, height: 180), gap: CGFloat = 12
    /// The pattern repeats every four rows, so drifting by four rows loops seamlessly.
    private static let rows = 9, period = 4
    private let canvas = CALayer()
    private var tiles: [CALayer] = []
    private var frames: [CGImage] = []
    private var columns = 0
    private var active = false
    private var cycle: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.masksToBounds = true
        layer.addSublayer(canvas)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(frames: [CGImage], active: Bool) {
        self.active = active
        let changed = frames.count != self.frames.count || zip(frames, self.frames).contains { $0 !== $1 }
        if changed {
            self.frames = frames
            place(fading: true)
        }
        animate()
    }

    func stop() { canvas.removeAnimation(forKey: "drift") }

    /// Neighbours across differ by one frame, and down by a row's worth, so no frame repeats near itself.
    private func frame(at index: Int) -> CGImage? {
        guard !frames.isEmpty, columns > 0 else { return nil }
        let column = index / Self.rows, row = index % Self.rows
        return frames[(column + (row % Self.period) * columns) % frames.count]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        guard size.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let tile = Self.tile, step = tile.height + Self.gap
        let wanted = Int(size.width / (tile.width + Self.gap)) + 2
        let relayout = wanted != columns
        columns = wanted
        while tiles.count < columns * Self.rows {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspectFill; layer.masksToBounds = true; layer.cornerRadius = 12; layer.cornerCurve = .continuous
            layer.backgroundColor = CGColor(gray: 1, alpha: 0.04)
            canvas.addSublayer(layer); tiles.append(layer)
        }
        let width = CGFloat(columns) * (tile.width + Self.gap) - Self.gap
        canvas.frame = CGRect(x: (size.width - width) / 2, y: -step, width: width, height: CGFloat(Self.rows) * step)
        for (index, layer) in tiles.enumerated() {
            let column = index / Self.rows, row = index % Self.rows
            layer.isHidden = column >= columns
            layer.frame = CGRect(x: CGFloat(column) * (tile.width + Self.gap),
                                 y: CGFloat(row) * step + (column % 2 == 1 ? step / 2 : 0), width: tile.width, height: tile.height)
        }
        if relayout { place(fading: false) }
        if cycle != step * CGFloat(Self.period) { cycle = step * CGFloat(Self.period); canvas.removeAnimation(forKey: "drift") }
        animate()
    }

    /// Puts each tile's frame on it; fresh frames fade in one after another across the wall.
    private func place(fading: Bool) {
        let now = CACurrentMediaTime()
        for (index, layer) in tiles.enumerated() where !layer.isHidden {
            layer.contents = frame(at: index)
            guard fading, layer.contents != nil else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.6
            fade.beginTime = now + Double(index % Self.rows + index / Self.rows) * 0.06
            fade.fillMode = .backwards
            layer.add(fade, forKey: "fade")
        }
    }

    private func animate() {
        guard active, !frames.isEmpty, cycle > 0 else { canvas.removeAnimation(forKey: "drift"); return }
        guard canvas.animation(forKey: "drift") == nil else { return }
        let drift = CABasicAnimation(keyPath: "transform.translation.y")
        drift.fromValue = 0; drift.toValue = -cycle
        drift.duration = 120; drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .linear)
        canvas.add(drift, forKey: "drift")
    }
}
#endif
