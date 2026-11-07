import Foundation

/// What the app does around the Bilibili source's videos itself (#256), with the signed-in account when there is
/// one: an UP主's card and following them, a video's likes, coins, favourite and watch later, its related videos and
/// comments, a part's chapters and subtitles, and the watch progress reported back to the account. The source's
/// script still does the browsing and playback; it names an UP主's space `up_<mid>` and a part `<aid>_<cid>[_<ep>]`.
public enum BilibiliAPI {
    // MARK: Ids

    /// The UP主 of a space category the source lists (`up_<mid>`, not one of its collections).
    public static func creator(category: String) -> Int? {
        guard let match = category.wholeMatch(of: /up_(\d+)/) else { return nil }
        return Int(match.1)
    }
    /// A space category's UP主, for its collections and sort orders too (`up_<mid>_click`, `up_<mid>_season_<id>`).
    public static func spaceOwner(category: String) -> Int? {
        guard let match = category.prefixMatch(of: /up_(\d+)(?:_|$)/) else { return nil }
        return Int(match.1)
    }
    /// An ordinary video's id (BV…), as opposed to a season (`season_<id>`).
    public static func isVideo(_ id: String) -> Bool { id.hasPrefix("BV") && id.count >= 10 }

    /// One part of a video, or a PGC episode, as the source's episode addresses name it.
    public struct Part: Hashable, Sendable {
        public let aid: Int, cid: Int
        /// The PGC episode (ep_id); nil for an ordinary video's part.
        public let episode: Int?
        public init?(address: String) {
            let fields = address.split(separator: "_").map { Int($0) }
            guard (2...3).contains(fields.count), let aid = fields[0], let cid = fields[1], aid > 0, cid > 0 else { return nil }
            self.aid = aid; self.cid = cid
            episode = fields.count == 3 ? fields[2] : nil
            if fields.count == 3, episode == nil { return nil }
        }
    }

    /// Counts as Bilibili writes them: 2.1万, 1.3亿.
    public static func count(_ value: Int) -> String {
        func short(_ unit: Double, _ name: String) -> String {
            let text = String(format: "%.1f", Double(value) / unit)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + name
        }
        return value >= 100_000_000 ? short(100_000_000, "亿") : value >= 10_000 ? short(10_000, "万") : String(value)
    }

    // MARK: Requests

    static var account: BilibiliAccount { BilibiliAccount.load() }
    public static var signedIn: Bool { account.signedIn }
    /// The account's CSRF token, which every change to it must carry.
    static func csrf(_ cookie: String) -> String? {
        cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("bili_jct=") }.map { String($0.dropFirst("bili_jct=".count)) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func get(_ address: String, signed parameters: [String: String]? = nil) async throws -> [String: JSONValue] {
        let signer = BilibiliSigner.shared
        let cookie = await signer.cookie(account: account.cookie)
        var address = address
        if let parameters { address += "?" + (try await signer.sign(parameters, cookie: cookie)) }
        guard let url = URL(string: address) else { throw TVError.invalidURL }
        let reply = try await signer.json(url, cookie: cookie)
        try check(reply)
        return reply
    }

    /// A change to the account, as the web site posts it. Throws Bilibili's message when it refuses.
    @discardableResult
    static func post(_ address: String, _ fields: [String: String]) async throws -> [String: JSONValue] {
        let account = account
        guard account.signedIn, let csrf = csrf(account.cookie) else { throw TVError.unsupported(L10n.text("Sign in to Bilibili in Settings first.")) }
        let cookie = await BilibiliSigner.shared.cookie(account: account.cookie)
        guard let url = URL(string: address) else { throw TVError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        var all = fields
        all["csrf"] = csrf
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
        request.httpBody = Data(all.keys.sorted().map { "\($0)=\(all[$0]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Bilibili.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Bilibili.referer + "/", forHTTPHeaderField: "Referer")
        request.setValue(Bilibili.referer, forHTTPHeaderField: "Origin")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 { throw TVError.http(status) }
        let reply = try JSONDecoder().decode([String: JSONValue].self, from: data)
        try check(reply)
        return reply
    }

    static func check(_ reply: [String: JSONValue]) throws {
        let code = reply["code"]?.int ?? 0
        guard code != 0 else { return }
        if code == -101 { throw TVError.unsupported(L10n.text("Your Bilibili sign-in has expired. Sign in again in Settings.")) }
        let message = reply["message"]?.string ?? ""
        throw TVError.unsupported(message.isEmpty || message == "\(code)" ? L10n.text("Bilibili refused the request. Try again later.") : message)
    }

    static func picture(_ value: JSONValue?) -> URL? {
        guard var text = value?.string, !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        if text.hasPrefix("http:") { text = "https:" + text.dropFirst(5) }
        return URL(string: text)
    }

    // MARK: UP主

    public struct Creator: Hashable, Sendable {
        public let mid: Int
        public var name: String
        public var face: URL?
        public var fans: Int
        public var videos: Int
        public var sign: String
        /// Whether the signed-in account follows them; false when signed out.
        public var following: Bool
        /// Their live room while they are live.
        public var liveRoom: Int?
    }

    public static func creator(_ mid: Int) async throws -> Creator {
        async let live = liveRoom(mid)
        let reply = try await get("https://api.bilibili.com/x/web-interface/card?mid=\(mid)&photo=false")
        let data = reply["data"]?.object ?? [:]
        let card = data["card"]?.object ?? [:]
        return Creator(mid: mid, name: card["name"]?.string ?? "", face: picture(card["face"]), fans: card["fans"]?.int ?? data["follower"]?.int ?? 0,
                       videos: data["archive_count"]?.int ?? 0, sign: card["sign"]?.string ?? "", following: data["following"] == .bool(true),
                       liveRoom: await live)
    }

    /// The UP主's live room while they are live.
    static func liveRoom(_ mid: Int) async -> Int? {
        guard let reply = try? await get("https://api.live.bilibili.com/room/v1/Room/getRoomInfoOld?mid=\(mid)"),
              let data = reply["data"]?.object, data["liveStatus"]?.int == 1, let room = data["roomid"]?.int, room > 0 else { return nil }
        return room
    }

    /// A followed UP主 who is live now.
    public struct LiveNow: Identifiable, Hashable, Sendable {
        public let room: Int
        public let host: String
        public let title: String
        public let cover: URL?
        public var id: Int { room }
    }

    /// The live rooms of the UP主 the account follows that are live now; none when signed out.
    public static func followedLive() async throws -> [LiveNow] {
        guard signedIn else { return [] }
        let data = try await get("https://api.live.bilibili.com/xlive/web-ucenter/user/following?page=1&page_size=30")["data"]?.object ?? [:]
        return (data["list"]?.array ?? []).compactMap(\.object).filter { $0["live_status"]?.int == 1 }.compactMap { item in
            guard let room = item["roomid"]?.int, room > 0 else { return nil }
            return LiveNow(room: room, host: item["uname"]?.string ?? "", title: item["title"]?.string ?? "",
                           cover: picture(item["room_cover"]) ?? picture(item["face"]))
        }
    }

    public static func follow(_ mid: Int, _ on: Bool) async throws {
        try await post("https://api.bilibili.com/x/relation/modify", ["fid": String(mid), "act": on ? "1" : "2", "re_src": "11"])
    }

    // MARK: A video

    /// A video's counts and, signed in, what the account has done to it.
    public struct VideoState: Hashable, Sendable {
        public let aid: Int
        public let owner: Int?
        public var views: Int, likes: Int, coins: Int, favorites: Int, replies: Int, danmaku: Int
        public var liked = false
        public var coined = 0
        public var favorited = false
        /// Coins the video takes from one account: 1 for a reprint, 2 for an original.
        public var maxCoins = 2
        /// Its length in seconds, when it was published, and its description (Bilibili's "-" for none is left out).
        public var duration = 0
        public var published: Date?
        public var summary = ""
    }

    public static func state(bvid: String) async throws -> VideoState {
        let reply = try await get("https://api.bilibili.com/x/web-interface/view?bvid=" + (bvid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bvid))
        let data = reply["data"]?.object ?? [:]
        let stat = data["stat"]?.object ?? [:]
        guard let aid = data["aid"]?.int else { throw TVError.unsupported(L10n.text("Bilibili refused the request. Try again later.")) }
        var state = VideoState(aid: aid, owner: data["owner"]?.object?["mid"]?.int, views: stat["view"]?.int ?? 0, likes: stat["like"]?.int ?? 0,
                               coins: stat["coin"]?.int ?? 0, favorites: stat["favorite"]?.int ?? 0, replies: stat["reply"]?.int ?? 0,
                               danmaku: stat["danmaku"]?.int ?? 0)
        state.maxCoins = data["copyright"]?.int == 2 ? 1 : 2
        state.duration = data["duration"]?.int ?? 0
        state.published = data["pubdate"]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        let summary = (data["desc"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        state.summary = summary == "-" ? "" : summary
        if signedIn, let relation = try? await get("https://api.bilibili.com/x/web-interface/archive/relation?aid=\(aid)")["data"]?.object {
            state.liked = relation["like"] == .bool(true)
            state.coined = relation["coin"]?.int ?? 0
            state.favorited = relation["favorite"] == .bool(true)
        }
        return state
    }

    public static func like(aid: Int, _ on: Bool) async throws {
        try await post("https://api.bilibili.com/x/web-interface/archive/like", ["aid": String(aid), "like": on ? "1" : "2"])
    }

    public static func coin(aid: Int, count: Int, like: Bool) async throws {
        try await post("https://api.bilibili.com/x/web-interface/coin/add", ["aid": String(aid), "multiply": String(count), "select_like": like ? "1" : "0"])
    }

    /// 一键三连: like, coins and favourite at once. Answers what Bilibili did.
    public static func triple(aid: Int) async throws -> (like: Bool, coins: Bool, favorite: Bool) {
        let data = try await post("https://api.bilibili.com/x/web-interface/archive/like/triple", ["aid": String(aid)])["data"]?.object ?? [:]
        return (data["like"] == .bool(true), data["coin"] == .bool(true), data["fav"] == .bool(true))
    }

    /// Into, or out of, the account's default favourites folder.
    public static func favorite(aid: Int, _ on: Bool) async throws {
        let me = account.cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("DedeUserID=") }.map { String($0.dropFirst("DedeUserID=".count)) } ?? ""
        let folders = try await get("https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=\(me)&type=2&rid=\(aid)")["data"]?.object?["list"]?.array ?? []
        let ids = folders.compactMap(\.object)
        // The default folder is the first; taking a video out takes it out of every folder that holds it.
        let chosen = on ? ids.prefix(1).compactMap { $0["id"]?.string } : ids.filter { $0["fav_state"]?.int == 1 }.compactMap { $0["id"]?.string }
        guard !chosen.isEmpty else { return }
        try await post("https://api.bilibili.com/x/v3/fav/resource/deal", ["rid": String(aid), "type": "2",
                                                                          on ? "add_media_ids" : "del_media_ids": chosen.joined(separator: ",")])
    }

    public static func watchLater(aid: Int) async throws {
        try await post("https://api.bilibili.com/x/v2/history/toview/add", ["aid": String(aid)])
    }

    /// The videos Bilibili suggests beside this one, as the source lists videos.
    public static func related(bvid: String) async throws -> [Video] {
        let reply = try await get("https://api.bilibili.com/x/web-interface/archive/related?bvid=" + bvid)
        return (reply["data"]?.array ?? []).compactMap(\.object).compactMap { item in
            guard let id = item["bvid"]?.string, !id.isEmpty, item["title"]?.string != "视频已失效" else { return nil }
            let seconds = item["duration"]?.int ?? 0
            let clock = seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
            let remarks = [seconds > 0 ? clock : "", item["owner"]?.object?["name"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return Video(id: id, name: HTMLText.name(item["title"]?.string ?? id), poster: picture(item["pic"]),
                         posterHeaders: Bilibili.mediaHeaders, remarks: remarks)
        }
    }

    /// Frames sampled through a video: Bilibili's scrubbing previews (视频快照), sheets of `columns` × `rows` frames
    /// each, `count` frames in all, in the video's order.
    public struct Videoshot: Sendable {
        public let sheets: [URL]
        public let columns: Int
        public let rows: Int
        public let count: Int
    }

    /// The video's preview frames; nil when Bilibili has none for it.
    public static func videoshot(bvid: String) async throws -> Videoshot? {
        let data = try await get("https://api.bilibili.com/x/player/videoshot?index=1&bvid=" + bvid)["data"]?.object ?? [:]
        let sheets = (data["image"]?.array ?? []).compactMap { picture($0) }
        let columns = data["img_x_len"]?.int ?? 0, rows = data["img_y_len"]?.int ?? 0
        guard !sheets.isEmpty, columns > 0, rows > 0 else { return nil }
        // `index` holds each frame's time after a leading 0; the sheets' remaining cells are black.
        let times = data["index"]?.array?.count ?? 0
        let count = min(times > 1 ? times - 1 : columns * rows * sheets.count, columns * rows * sheets.count)
        return Videoshot(sheets: sheets, columns: columns, rows: rows, count: count)
    }

    // MARK: Comments

    public struct Comment: Identifiable, Hashable, Sendable {
        public let id: Int
        public let name: String
        public let face: URL?
        public let text: String
        public let likes: Int
        public let date: Date
        /// Replies under it, and the first few of them.
        public let replyCount: Int
        public let replies: [Comment]
    }

    public struct CommentPage: Sendable {
        public let comments: [Comment]
        /// Where the next page starts; nil at the end.
        public let next: String?
        public let total: Int
    }

    static func comment(_ item: [String: JSONValue]) -> Comment? {
        guard let id = item["rpid"]?.int else { return nil }
        let member = item["member"]?.object ?? [:]
        return Comment(id: id, name: member["uname"]?.string ?? "", face: picture(member["avatar"]),
                       text: item["content"]?.object?["message"]?.string ?? "", likes: item["like"]?.int ?? 0,
                       date: Date(timeIntervalSince1970: TimeInterval(item["ctime"]?.int ?? 0)),
                       replyCount: item["rcount"]?.int ?? 0, replies: (item["replies"]?.array ?? []).compactMap(\.object).compactMap(comment))
    }

    /// A video's comments, most liked first or newest first, a page at a time from `cursor`.
    public static func comments(aid: Int, newest: Bool, cursor: String? = nil) async throws -> CommentPage {
        var address = "https://api.bilibili.com/x/v2/reply/main?type=1&oid=\(aid)&mode=\(newest ? 2 : 3)&ps=20"
        if let cursor { address += "&next=" + cursor }
        let data = try await get(address)["data"]?.object ?? [:]
        let page = data["cursor"]?.object ?? [:]
        var list = (data["replies"]?.array ?? []).compactMap(\.object).compactMap(comment)
        // The UP主's pinned comment comes first on the first page.
        if cursor == nil, let top = data["top_replies"]?.array?.compactMap(\.object).compactMap(comment) { list = top + list.filter { item in !top.contains { $0.id == item.id } } }
        let ended = page["is_end"] == .bool(true) || list.isEmpty
        return CommentPage(comments: list, next: ended ? nil : page["next"]?.string, total: page["all_count"]?.int ?? 0)
    }

    /// The replies under one comment, 20 to a page.
    public static func replies(aid: Int, root: Int, page: Int) async throws -> (replies: [Comment], more: Bool) {
        let data = try await get("https://api.bilibili.com/x/v2/reply/reply?type=1&oid=\(aid)&root=\(root)&pn=\(page)&ps=20")["data"]?.object ?? [:]
        let list = (data["replies"]?.array ?? []).compactMap(\.object).compactMap(comment)
        let total = data["page"]?.object?["count"]?.int ?? 0
        return (list, page * 20 < total)
    }

    // MARK: Playback

    /// What the player shows beside a part's picture: its chapters (分段章节) and subtitle files.
    public struct PlayerInfo: Sendable {
        public let chapters: [PlaybackChapter]
        public let subtitles: [ExternalSubtitle]
        /// Some are the uploader's own, not only Bilibili's machine-made ones: those may come on by themselves.
        public let uploaded: Bool
    }

    public static func playerInfo(_ part: Part) async throws -> PlayerInfo {
        var parameters = ["aid": String(part.aid), "cid": String(part.cid)]
        if let episode = part.episode { parameters["ep_id"] = String(episode) }
        let data = try await get("https://api.bilibili.com/x/player/wbi/v2", signed: parameters)["data"]?.object ?? [:]
        let chapters = (data["view_points"]?.array ?? []).compactMap(\.object).compactMap { point -> PlaybackChapter? in
            guard let from = point["from"]?.double, let to = point["to"]?.double, to > from else { return nil }
            return PlaybackChapter(start: from, end: to, title: point["content"]?.string ?? "")
        }
        let files = (data["subtitle"]?.object?["subtitles"]?.array ?? []).compactMap(\.object)
        let machine = { (item: [String: JSONValue]) in item["lan"]?.string?.hasPrefix("ai-") == true }
        // The uploader's own first.
        let subtitles = (files.filter { !machine($0) } + files.filter(machine)).compactMap { item -> ExternalSubtitle? in
            guard let url = picture(item["subtitle_url"]) else { return nil }
            return ExternalSubtitle(name: item["lan_doc"]?.string ?? "", url: url, language: item["lan"]?.string.map(language) ?? "", format: "application/json")
        }
        return PlayerInfo(chapters: chapters, subtitles: subtitles, uploaded: files.contains { !machine($0) })
    }

    /// Bilibili's language codes ("ai-zh", "zh-Hans", "en-US") as the app's: the AI prefix dropped.
    static func language(_ code: String) -> String { code.hasPrefix("ai-") ? String(code.dropFirst(3)) : code }

    /// Reports where the account is in a part, so Bilibili's history and its other apps continue from there.
    public static func heartbeat(_ part: Part, seconds: Double) async throws {
        var fields = ["aid": String(part.aid), "cid": String(part.cid), "played_time": String(max(0, Int(seconds))),
                      "type": part.episode == nil ? "3" : "4", "dt": "2", "play_type": "0"]
        if let episode = part.episode { fields["epid"] = String(episode); fields["sub_type"] = "1" }
        try await post("https://api.bilibili.com/x/click-interface/web/heartbeat", fields)
    }
}

/// A titled stretch of a video (a chapter), in seconds.
public struct PlaybackChapter: Hashable, Sendable {
    public let start: Double, end: Double
    public let title: String
    public init(start: Double, end: Double, title: String) { self.start = start; self.end = end; self.title = title }
}

/// A stretch a source marks as skippable: the opening or ending credits (the play result's `skips`).
public struct PlaybackSkip: Hashable, Sendable {
    public enum Kind: String, Sendable { case intro, outro }
    public let start: Double, end: Double
    public let kind: Kind
    public init(start: Double, end: Double, kind: Kind) { self.start = start; self.end = end; self.kind = kind }

    /// `[{"start", "end", "type": "intro"|"outro"}]`, in seconds; anything else is left out.
    static func parse(_ value: JSONValue?) -> [PlaybackSkip] {
        (value?.array ?? []).compactMap(\.object).compactMap { item in
            guard let start = item["start"]?.double, let end = item["end"]?.double, start >= 0, end > start,
                  let kind = item["type"]?.string.flatMap(Kind.init) else { return nil }
            return PlaybackSkip(start: start, end: end, kind: kind)
        }
    }

    /// The stretch playing at `time` that a viewer could skip now: not in its last second.
    public static func current(_ skips: [PlaybackSkip], at time: Double) -> PlaybackSkip? {
        skips.first { time >= $0.start && time < $0.end - 1 }
    }
}

/// Reports watch progress for the signed-in account (`BilibiliAPI.heartbeat`): at most every 15 seconds while a part
/// plays, and once more when it stops. Off the main thread; a failed report is dropped.
public actor BilibiliHeartbeat {
    public static let shared = BilibiliHeartbeat()
    private var last: (part: BilibiliAPI.Part, date: Date, seconds: Int)?

    public func report(_ part: BilibiliAPI.Part, seconds: Double, final: Bool = false) async {
        guard seconds.isFinite, BilibiliAPI.signedIn else { return }
        let whole = Int(seconds)
        if let last, last.part == part, last.seconds == whole || (!final && Date().timeIntervalSince(last.date) < 15) { return }
        last = (part, Date(), whole)
        do { try await BilibiliAPI.heartbeat(part, seconds: seconds) }
        catch { Diagnostics.shared.record(.debug, "bilibili", "heartbeat \(error.localizedDescription)") }
    }
}
