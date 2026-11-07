import SwiftUI
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

/// The UP主: their picture, name and followers, which open their space, then Follow and, while they are live, Live.
/// `large` is the head of their space itself, with their sign.
struct BilibiliCreatorRow: View {
    @Environment(Store.self) private var store
    let mid: Int
    let name: String
    let client: CatalogClient
    var large = false
    @State private var creator: BilibiliAPI.Creator?
    @State private var following = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                if large {
                    identity
                } else {
                    RouteLink { bilibiliSpace(mid: mid, name: creator?.name ?? name, client: client) } label: { identity }
                        .rowCardButton()
                        .accessibilityIdentifier("bilibili.creator")
                }
                Spacer(minLength: 8)
                if let room = creator?.liveRoom, let channel = bilibiliLiveChannel(room: room, host: creator?.name ?? name) {
                    Button { store.playing = channel } label: { Label(L10n.text("Watch Live"), systemImage: "dot.radiowaves.left.and.right") }
                        .controlButton().tint(Brand.rose)
                        .accessibilityIdentifier("bilibili.live")
                }
                followButton
            }
            if large, let sign = creator?.sign, !sign.isEmpty {
                Text(sign).font(.subheadline).foregroundStyle(.secondary).lineLimit(3).selectable()
            }
            BilibiliNotice(message: $message)
        }
        .animation(.smooth(duration: 0.25), value: creator)
        .task(id: mid) {
            guard let found = try? await BilibiliAPI.creator(mid) else { return }
            creator = found; following = found.following
        }
    }

    private var identity: some View {
        let size = large ? BilibiliMetrics.largeAvatar : BilibiliMetrics.avatar
        return HStack(spacing: 12) {
            Color.clear.frame(width: size, height: size)
                .overlay { PosterImage(url: creator?.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(creator?.name ?? name).font(large ? .title2.weight(.bold) : .headline).lineLimit(1)
                Text(stats).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if !large { Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }
        .padding(large ? 0 : 6)
        .contentShape(Rectangle())
    }

    private var stats: String {
        guard let creator else { return L10n.text("UP主") }
        var parts = [L10n.text("%@ followers", BilibiliAPI.count(creator.fans))]
        if creator.videos > 0 { parts.append(L10n.text("%@ videos", BilibiliAPI.count(creator.videos))) }
        return parts.joined(separator: " · ")
    }

    private var followButton: some View {
        Button { Task { await toggleFollow() } } label: {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: following ? "checkmark" : "plus") }
                Text(following ? L10n.text("Followed") : L10n.text("Follow"))
            }
            .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
        }
        .controlButton(prominent: !following).tint(BilibiliMark.pink)
        .disabled(busy)
        .accessibilityIdentifier("bilibili.follow")
    }

    private func toggleFollow() async {
        guard BilibiliAPI.signedIn else { message = L10n.text("Sign in to Bilibili in Settings first."); return }
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

/// The account's like, coins, favourite and watch later on a video, with its counts, and its comments.
struct BilibiliActionBar: View {
    let bvid: String
    @State private var state: BilibiliAPI.VideoState?
    @State private var busy = false
    @State private var message: String?
    @State private var choosingCoins = false
    @State private var showsComments = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: actionSpacing) {
                action("hand.thumbsup", on: state?.liked == true, count: state?.likes, title: L10n.text("Like")) { await like() }
                    .contextMenu {
                        Button { Task { await triple() } } label: { Label(L10n.text("Like, Coin and Favorite"), systemImage: "sparkles") }
                    }
                    .accessibilityIdentifier("bilibili.like")
                action("bitcoinsign.circle", on: (state?.coined ?? 0) > 0, count: state?.coins, title: L10n.text("Coin")) {
                    guard signedIn() else { return }
                    choosingCoins = true
                }
                .accessibilityIdentifier("bilibili.coin")
                action("star", on: state?.favorited == true, count: state?.favorites, title: L10n.text("Favorite")) { await favorite() }
                    .accessibilityIdentifier("bilibili.favorite")
                action("clock", on: false, count: nil, title: L10n.text("Watch Later")) { await watchLater() }
                    .accessibilityIdentifier("bilibili.later")
                action("text.bubble", on: false, count: state?.replies, title: L10n.text("Comments")) { showsComments = true }
                    .accessibilityIdentifier("bilibili.comments")
            }
            .disabled(state == nil)
            .tvFocusSection()
            BilibiliNotice(message: $message)
        }
        .task(id: bvid) { state = try? await BilibiliAPI.state(bvid: bvid) }
        .confirmationDialog(L10n.text("Coin"), isPresented: $choosingCoins, titleVisibility: .visible) {
            let left = max(0, (state?.maxCoins ?? 2) - (state?.coined ?? 0))
            ForEach(Array(1...max(1, left)), id: \.self) { count in
                Button(count == 1 ? L10n.text("1 Coin") : L10n.text("%lld Coins", count)) { Task { await coin(count) } }
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
        if let state { BilibiliCommentsView(aid: state.aid, total: state.replies) }
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

    private func signedIn() -> Bool {
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

    private func like() async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.like(aid: current.aid, !current.liked)
            state?.liked.toggle()
            state?.likes += current.liked ? -1 : 1
        }
    }

    private func coin(_ count: Int) async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.coin(aid: current.aid, count: count, like: true)
            state?.coined += count; state?.coins += count
            if !current.liked { state?.liked = true; state?.likes += 1 }
        }
    }

    private func favorite() async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.favorite(aid: current.aid, !current.favorited)
            state?.favorited.toggle()
            state?.favorites += current.favorited ? -1 : 1
        }
    }

    private func watchLater() async {
        await perform {
            guard let current = state else { return }
            try await BilibiliAPI.watchLater(aid: current.aid)
            message = L10n.text("Added to Watch Later.")
        }
    }

    private func triple() async {
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
