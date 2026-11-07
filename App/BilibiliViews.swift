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
    #elseif os(iOS)
    static let avatar: CGFloat = 40, largeAvatar: CGFloat = 88, tile: CGFloat = DiscoverLayout.landscapeWidth
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
    /// Follow needs the account: Apple TV opens the sign-in screen rather than saying so.
    var needsSignIn = false

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
        guard BilibiliAPI.signedIn else { message = L10n.text("Sign in to Bilibili in Settings first."); needsSignIn = true; return }
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
        #if os(iOS)
        phoneBody
        #else
        standardBody
        #endif
    }

    private var standardBody: some View {
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
                if model.busy { ProgressView().appControlSize(.small) } else { Image(systemName: model.following ? "checkmark" : "plus") }
                Text(model.following ? L10n.text("Followed") : L10n.text("Follow"))
            }
            .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
        }
        .controlButton(prominent: !model.following).tint(BilibiliMark.pink)
        .disabled(model.busy)
        .accessibilityIdentifier("bilibili.follow")
    }

    #if os(iOS)
    /// Under a video: one slim row, their picture, name and followers (which open their space), then Follow as a small
    /// pink capsule. At the head of their space: a centred portrait of them, as the Apple TV space page's hero.
    private var phoneBody: some View {
        let shownName = model.creator?.name ?? name
        return Group {
            if large {
                VStack(spacing: 6) {
                    avatar(BilibiliMetrics.largeAvatar).padding(.bottom, 6)
                    Text(shownName).font(.title2.weight(.bold)).lineLimit(1)
                    Text(model.stats).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    if let sign = model.creator?.sign, !sign.isEmpty {
                        Text(sign).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                            .padding(.horizontal, 12).padding(.top, 2).selectable()
                    }
                    HStack(spacing: 10) { liveCapsule(shownName); followCapsule }.padding(.top, 10)
                    BilibiliNotice(message: Binding(get: { model.message }, set: { model.message = $0 }))
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        RouteLink { bilibiliSpace(mid: mid, name: shownName, client: client) } label: {
                            HStack(spacing: 10) {
                                avatar(BilibiliMetrics.avatar)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shownName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                    Text(model.stats).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bilibili.creator")
                        liveCapsule(shownName)
                        followCapsule
                    }
                    BilibiliNotice(message: Binding(get: { model.message }, set: { model.message = $0 }))
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.creator)
        .task(id: mid) { await model.load(mid) }
    }

    private func avatar(_ size: CGFloat) -> some View {
        Color.clear.frame(width: size, height: size)
            .overlay { PosterImage(url: model.creator?.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }

    /// A small capsule: filled with `tint` for the one thing to do, quiet glass otherwise.
    private func capsule(_ title: String, symbol: String, filled: Bool, tint: Color, busy: Bool = false) -> some View {
        HStack(spacing: 4) {
            if busy { ProgressView().appControlSize(.mini).tint(filled ? .white : nil) } else { Image(systemName: symbol).font(.caption.weight(.bold)) }
            Text(title)
        }
        .font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
        .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14).frame(height: 34)
        .glassOrFill(filled ? GlassStyle.regular.tint(tint).interactive() : .regular.interactive(),
                     filled ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Capsule())
        .contentShape(Capsule())
    }

    @ViewBuilder private func liveCapsule(_ host: String) -> some View {
        if let room = model.creator?.liveRoom, let channel = bilibiliLiveChannel(room: room, host: host) {
            Button { store.playing = channel } label: {
                capsule(L10n.text("Watch Live"), symbol: "dot.radiowaves.left.and.right", filled: true, tint: Brand.rose)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bilibili.live")
        }
    }

    private var followCapsule: some View {
        Button { Task { await model.toggleFollow(mid) } } label: {
            capsule(model.following ? L10n.text("Followed") : L10n.text("Follow"), symbol: model.following ? "checkmark" : "plus",
                    filled: !model.following, tint: BilibiliMark.pink, busy: model.busy)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityIdentifier("bilibili.follow")
    }
    #endif
}

/// The head of an UP主's space: who they are, then their uploads by newest, most played or most favourited, or their
/// collections. `category` is the listing showing; `open` shows another.
struct BilibiliSpaceHeader: View {
    let mid: Int
    let name: String
    let client: CatalogClient
    let category: String
    let open: (String) -> Void
    private var tabs: [(id: String, title: String)] { Self.tabs(mid) }
    /// The space's listings: uploads by newest, most played or most favourited, and collections.
    static func tabs(_ mid: Int) -> [(id: String, title: String)] {
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
    /// An action that needs the account: Apple TV opens the sign-in screen rather than saying so.
    var needsSignIn = false

    func load(_ bvid: String) async { state = try? await BilibiliAPI.state(bvid: bvid) }

    /// The coins the account may still give the video.
    var coinsLeft: Int { max(0, (state?.maxCoins ?? 2) - (state?.coined ?? 0)) }

    func signedIn() -> Bool {
        if BilibiliAPI.signedIn { return true }
        message = L10n.text("Sign in to Bilibili in Settings first.")
        needsSignIn = true
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
    /// Apple TV: the video's cover, frosted behind the list.
    var cover: URL? = nil
    var coverHeaders: [String: String] = [:]
    @State private var newest = false
    @State private var comments: [BilibiliAPI.Comment] = []
    @State private var next: String?
    @State private var ended = false
    @State private var loading = false
    @State private var error: String?
    @State private var replies: [Int: (list: [BilibiliAPI.Comment], page: Int, more: Bool)] = [:]

    var body: some View {
        #if os(tvOS)
        tvBody.task(id: newest) {
            comments = []; next = nil; ended = false; replies = [:]; error = nil
            await load()
        }
        #else
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
            .navigationTitle(title)
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
        #endif
    }

    private var title: String { total > 0 ? L10n.text("Comments (%@)", BilibiliAPI.count(total)) : L10n.text("Comments") }

    #if os(tvOS)
    /// Apple TV: a full-screen list over the frosted cover, as Bilibili's TV clients show comments. Every comment and
    /// reply is a row of its own the remote moves through; replies sit indented under theirs, and a row loads more.
    private var tvBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                // One line: the count, then the order.
                HStack(alignment: .center, spacing: 28) {
                    Text(title).font(.system(size: 34, weight: .bold))
                    HStack(spacing: 8) {
                        ForEach([false, true], id: \.self) { order in
                            Button(order ? L10n.text("Newest") : L10n.text("Hot")) { newest = order }
                                .buttonStyle(BilibiliTVTabStyle(selected: newest == order, compact: true))
                        }
                    }
                    .focusSection()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24).padding(.bottom, 10)
                ForEach(comments) { comment in
                    tvThread(comment)
                        .onAppear { if comment.id == comments.last?.id { Task { await load() } } }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding(40) }
                if let error {
                    VStack(spacing: 18) {
                        Text(error).font(.system(size: 26)).opacity(0.6)
                        Button(L10n.text("Try Again")) { Task { await load() } }
                            .buttonStyle(DiscoverTVActionStyle(height: 72, font: 26))
                    }
                    .frame(maxWidth: .infinity).padding(40)
                } else if ended, comments.isEmpty {
                    Text(L10n.text("No comments yet.")).font(.system(size: 28)).opacity(0.6).frame(maxWidth: .infinity).padding(60)
                }
            }
            .padding(.horizontal, 110).padding(.top, 36).padding(.bottom, 60)
        }
        .scrollClipDisabled()
        .background { BilibiliTVBackdrop(cover: cover, headers: coverHeaders, frosted: true) }
        .foregroundStyle(.white).preferredColorScheme(.dark)
    }

    @ViewBuilder private func tvThread(_ comment: BilibiliAPI.Comment) -> some View {
        let loaded = replies[comment.id]
        let shown = loaded?.list ?? comment.replies
        let more = loaded == nil ? comment.replyCount > shown.count : loaded?.more == true
        // Pressing a comment shows its replies, as its replies row does.
        Button { if more { Task { await loadReplies(comment) } } } label: { tvLine(comment, small: false) }
            .buttonStyle(BilibiliTVRowStyle())
            .accessibilityIdentifier("bilibili.comments.row")
        ForEach(shown) { reply in
            Button {} label: { tvLine(reply, small: true) }
                .buttonStyle(BilibiliTVRowStyle()).padding(.leading, 76)
        }
        if more {
            Button { Task { await loadReplies(comment) } } label: {
                Label(loaded == nil ? L10n.text("%@ replies", BilibiliAPI.count(comment.replyCount)) : L10n.text("More Replies"),
                      systemImage: "chevron.down")
                    .font(.system(size: 22, weight: .semibold)).opacity(0.7)
            }
            .buttonStyle(BilibiliTVRowStyle(compact: true)).padding(.leading, 76)
        }
    }

    private func tvLine(_ comment: BilibiliAPI.Comment, small: Bool) -> some View {
        let size: CGFloat = small ? 44 : 56
        return HStack(alignment: .top, spacing: 20) {
            Color.clear.frame(width: size, height: size)
                .overlay { PosterImage(url: comment.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    Text(comment.name).font(.system(size: 24, weight: .semibold)).lineLimit(1).opacity(0.8)
                    Text(comment.date, format: .relative(presentation: .named)).font(.system(size: 22)).opacity(0.45)
                    if comment.likes > 0 {
                        Label(BilibiliAPI.count(comment.likes), systemImage: "hand.thumbsup").font(.system(size: 22)).monospacedDigit().opacity(0.5)
                    }
                }
                Text(comment.text).font(.system(size: small ? 26 : 28)).lineSpacing(5)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
    #endif

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
            #if os(iOS)
            Color.clear.frame(height: 4)
            #else
            Divider()
            #endif
        }
    }
}

private struct BilibiliCommentRow: View {
    let comment: BilibiliAPI.Comment
    var small = false
    var body: some View {
        #if os(iOS)
        phone
        #else
        standard
        #endif
    }

    #if os(iOS)
    private var phone: some View {
        HStack(alignment: .top, spacing: 10) {
            if !small {
                Color.clear.frame(width: 34, height: 34)
                    .overlay { PosterImage(url: comment.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                    .clipShape(Circle())
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(comment.name).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Text(comment.date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.tertiary)
                }
                Text(comment.text).font(small ? .subheadline : .body).fixedSize(horizontal: false, vertical: true).selectable()
                if comment.likes > 0 {
                    Label(BilibiliAPI.count(comment.likes), systemImage: "hand.thumbsup").font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

    private var standard: some View {
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
                    LazyHStack(alignment: .top, spacing: railSpacing) {
                        ForEach(videos) { video in
                            RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video) }
                                .cardButton()
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.never)
                .scrollClipDisabled()
                #if os(iOS)
                // Edge to edge, as the episodes above: the covers start at the page's margin and run off the screen.
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
                #endif
                .tvFocusSection()
            }
        }
        .task(id: bvid) { videos = (try? await BilibiliAPI.related(bvid: bvid)) ?? [] }
    }

    private var railSpacing: CGFloat {
        #if os(iOS)
        DiscoverLayout.spacing
        #else
        16
        #endif
    }
}

/// A Bilibili video as its site shows one: the 16:9 cover, two lines of title, and its length and UP主.
struct BilibiliVideoTile: View {
    let video: Video
    /// A live room: marked as live on its cover.
    var live = false
    /// Its width in a row; nil in a grid, whose column sets it.
    var width: CGFloat? = BilibiliMetrics.tile
    var body: some View {
        #if os(iOS)
        // Discover's landscape card: the cover with a hairline edge, two lines of title and a quiet line under them.
        VStack(alignment: .leading, spacing: 7) {
            cover(corner: 12)
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 3) {
                Text(video.name).font(.system(size: DiscoverLayout.caption, weight: .medium)).foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                Text(video.remarks.isEmpty ? " " : video.remarks).font(.system(size: DiscoverLayout.secondary, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.56)).lineLimit(1)
            }
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
        #else
        standard
        #endif
    }

    private func cover(corner: CGFloat) -> some View {
        Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
            .posterClip(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(alignment: .topLeading) {
                if live {
                    Text(L10n.text("LIVE")).font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(BilibiliMark.pink, in: Capsule()).padding(8)
                }
            }
    }

    private var standard: some View {
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
        .frame(width: width)
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
        #if os(tvOS)
        tvBody
        #else
        // Watch Now's and Discover's rows: a heading that opens the whole list, then landscape covers running off the
        // screen. The rows reach into the page's margin by Discover's gutter, so their headings line up with the page.
        VStack(alignment: .leading, spacing: 26) {
            if !live.isEmpty {
                WatchNowPhoneShelf(title: L10n.text("Live Now")) {
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
                    WatchNowPhoneShelf(title: item.title, action: { open(item.id) }) {
                        ForEach(item.videos) { video in
                            RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video) }
                                .cardButton()
                        }
                    }
                    .accessibilityIdentifier("bilibili.shelf." + item.id)
                }
            }
            if !shelves.filter({ !$0.videos.isEmpty }).isEmpty || !live.isEmpty {
                WatchNowPhoneHeading(title: L10n.text("Recommendations"))
            }
        }
        .padding(.horizontal, -DiscoverLayout.gutter)
        .task(id: ready) { if ready { await load() } }
        #endif
    }

    #if os(tvOS)
    /// Watch Now's and Discover's rows: their covers (16:9 here), captions that move with the lift, and See All waiting
    /// to the left of the first cover. The rows reach into the page's margin by Discover's gutter, so their covers line
    /// up with the page and See All's sliver sits inside the row, where focus can reach it.
    private var tvBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !live.isEmpty {
                WatchNowTVRail(title: L10n.text("Live Now")) {
                    ForEach(live) { room in
                        Button { if let channel = bilibiliLiveChannel(room: room.room, host: room.host) { store.playing = channel } } label: {
                            WatchNowTVCover(title: room.title, detail: room.host, poster: room.cover, headers: Bilibili.imageHeaders,
                                            landscape: true, badge: (L10n.text("LIVE"), BilibiliMark.pink))
                        }
                        .cardButton()
                    }
                }
            }
            ForEach(shelves) { item in
                if !item.videos.isEmpty {
                    WatchNowTVRail(title: item.title, seeAll: WatchNowTVSeeAll(height: WatchNowTVCover.landscapeHeight) { open(item.id) }) {
                        ForEach(item.videos) { video in
                            RouteLink { CatalogDestination(video: video, client: client) } label: {
                                WatchNowTVCover(title: video.name, detail: video.remarks, poster: video.poster, headers: video.posterHeaders, landscape: true)
                            }
                            .cardButton()
                        }
                    }
                }
            }
            if !shelves.filter({ !$0.videos.isEmpty }).isEmpty || !live.isEmpty {
                WatchNowTVHeading(title: L10n.text("Recommendations"))
            }
        }
        .padding(.horizontal, -DiscoverLayout.gutter)
        .task(id: ready) { if ready { await load() } }
    }
    #endif

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

#if os(iOS)
// MARK: iPhone's video page

/// A Bilibili video's page under the iPhone's player, in the Apple TV page's order and manner: the title once, one quiet
/// line of facts, the UP主 with Follow, the account's actions as one row of glass plates, the description, then the
/// parts, the comments as a card that opens them over the page (the video stays in view above), and related videos.
struct BilibiliPhoneVideoPage<Parts: View, Status: View>: View {
    let bvid: String
    let title: String
    /// The source's synopsis, until Bilibili's own description is in.
    let synopsis: String
    let creator: (mid: Int, name: String)?
    let client: CatalogClient
    /// In Yingxia's own favourites (the heart elsewhere in the app), not Bilibili's.
    let saved: Bool
    let toggleSaved: () -> Void
    let download: (() -> Void)?
    /// The page's notices: a playback that failed, details that didn't load.
    @ViewBuilder let status: Status
    @ViewBuilder let parts: Parts
    @State private var actions = BilibiliVideoActions()
    @State private var hotComments: [BilibiliAPI.Comment] = []
    @State private var choosingCoins = false
    @State private var showsComments = false
    @State private var showsSignIn = false
    @State private var showsMore = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                // A line kept while the facts load, so the page doesn't move when they come in.
                Text(facts.isEmpty ? " " : facts).font(.footnote).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            if let creator { BilibiliCreatorRow(mid: creator.mid, name: creator.name, client: client) }
            VStack(alignment: .leading, spacing: 8) {
                plates
                BilibiliNotice(message: Binding(get: { actions.message }, set: { actions.message = $0 }))
            }
            description
            status
            parts
            if let state = actions.state, !hotComments.isEmpty { commentsCard(total: state.replies) }
            BilibiliRelatedRow(bvid: bvid, client: client)
        }
        .animation(.smooth(duration: 0.3), value: actions.state)
        .task(id: bvid) {
            await actions.load(bvid)
            if let aid = actions.state?.aid, let page = try? await BilibiliAPI.comments(aid: aid, newest: false, cursor: nil) {
                hotComments = Array(page.comments.prefix(3))
            }
            #if DEBUG
            // `-qaOpenComments 1` opens the comments over the page once they are in, for screenshots.
            if UserDefaults.standard.bool(forKey: "qaOpenComments"), !hotComments.isEmpty { showsComments = true }
            #endif
        }
        .confirmationDialog(L10n.text("Coin"), isPresented: $choosingCoins, titleVisibility: .visible) {
            ForEach(Array(1...max(1, actions.coinsLeft)), id: \.self) { count in
                Button(count == 1 ? L10n.text("1 Coin") : L10n.text("%lld Coins", count)) { Task { await actions.coin(count) } }
            }
        } message: {
            Text(L10n.text("Coins also like the video."))
        }
        // Over the page at half height, so the video keeps playing in view above them; up to full height to read on.
        .sheet(isPresented: $showsComments) {
            if let state = actions.state {
                BilibiliCommentsView(aid: state.aid, total: state.replies)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            }
        }
        // Signed out, Like, Coin and Favorite open the account's sign-in, then the counts load again.
        .onChange(of: actions.needsSignIn) { _, needed in
            guard needed else { return }
            actions.needsSignIn = false
            showsSignIn = true
        }
        .sheet(isPresented: $showsSignIn, onDismiss: { Task { await actions.load(bvid) } }) {
            NavigationStack { BilibiliAccountView() }
        }
    }

    /// 57:46 · 1065.6万 views · 2.3万 danmaku · 2026/11/1
    private var facts: String {
        guard let state = actions.state else { return "" }
        var parts: [String] = []
        if state.duration > 0 { parts.append(Self.clock(state.duration)) }
        if state.views > 0 { parts.append(L10n.text("%@ views", BilibiliAPI.count(state.views))) }
        if state.danmaku > 0 { parts.append(L10n.text("%@ danmaku", BilibiliAPI.count(state.danmaku))) }
        if let date = state.published { parts.append(date.formatted(.dateTime.year().month().day())) }
        return parts.joined(separator: " · ")
    }

    static func clock(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Bilibili's description, else the source's synopsis; Bilibili's "-" stands for none.
    private var summary: String {
        if let text = actions.state?.summary, !text.isEmpty { return text }
        let text = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "-" ? "" : text
    }

    private func caption(_ count: Int?, _ title: String) -> String { count.map { $0 > 0 ? BilibiliAPI.count($0) : title } ?? title }

    /// Like, Coin and Favorite with their counts, Download, and More for the rest: one row of plates across the page.
    private var plates: some View {
        let state = actions.state
        return HStack(alignment: .top, spacing: 0) {
            Button { Task { await actions.like() } } label: {
                WatchPlateLabel(symbol: "hand.thumbsup", caption: caption(state?.likes, L10n.text("Like")), on: state?.liked == true, tint: BilibiliMark.pink)
            }
            .contextMenu {
                Button { Task { await actions.triple() } } label: { Label(L10n.text("Like, Coin and Favorite"), systemImage: "sparkles") }
            }
            .accessibilityLabel(L10n.text("Like")).accessibilityIdentifier("bilibili.like")
            .frame(maxWidth: .infinity)
            Button { if actions.signedIn() { choosingCoins = true } } label: {
                WatchPlateLabel(symbol: "bitcoinsign.circle", caption: caption(state?.coins, L10n.text("Coin")), on: (state?.coined ?? 0) > 0, tint: BilibiliMark.pink)
            }
            .accessibilityLabel(L10n.text("Coin")).accessibilityIdentifier("bilibili.coin")
            .frame(maxWidth: .infinity)
            Button { Task { await actions.favorite() } } label: {
                WatchPlateLabel(symbol: "star", caption: caption(state?.favorites, L10n.text("Favorite")), on: state?.favorited == true, tint: BilibiliMark.pink)
            }
            .accessibilityLabel(L10n.text("Favorite")).accessibilityIdentifier("bilibili.favorite")
            .frame(maxWidth: .infinity)
            if let download {
                Button(action: download) { WatchPlateLabel(symbol: "arrow.down.circle", caption: L10n.text("Download")) }
                    .accessibilityLabel(L10n.text("Download")).accessibilityIdentifier("detail.download")
                    .frame(maxWidth: .infinity)
            }
            // A sheet of choices rather than a menu: iOS draws a menu's own glass around its label, a second, larger plate.
            Button { showsMore = true } label: {
                WatchPlateLabel(symbol: saved ? "heart" : "ellipsis", caption: saved ? L10n.text("Saved") : L10n.text("More"), on: saved)
            }
            .accessibilityLabel(L10n.text("More")).accessibilityIdentifier("bilibili.more")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(state == nil)
        .confirmationDialog(title, isPresented: $showsMore, titleVisibility: .hidden) {
            Button(L10n.text("Watch Later")) { Task { await actions.watchLater() } }
            Button(L10n.text("Like, Coin and Favorite")) { Task { await actions.triple() } }
            Button(saved ? L10n.text("Remove from Yingxia Favorites") : L10n.text("Add to Yingxia Favorites"), action: toggleSaved)
        }
        // The row spans the page, its first and last plates a little inside its edges.
        .padding(.horizontal, -6)
    }

    /// Three lines of the description; a tap shows the rest.
    @ViewBuilder private var description: some View {
        let text = summary
        if !text.isEmpty {
            Button { withAnimation(.smooth(duration: 0.3)) { expanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        .lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
                    if text.count > 60 {
                        Text(L10n.text(expanded ? "Show Less" : "More")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("bilibili.description")
        }
    }

    /// The comments as one card, as YouTube's page has: their count and the most liked one; a tap opens them all.
    private func commentsCard(total: Int) -> some View {
        Button { showsComments = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.text("Comments")).font(.headline).foregroundStyle(.primary)
                    if total > 0 { Text(BilibiliAPI.count(total)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                if let first = hotComments.first {
                    HStack(alignment: .top, spacing: 10) {
                        Color.clear.frame(width: 26, height: 26)
                            .overlay { PosterImage(url: first.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(first.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Text(first.text).font(.subheadline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassOrFill(.regular.interactive(), Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bilibili.comments")
    }
}
#endif

#if os(macOS)
// MARK: The Mac's video page

/// A Bilibili video's page on the Mac, as Apple TV's (#256): its cover across the window; over its foot the title once,
/// the facts, Play with the account's actions as glass plates, and beside them the UP主 with Follow and three lines of
/// the description; then the parts, the hot comments and related videos.
struct BilibiliMacVideoPage<Play: View, Parts: View, Status: View>: View {
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
    /// More than one part: the parts show.
    let hasParts: Bool
    @Binding var pastHero: Bool
    @ViewBuilder let play: Play
    @ViewBuilder let parts: Parts
    /// The page's notices: a playback that failed, details that didn't load.
    @ViewBuilder let status: Status
    @State private var actions = BilibiliVideoActions()
    @State private var maker = BilibiliCreatorModel()
    @State private var hotComments: [BilibiliAPI.Comment] = []
    @State private var showsComments = false
    @State private var showsSignIn = false

    var body: some View {
        GeometryReader { geometry in
            let height = MacHeroMetrics.height(for: geometry.size)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    MacVideoHero(height: height, width: geometry.size.width, backdrop: cover, backdropHeaders: coverHeaders) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title).font(.system(size: 36, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                                .frame(maxWidth: 760, alignment: .leading)
                                .shadow(color: .black.opacity(0.4), radius: 10)
                            // A line kept while the facts load, so the hero doesn't move when they come in.
                            Text(facts.isEmpty ? " " : facts).font(.system(size: 14, weight: .medium)).monospacedDigit()
                                .lineLimit(1).opacity(0.75)
                        }
                    } actions: {
                        videoActions
                    } side: {
                        about
                    }
                    VStack(alignment: .leading, spacing: 30) {
                        status
                        if hasParts { parts }
                        if !hotComments.isEmpty { commentsRow }
                        BilibiliRelatedRow(bvid: bvid, client: client)
                    }
                    .padding(.horizontal, MacHeroMetrics.gutter)
                }
                .padding(.bottom, 40)
            }
            // From the window's top edge: the picture runs on under the toolbar, as Discover's title page.
            .ignoresSafeArea(edges: .top)
            .macHeroScroll(heroHeight: height, past: $pastHero)
        }
        .animation(.smooth(duration: 0.3), value: actions.state)
        .task(id: bvid) {
            await actions.load(bvid)
            if let aid = actions.state?.aid, let page = try? await BilibiliAPI.comments(aid: aid, newest: false, cursor: nil) {
                hotComments = Array(page.comments.prefix(12))
            }
        }
        .task(id: creator?.mid) { if let mid = creator?.mid { await maker.load(mid) } }
        .sheet(isPresented: $showsComments) {
            if let state = actions.state {
                BilibiliCommentsView(aid: state.aid, total: state.replies).discoverSheetSize(width: 640, height: 720)
            }
        }
        // Signed out, Like, Coin, Favorite and Follow open the account's sign-in, then the counts load again.
        .onChange(of: actions.needsSignIn || maker.needsSignIn) { _, needed in
            guard needed else { return }
            actions.needsSignIn = false; maker.needsSignIn = false
            showsSignIn = true
        }
        .sheet(isPresented: $showsSignIn, onDismiss: {
            Task { await actions.load(bvid); if let mid = creator?.mid { await maker.load(mid) } }
        }) {
            NavigationStack { BilibiliAccountView() }.discoverSheetSize(width: 520, height: 640)
        }
    }

    /// Bilibili's description, else the source's synopsis; Bilibili's "-" stands for none.
    private var summary: String {
        if let text = actions.state?.summary, !text.isEmpty { return text }
        let text = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "-" ? "" : text
    }

    /// 1:15 · 42.8万 views · 1240 danmaku · 2025/3/1
    private var facts: String {
        guard let state = actions.state else { return "" }
        var parts: [String] = []
        if state.duration > 0 {
            let seconds = state.duration
            parts.append(seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                                         : String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        if state.views > 0 { parts.append(L10n.text("%@ views", BilibiliAPI.count(state.views))) }
        if state.danmaku > 0 { parts.append(L10n.text("%@ danmaku", BilibiliAPI.count(state.danmaku))) }
        if let date = state.published { parts.append(date.formatted(.dateTime.year().month().day())) }
        return parts.joined(separator: " · ")
    }

    private func caption(_ count: Int?, _ title: String) -> String { count.map { $0 > 0 ? BilibiliAPI.count($0) : title } ?? title }

    /// Play, then Like, Coin and Favorite with their counts, Download, and More for the rest, as one row of plates.
    private var videoActions: some View {
        let state = actions.state
        return VStack(alignment: .leading, spacing: 18) {
            play
            HStack(alignment: .top, spacing: 6) {
                MacPlate(symbol: "hand.thumbsup", caption: caption(state?.likes, L10n.text("Like")), on: state?.liked == true,
                         tint: BilibiliMark.pink, id: "bilibili.like") { Task { await actions.like() } }
                    .contextMenu {
                        Button { Task { await actions.triple() } } label: { Label(L10n.text("Like, Coin and Favorite"), systemImage: "sparkles") }
                    }
                MacPlateMenu(symbol: "bitcoinsign.circle", caption: caption(state?.coins, L10n.text("Coin")), on: (state?.coined ?? 0) > 0,
                             tint: BilibiliMark.pink, title: L10n.text("Coin"), id: "bilibili.coin") {
                    Section(L10n.text("Coins also like the video.")) {
                        ForEach(Array(1...max(1, actions.coinsLeft)), id: \.self) { count in
                            Button(count == 1 ? L10n.text("1 Coin") : L10n.text("%lld Coins", count)) { Task { await actions.coin(count) } }
                        }
                    }
                }
                MacPlate(symbol: "star", caption: caption(state?.favorites, L10n.text("Favorite")), on: state?.favorited == true,
                         tint: BilibiliMark.pink, id: "bilibili.favorite") { Task { await actions.favorite() } }
                MacPlate(symbol: "arrow.down.circle", caption: L10n.text("Download"), id: "detail.download", action: download)
                MacPlateMenu(symbol: saved ? "heart" : "ellipsis", caption: saved ? L10n.text("Saved") : L10n.text("More"), on: saved,
                             title: L10n.text("More"), id: "bilibili.more") {
                    Button { Task { await actions.watchLater() } } label: { Label(L10n.text("Watch Later"), systemImage: "clock") }
                    Button { Task { await actions.triple() } } label: { Label(L10n.text("Like, Coin and Favorite"), systemImage: "sparkles") }
                    Divider()
                    Button(action: toggleSaved) {
                        Label(saved ? L10n.text("Remove from Yingxia Favorites") : L10n.text("Add to Yingxia Favorites"),
                              systemImage: saved ? "heart.slash" : "heart")
                    }
                }
            }
            .disabled(state == nil)
            BilibiliNotice(message: Binding(get: { actions.message ?? maker.message }, set: { actions.message = $0; maker.message = $0 }))
        }
    }

    /// Who made it, with Follow (and Watch Live while they are live), then what they wrote, which opens in full.
    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let creator {
                let name = maker.creator?.name ?? creator.name
                HStack(spacing: 10) {
                    RouteLink { bilibiliSpace(mid: creator.mid, name: name, client: client) } label: {
                        HStack(spacing: 12) {
                            Color.clear.frame(width: 44, height: 44)
                                .overlay { PosterImage(url: maker.creator?.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                                Text(maker.stats).font(.system(size: 12)).monospacedDigit().lineLimit(1).opacity(0.65)
                            }
                            Image(systemName: "chevron.forward").font(.system(size: 12, weight: .semibold)).opacity(0.45)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bilibili.creator")
                    Spacer(minLength: 8)
                    if let room = maker.creator?.liveRoom, let channel = bilibiliLiveChannel(room: room, host: name) {
                        Button { store.playing = channel } label: {
                            Label(L10n.text("Watch Live"), systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 14).frame(height: 32)
                                .glassOrFill(.regular.interactive(), Color.white.opacity(0.14), in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bilibili.live")
                    }
                    Button { Task { await maker.toggleFollow(creator.mid) } } label: {
                        HStack(spacing: 6) {
                            if maker.busy { ProgressView().appControlSize(.mini) } else { Image(systemName: maker.following ? "checkmark" : "plus") }
                            Text(maker.following ? L10n.text("Followed") : L10n.text("Follow"))
                        }
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).frame(height: 32)
                        .background(maker.following ? AnyShapeStyle(Color.white.opacity(0.16)) : AnyShapeStyle(BilibiliMark.pink), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bilibili.follow")
                }
            }
            if !summary.isEmpty { MacHeroSynopsis(text: summary, lines: 3) }
        }
    }

    /// The most liked comments as glass cards across the page; the arrow by the heading, or any card, opens them all.
    private var commentsRow: some View {
        let total = actions.state?.replies ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L10n.text("Comments")).font(.headline)
                if total > 0 { Text(BilibiliAPI.count(total)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary) }
                Button { showsComments = true } label: {
                    Image(systemName: "chevron.forward").font(.footnote.weight(.bold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(L10n.text("All Comments")).accessibilityIdentifier("bilibili.comments.all")
            }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(hotComments) { comment in
                        Button { showsComments = true } label: { BilibiliMacCommentCard(comment: comment) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("bilibili.comment")
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
    }
}

/// A hot comment on the Mac's video page: who wrote it, its likes and three lines of it.
private struct BilibiliMacCommentCard: View {
    let comment: BilibiliAPI.Comment
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 26, height: 26)
                    .overlay { PosterImage(url: comment.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                    .clipShape(Circle())
                Text(comment.name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                if comment.likes > 0 {
                    Label(BilibiliAPI.count(comment.likes), systemImage: "hand.thumbsup").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(comment.text).font(.subheadline).lineSpacing(2).lineLimit(3).multilineTextAlignment(.leading)
        }
        .padding(14)
        .frame(width: 320, height: 118, alignment: .topLeading)
        .glassOrFill(.regular.interactive(), Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
#endif

#if os(tvOS)
// MARK: Apple TV's video page

private enum BilibiliTVMetrics {
    static let gutter: CGFloat = 96
    /// Play and the four action plates under it.
    static let actionsWidth: CGFloat = 540
    /// Play, the UP主, Follow and Live: one height, so the hero's first row lines up.
    static let rowHeight: CGFloat = 82
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
    @State private var showsSignIn = false
    /// What has focus in the hero: while anything there has it, the hero is scrolled fully into view.
    @FocusState private var heroFocus: HeroItem?
    private enum HeroItem: Hashable { case play, like, coin, favorite, more, creator, live, follow, summary }

    var body: some View {
        // Coming back up from the rows, the remote's scroll stops once the focused button shows, which left the title
        // under the top edge (and the system's tab pill hidden): the whole hero comes back instead.
        ScrollViewReader { proxy in
            page.onChange(of: heroFocus != nil) { _, inHero in
                if inHero { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("hero", anchor: .top) } }
            }
        }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 60) {
                hero.id("hero")
                if hasParts { parts.padding(.horizontal, BilibiliTVMetrics.gutter).focusSection() }
                if !hotComments.isEmpty { commentsRow }
                if !related.isEmpty { relatedRow }
            }
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
        .modifier(DiscoverTVScrolled(scrolled: $scrolled))
        .background { BilibiliTVBackdrop(cover: cover, headers: coverHeaders, frosted: scrolled) }
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
        .task(id: creator?.mid) { if let mid = creator?.mid { await maker.load(mid) } }
        .fullScreenCover(isPresented: $showsComments) {
            if let state = actions.state { BilibiliCommentsView(aid: state.aid, total: state.replies, cover: cover, coverHeaders: coverHeaders) }
        }
        .fullScreenCover(isPresented: $showsDescription) { descriptionScreen }
        // Signed out, Like, Coin, Favorite and Follow open the sign-in screen; other notes float in at the top.
        .overlay(alignment: .top) {
            BilibiliTVToast(message: Binding(get: { actions.message ?? maker.message }, set: { actions.message = $0; maker.message = $0 }))
        }
        .onChange(of: actions.needsSignIn || maker.needsSignIn) { _, needed in
            guard needed else { return }
            actions.needsSignIn = false; maker.needsSignIn = false; actions.message = nil; maker.message = nil
            showsSignIn = true
        }
        .fullScreenCover(isPresented: $showsSignIn, onDismiss: {
            Task { await actions.load(bvid); if let mid = creator?.mid { await maker.load(mid) } }
        }) { BilibiliAccountView() }
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
            play.focused($heroFocus, equals: .play)
            HStack(alignment: .top, spacing: 16) {
                plate("hand.thumbsup", on: state?.liked == true, count: state?.likes, title: L10n.text("Like"), id: "bilibili.like", focus: .like) {
                    Task { await actions.like() }
                }
                .disabled(state == nil)
                // A menu, not a dialog: a confirmation dialog on a pushed page hangs tvOS 27 (#272).
                plateMenu("bitcoinsign.circle", on: (state?.coined ?? 0) > 0, caption: caption(state?.coins, L10n.text("Coin")),
                          title: L10n.text("Coin"), id: "bilibili.coin", focus: .coin) {
                    Section(L10n.text("Coins also like the video.")) {
                        ForEach(Array(1...max(1, actions.coinsLeft)), id: \.self) { count in
                            Button(count == 1 ? L10n.text("1 Coin") : L10n.text("%lld Coins", count)) { Task { await actions.coin(count) } }
                        }
                    }
                }
                .disabled(state == nil)
                plate("star", on: state?.favorited == true, count: state?.favorites, title: L10n.text("Favorite"), id: "bilibili.favorite", focus: .favorite) {
                    Task { await actions.favorite() }
                }
                .disabled(state == nil)
                plateMenu("ellipsis", on: false, caption: L10n.text("More"), title: L10n.text("More"), id: "bilibili.more", focus: .more) {
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
        }
    }

    private func caption(_ count: Int?, _ title: String) -> String { count.map { $0 > 0 ? BilibiliAPI.count($0) : title } ?? title }

    private func glyph(_ symbol: String, on: Bool) -> some View {
        Group {
            if on { Image(systemName: symbol + ".fill").foregroundStyle(BilibiliMark.pink) } else { Image(systemName: symbol) }
        }
        .frame(maxWidth: .infinity)
    }

    private func plate(_ symbol: String, on: Bool, count: Int?, title: String, id: String, focus: HeroItem,
                       action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Button(action: action) { glyph(symbol, on: on) }
                .buttonStyle(DiscoverTVActionStyle(height: 76, font: 30, corner: 24))
                .focused($heroFocus, equals: focus)
                .accessibilityLabel(title).accessibilityIdentifier(id)
            plateCaption(caption(count, title))
        }
    }

    private func plateMenu<Content: View>(_ symbol: String, on: Bool, caption: String, title: String, id: String, focus: HeroItem,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 12) {
            Menu(content: content) { glyph(symbol, on: on) }
                .menuStyle(.button).buttonStyle(DiscoverTVActionStyle(height: 76, font: 30, corner: 24))
                .focused($heroFocus, equals: focus)
                .accessibilityLabel(title).accessibilityIdentifier(id)
            plateCaption(caption)
        }
    }

    private func plateCaption(_ text: String) -> some View {
        Text(text).font(.system(size: 22, weight: .medium)).monospacedDigit().lineLimit(1).opacity(0.6)
    }

    /// Who made it, with Follow, and what they wrote, which opens in full.
    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let creator {
                let name = maker.creator?.name ?? creator.name
                HStack(spacing: 18) {
                    RouteLink { bilibiliSpace(mid: creator.mid, name: name, client: client) } label: {
                        HStack(spacing: 18) {
                            Color.clear.frame(width: 56, height: 56)
                                .overlay { PosterImage(url: maker.creator?.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name).font(.system(size: 26, weight: .semibold))
                                Text(maker.stats).font(.system(size: 20)).opacity(0.65)
                            }
                            Image(systemName: "chevron.forward").font(.system(size: 22, weight: .semibold)).opacity(0.45)
                        }
                        .padding(.leading, -2).padding(.trailing, 8)
                    }
                    .buttonStyle(DiscoverTVActionStyle(height: BilibiliTVMetrics.rowHeight, font: 26))
                    .focused($heroFocus, equals: .creator)
                    .accessibilityIdentifier("bilibili.creator")
                    if let room = maker.creator?.liveRoom, let channel = bilibiliLiveChannel(room: room, host: name) {
                        Button { store.playing = channel } label: { Label(L10n.text("Watch Live"), systemImage: "dot.radiowaves.left.and.right") }
                            .buttonStyle(DiscoverTVActionStyle(height: BilibiliTVMetrics.rowHeight, font: 26))
                            .focused($heroFocus, equals: .live)
                            .accessibilityIdentifier("bilibili.live")
                    }
                    Button { Task { await maker.toggleFollow(creator.mid) } } label: {
                        HStack(spacing: 10) {
                            if maker.busy { ProgressView() } else { Image(systemName: maker.following ? "checkmark" : "plus") }
                            Text(maker.following ? L10n.text("Followed") : L10n.text("Follow"))
                        }
                    }
                    .buttonStyle(DiscoverTVActionStyle(height: BilibiliTVMetrics.rowHeight, font: 26))
                    .focused($heroFocus, equals: .follow)
                    .accessibilityIdentifier("bilibili.follow")
                }
            }
            if !summary.isEmpty {
                Button { showsDescription = true } label: {
                    Text(summary).font(.system(size: 26)).lineSpacing(4).lineLimit(3).multilineTextAlignment(.leading)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
                .buttonStyle(BilibiliTVPlateStyle())
                .focused($heroFocus, equals: .summary)
                // The plate's padding outside the column, so the text lines up with the UP主 above it.
                .padding(.leading, -BilibiliTVPlateStyle.inset)
                .accessibilityIdentifier("bilibili.description")
            }
        }
    }

    // MARK: The rows

    private func row(_ title: String, spacing: CGFloat, open: (() -> Void)? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Text(title).font(.system(size: 34, weight: .medium)).opacity(0.6)
                if let open {
                    // "Comments ›": a glass arrow opens the whole list, as the cards also do.
                    Button(action: open) {
                        Image(systemName: "chevron.forward").font(.system(size: 22, weight: .bold)).frame(width: 16)
                    }
                    .buttonStyle(DiscoverTVActionStyle(height: 52, font: 22))
                    .accessibilityLabel(L10n.text("All Comments"))
                    .accessibilityIdentifier("bilibili.comments.all")
                }
            }
            .padding(.horizontal, BilibiliTVMetrics.gutter)
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
        return row(total > 0 ? L10n.text("Comments (%@)", BilibiliAPI.count(total)) : L10n.text("Comments"), spacing: 32,
                   open: { showsComments = true }) {
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
            BilibiliTVBackdrop(cover: cover, headers: coverHeaders, frosted: true)
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

// MARK: Apple TV's UP主 space

/// Apple TV's page for an UP主's space (#256), in the video page's language: their newest upload's cover across the
/// screen behind who they are (a large picture, their name, followers and uploads, their sign) with Follow and, while
/// they are live, Watch Live; then tabs for their uploads by order or their collections, and those as Bilibili's 16:9
/// tiles. No search field: the source's search covers all of Bilibili, not this UP主.
struct BilibiliTVSpacePage<Grid: View>: View {
    @Environment(Store.self) private var store
    let mid: Int
    let name: String
    let tabs: [(id: String, title: String)]
    /// The listing showing.
    let category: String
    /// The first upload listed: its cover is the backdrop, kept once there so changing tabs doesn't swap it.
    let latest: Video?
    let open: (String) -> Void
    @ViewBuilder let grid: Grid
    @State private var maker = BilibiliCreatorModel()
    @State private var backdrop: Video?
    @State private var scrolled = false
    @State private var showsSignIn = false
    @FocusState private var heroFocus: HeroItem?
    private enum HeroItem: Hashable { case follow, live, tab(String) }

    /// Four 16:9 tiles across.
    static var columns: [GridItem] { Array(repeating: GridItem(.fixed(BilibiliMetrics.tile), spacing: 48, alignment: .top), count: 4) }

    var body: some View {
        ScrollViewReader { proxy in
            page.onChange(of: heroFocus != nil) { _, inHero in
                if inHero { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("hero", anchor: .top) } }
            }
        }
    }

    private var page: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 48) {
                hero.id("hero")
                VStack(alignment: .leading, spacing: 56) { grid }
                    .padding(.horizontal, BilibiliTVMetrics.gutter)
                    .focusSection()
            }
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
        .modifier(DiscoverTVScrolled(scrolled: $scrolled))
        .background {
            ZStack {
                BilibiliTVBackdrop(cover: backdrop?.poster, headers: backdrop?.posterHeaders ?? [:], frosted: scrolled)
                // The tiles start halfway down: darker there than the video page, whose text runs to the foot.
                LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.75), location: 0.62)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .task(id: mid) { await maker.load(mid) }
        .onChange(of: latest?.id, initial: true) { if backdrop == nil, latest?.poster != nil { backdrop = latest } }
        .overlay(alignment: .top) { BilibiliTVToast(message: Binding(get: { maker.message }, set: { maker.message = $0 })) }
        .onChange(of: maker.needsSignIn) { _, needed in
            guard needed else { return }
            maker.needsSignIn = false; maker.message = nil; showsSignIn = true
        }
        .fullScreenCover(isPresented: $showsSignIn, onDismiss: { Task { await maker.load(mid) } }) { BilibiliAccountView() }
        .animation(.smooth(duration: 0.3), value: maker.creator)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 44) {
            HStack(alignment: .center, spacing: 40) {
                Color.clear.frame(width: 168, height: 168)
                    .overlay { PosterImage(url: maker.creator?.face, headers: Bilibili.imageHeaders, symbol: "person.fill") }
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.18), lineWidth: 2) }
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                VStack(alignment: .leading, spacing: 10) {
                    Text(maker.creator?.name ?? name).font(.system(size: 64, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.45), radius: 12)
                    Text(maker.stats).font(.system(size: 28, weight: .medium)).lineLimit(1).opacity(0.7)
                    if let sign = maker.creator?.sign.trimmingCharacters(in: .whitespacesAndNewlines), !sign.isEmpty {
                        Text(sign).font(.system(size: 24)).lineSpacing(3).lineLimit(2).opacity(0.6)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                }
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 12) {
                    HStack(spacing: 18) {
                        if let room = maker.creator?.liveRoom, let channel = bilibiliLiveChannel(room: room, host: maker.creator?.name ?? name) {
                            Button { store.playing = channel } label: { Label(L10n.text("Watch Live"), systemImage: "dot.radiowaves.left.and.right") }
                                .buttonStyle(DiscoverTVActionStyle(height: BilibiliTVMetrics.rowHeight, font: 26))
                                .focused($heroFocus, equals: .live)
                                .accessibilityIdentifier("bilibili.live")
                        }
                        Button { Task { await maker.toggleFollow(mid) } } label: {
                            HStack(spacing: 10) {
                                if maker.busy { ProgressView() } else { Image(systemName: maker.following ? "checkmark" : "plus") }
                                Text(maker.following ? L10n.text("Followed") : L10n.text("Follow"))
                            }
                        }
                        .buttonStyle(DiscoverTVActionStyle(height: BilibiliTVMetrics.rowHeight, font: 26))
                        .focused($heroFocus, equals: .follow)
                        .accessibilityIdentifier("bilibili.follow")
                    }
                }
            }
            HStack(spacing: 14) {
                ForEach(tabs, id: \.id) { tab in
                    Button { if category != tab.id { open(tab.id) } } label: { Text(tab.title) }
                        .buttonStyle(BilibiliTVTabStyle(selected: category == tab.id))
                        .focused($heroFocus, equals: .tab(tab.id))
                        .accessibilityIdentifier("bilibili.space.\(tab.id)")
                }
            }
            .focusSection()
            .defaultFocus($heroFocus, .tab(category))
        }
        .padding(.horizontal, BilibiliTVMetrics.gutter)
        .frame(maxWidth: .infinity, minHeight: 620, alignment: .bottomLeading)
    }
}

/// A note over Apple TV's Bilibili pages ("Added to Watch Later.", a refused like): a glass capsule that drops in at
/// the top of the screen and leaves after a few seconds, so the page under it never moves.
private struct BilibiliTVToast: View {
    @Binding var message: String?
    var body: some View {
        ZStack {
            if let message {
                Text(message).font(.system(size: 26, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 34).padding(.vertical, 18)
                    .glassSurface(.regular, in: Capsule())
                    .frame(maxWidth: 1100)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(3.5))
                        withAnimation(.smooth(duration: 0.35)) { self.message = nil }
                    }
            }
        }
        .padding(.top, 54)
        .animation(.smooth(duration: 0.35), value: message)
        .allowsHitTesting(false)
    }
}

/// A row of the comments list: the whole width, bare until focused, then on a soft plate.
private struct BilibiliTVRowStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration, compact: compact) }
    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .padding(.horizontal, 24).padding(.vertical, compact ? 12 : 18)
                .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white.opacity(focused ? 0.15 : 0)))
                .scaleEffect(configuration.isPressed ? 0.99 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}

/// A tab (the UP主's listings, the comments' order): a glass capsule, tinted for the one showing; focused, white glass
/// with dark text.
private struct BilibiliTVTabStyle: ButtonStyle {
    let selected: Bool
    /// Smaller, beside a heading.
    var compact = false
    func makeBody(configuration: Configuration) -> some View { Tab(configuration: configuration, selected: selected, compact: compact) }
    private struct Tab: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let compact: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .font(.system(size: compact ? 24 : 28, weight: selected || focused ? .semibold : .medium)).lineLimit(1)
                .foregroundStyle(focused ? Color.black : Color.white.opacity(selected ? 1 : 0.6))
                .padding(.horizontal, compact ? 22 : 30).frame(height: compact ? 50 : 66)
                // Liquid Glass, as the page's other buttons: tinted for the one showing, white under focus.
                .glassSurface(focused ? .regular.tint(.white.opacity(0.9)).interactive()
                              : selected ? .regular.tint(.white.opacity(0.28)).interactive() : .regular.interactive(), in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.06 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// The video page's backdrop: the cover across the whole screen, as Discover's title page shows a backdrop, darker
/// toward the text; frosted once the page scrolls past its hero.
private struct BilibiliTVBackdrop: View {
    let cover: URL?
    let headers: [String: String]
    let frosted: Bool
    var body: some View {
        ZStack {
            Color.black
            if let cover { TMDBArtwork(url: cover, maxPixels: 2400, headers: headers) }
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.55), location: 0.5),
                                   .init(color: .clear, location: 0.85)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.regularMaterial).opacity(frosted ? 1 : 0)
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
struct BilibiliTVPlateStyle: ButtonStyle {
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

#endif
