import Foundation

/// A public Telegram channel as a source of its own, read from Telegram's public preview
/// (`t.me/s/<channel>`) without signing in: the viewer adds the channel's address
/// (`https://t.me/<channel>`) as a subscription, and its posts list as titles. A post's
/// episodes are the video it carries, the episode-range links into its comment thread
/// (short-drama channels post one range per comment), and any external "main line" link;
/// playback resolves a comment or embed page to its direct video address when the public
/// page carries one, and otherwise hands the page to the usual web detection. The address may name the entry
/// that reads t.me where the network blocks it (`TelegramEndpoint`, #2556). Only public channels work: the
/// preview is all this source reads. Some public channels show nothing in it (their posts stay inside the
/// Telegram app), so a channel whose preview comes back empty says so instead of listing nothing, and a Telegram
/// address that names no public channel (an invite link, a private channel, a user) is refused when it is added.
public enum TelegramSource {
    static let keyPrefix = "builtin.telegram."
    static let api = "csp_YingxiaTelegram"

    /// Whether an address is on Telegram at all: `t.me`, `telegram.me`, `telegram.dog` or `www.t.me`.
    static func isTelegramHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return TelegramEndpoint.hosts.contains(host)
    }

    /// The public channel a Telegram address names: `t.me/<channel>`, its preview
    /// `t.me/s/<channel>`, or a post in it. Invite links (`t.me/+…`, `t.me/joinchat/…`)
    /// and private channels (`t.me/c/…`) name none.
    public static func channel(_ url: URL) -> String? {
        guard let address = TelegramEndpoint.split(url)?.telegram,
              let host = address.host()?.lowercased(), TelegramEndpoint.hosts.contains(host) else { return nil }
        let parts = address.pathComponents.filter { $0 != "/" }
        guard let first = parts.first else { return nil }
        let candidate: String
        if first == "s" {
            guard parts.count >= 2 else { return nil }
            candidate = parts[1]
        } else {
            candidate = first
        }
        return isUsername(candidate) ? candidate : nil
    }

    /// A subscription holding just this channel's source, read through the entry `origin` named if it named one.
    public static func subscription(_ channel: String, origin: URL) -> Subscription {
        let endpoint = TelegramEndpoint.split(origin)?.endpoint ?? .direct
        return Subscription(origin: origin, importedAt: Date(), sites: [site(channel, endpoint: endpoint)], lives: [], raw: [:])
    }

    static func site(_ channel: String, endpoint: TelegramEndpoint = .direct) -> Site {
        let key = keyPrefix + channel.lowercased(), name = "Telegram @\(channel)"
        var ext: [String: JSONValue] = ["channel": .string(channel)]
        // Kept with the source, not the subscription: a merge or a reload must read it as it was added (#2556).
        if !endpoint.isDirect { ext["endpoint"] = .string(endpoint.base.absoluteString) }
        let raw: [String: JSONValue] = ["key": .string(key), "name": .string(name), "type": .number(3), "api": .string(api),
                                        "searchable": .number(1), "quickSearch": .number(1), "ext": .object(ext)]
        return Site(key: key, name: name, type: 3, api: api, raw: raw)
    }

    /// The channel a Telegram source browses.
    static func channel(of site: Site) -> String? {
        if let channel = site.raw["ext"]?.object?["channel"]?.string, isUsername(channel) { return channel }
        guard site.key.hasPrefix(keyPrefix) else { return nil }
        let channel = String(site.key.dropFirst(keyPrefix.count))
        return isUsername(channel) ? channel : nil
    }

    /// Answers a spider request (`play`, `ids`, `wd`, or the home page) in TVBox's JSON.
    static func request(_ site: Site, params: [String: String], http: HTTPClient) async throws -> [String: JSONValue] {
        guard let channel = channel(of: site) else { throw TVError.invalidURL }
        let endpoint = TelegramEndpoint.endpoint(of: site)
        if let address = params["play"] { return try await play(address, endpoint: endpoint, http: http) }
        if let ids = params["ids"], let id = Int(ids) {
            return ["list": .array([.object(try details(try await post(channel: channel, id: id, endpoint: endpoint, http: http),
                                                      channel: channel, endpoint: endpoint))])]
        }
        let page = max(1, Int(params["pg"] ?? "") ?? 1)
        let posts = try await fetchPage(channel: channel, page: page, endpoint: endpoint, http: http)
        if let query = params["wd"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let found = posts.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
            return ["list": .array(found.map { .object(videoFields($0)) }), "pagecount": .number(1)]
        }
        return try homeResponse(posts, page: page)
    }

    /// The home page for one page of posts: the Latest class and the posts. A first page with
    /// no posts at all means the preview exposes nothing — the channel is not public, or
    /// Telegram withholds its posts from the web — so it says so, instead of showing an empty
    /// list as if the channel simply had nothing in it. Later pages coming back empty only end
    /// the list.
    static func homeResponse(_ posts: [Post], page: Int) throws -> [String: JSONValue] {
        if page == 1, posts.isEmpty {
            throw TVError.unsupported(L10n.text("This Telegram channel's public preview is empty. Only public channels can be added, and some public channels do not show their posts in the web preview."))
        }
        // The preview page holds about twenty posts; a non-empty page may have older ones, so the count
        // stays high until a page comes back empty (#2234).
        let pageCount = posts.isEmpty ? page : 1000
        return ["class": .array([.object(["type_id": .string("latest"), "type_name": .string(L10n.text("Latest"))])]),
                "list": .array(posts.map { .object(videoFields($0)) }), "pagecount": .number(Double(pageCount))]
    }

    /// A direct media address plays as-is. A Telegram embed or comment page is read for the
    /// video address it carries, so playback stays in the app; a page without one (an
    /// external line, or a video too large for the public widget) goes to web detection.
    private static func play(_ address: String, endpoint: TelegramEndpoint, http: HTTPClient) async throws -> [String: JSONValue] {
        let header: JSONValue = .object(["Referer": .string("https://t.me/"), "User-Agent": .string(HTTPClient.userAgent)])
        if CatalogClient.isDirectMedia(address) { return ["parse": .number(0), "url": .string(address), "header": header] }
        // A Baidu share link is a cloud file behind a login and an extraction code. Save its first
        // video into the signed-in drive and play that copy — web detection can never find a video
        // in a share page, so this is what makes the line actually play (#2811).
        if let url = try? WebAddress.resolve(address), let share = BaiduShareLink(url: url) {
            return try await playBaiduShare(share, header: header)
        }
        // Other cloud drives can't be saved from here yet; say so instead of timing out.
        if Self.isNetdiskShareLink(address) {
            throw TVError.unsupported(L10n.text("This line is a cloud-drive share link, not a playable video. Open it in the drive's app, save the file to your own drive, then play it from Cloud Files."))
        }
        if let url = try? WebAddress.resolve(address) {
            // Only Telegram's own pages go through the source's entry; an external "main line" is read directly,
            // so the entry never sees addresses that aren't Telegram's.
            let page = TelegramEndpoint.split(url) != nil ? endpoint.address(url) : url
            if let html = try? await fetch(page, http: http), let video = video(in: html) {
                return ["parse": .number(0), "url": .string(video), "header": header]
            }
        }
        return ["parse": .number(1), "url": .string(address), "header": header]
    }

    /// Save the Baidu share's first video into Cloud Files and point the line at the saved copy, which
    /// the player prepares from the signed-in account. A missing Baidu account is called out explicitly.
    private static func playBaiduShare(_ share: BaiduShareLink, header: JSONValue) async throws -> [String: JSONValue] {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        guard accounts.baiduCookie?.contains("BDUSS") == true else {
            throw TVError.unsupported(L10n.text("Sign in to Baidu Netdisk under Cloud Drive Accounts to play this line."))
        }
        let saved = try await BaiduFiles.shared.saveFirstVideo(from: share)
        var address = URLComponents()
        address.scheme = CloudFiles.scheme
        address.host = "file"
        address.queryItems = [URLQueryItem(name: "drive", value: "baidu"),
                              URLQueryItem(name: "id", value: saved.path),
                              URLQueryItem(name: "name", value: saved.name)]
        guard let url = address.url else { throw TVError.invalidURL }
        return ["parse": .number(0), "url": .string(url.absoluteString), "header": header]
    }

    /// Cloud-drive share links (`/s/…`) point to files behind a login, not to web videos. They have
    /// no media URL for the sniffer to find, so they are rejected here with an actionable message
    /// instead of burning the 15-second detection clock. The hosts are the drives Yingxia supports
    /// under Cloud Files, where a saved copy of the file can be played.
    private static func isNetdiskShareLink(_ address: String) -> Bool {
        guard let url = URL(string: address), let host = url.host()?.lowercased() else { return false }
        let hosts = ["pan.baidu.com", "yun.baidu.com", "www.aliyundrive.com", "aliyundrive.com",
                     "pan.quark.cn", "drive.uc.cn", "www.123pan.com", "115.com"]
        guard hosts.contains(host) || host.hasSuffix(".pan.baidu.com") else { return false }
        return url.path.hasPrefix("/s/")
    }

    /// The preview page's posts, newest first.
    private static func latest(channel: String, endpoint: TelegramEndpoint = .direct, http: HTTPClient) async throws -> [Post] {
        try await fetchPage(channel: channel, page: 1, endpoint: endpoint, http: http)
    }

    /// One page of the channel's posts, newest first. The preview page holds about twenty posts;
    /// older ones come from `?before=<oldest id>`, so page N walks from the newest page down to it.
    private static func fetchPage(channel: String, page: Int, endpoint: TelegramEndpoint, http: HTTPClient) async throws -> [Post] {
        var before: Int? = nil
        var shown: [Post] = []
        for _ in 1...page {
            let html = try await fetch(previewURL(channel: channel, before: before, endpoint: endpoint), http: http)
            shown = Array(posts(in: html, channel: channel).reversed())
            guard let oldest = shown.last?.id else { return [] }
            before = oldest
        }
        return shown
    }

    /// The preview page, or the older posts before a post id.
    static func previewURL(channel: String, before: Int?, endpoint: TelegramEndpoint = .direct) -> URL {
        if let before {
            return endpoint.address("s/\(channel)", query: [URLQueryItem(name: "before", value: String(before))])
        }
        return endpoint.address("s/\(channel)")
    }

    /// One post, from its embed page; the preview page is the fallback when the embed
    /// page carries no post of its own.
    private static func post(channel: String, id: Int, endpoint: TelegramEndpoint, http: HTTPClient) async throws -> Post {
        if let html = try? await fetch(endpoint.address("\(channel)/\(id)", query: [URLQueryItem(name: "embed", value: "1")]), http: http),
           let post = posts(in: html, channel: channel).first(where: { $0.id == id }) { return post }
        // The embed page didn't carry it: the preview page that ends at it (`?before=` the next id) has it in one
        // request, however old it is; walking the pages from the newest down took one request per twenty posts, and
        // the whole channel's history for a post that is gone.
        let html = try await fetch(previewURL(channel: channel, before: id + 1, endpoint: endpoint), http: http)
        if let post = posts(in: html, channel: channel).first(where: { $0.id == id }) { return post }
        throw TVError.unsupported(L10n.text("This Telegram post is no longer in the channel's public preview."))
    }

    private static func fetch(_ url: URL, http: HTTPClient) async throws -> String {
        let (data, _) = try await http.get(url, headers: ["User-Agent": HTTPClient.userAgent, "Referer": "https://t.me/"])
        guard let text = String(data: data, encoding: .utf8) else {
            throw TVError.unsupported(L10n.text("Telegram returned a page Yingxia can't read."))
        }
        return text
    }

    static func videoFields(_ post: Post) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["vod_id": .string(String(post.id)), "vod_name": .string(post.title)]
        if let poster = post.poster { fields["vod_pic"] = .string(poster) }
        if !post.date.isEmpty { fields["vod_remarks"] = .string(post.date) }
        return fields
    }

    /// A post's details: its own video first, then its comment-thread episode ranges and
    /// external lines, in the order the post writes them.
    static func details(_ post: Post, channel: String, endpoint: TelegramEndpoint = .direct) throws -> [String: JSONValue] {
        var episodes: [(name: String, address: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ address: String) {
            guard seen.insert(address).inserted else { return }
            episodes.append((lineName(name.isEmpty ? L10n.text("Play") : name), address))
        }
        if let video = post.video { add(L10n.text("Play"), video) }
        for link in post.links { add(link.name, embedAddress(link.url, endpoint: endpoint)) }
        guard !episodes.isEmpty else {
            throw TVError.unsupported(L10n.text("This Telegram post has no playable video."))
        }
        var fields = videoFields(post)
        fields["vod_content"] = .string(post.text)
        fields["vod_play_from"] = .string("Telegram")
        fields["vod_play_url"] = .string(episodes.map { "\($0.name)$\($0.address)" }.joined(separator: "#"))
        return fields
    }

    /// TVBox's play lists separate episodes with `#` and names from addresses with `$`.
    private static func lineName(_ name: String) -> String {
        name.replacingOccurrences(of: "$", with: "＄").replacingOccurrences(of: "#", with: "＃")
    }

    /// A Telegram post or comment address as its embed page, which carries the video, read through `endpoint`.
    static func embedAddress(_ address: String, endpoint: TelegramEndpoint = .direct) -> String {
        guard let url = URL(string: address), let telegram = TelegramEndpoint.split(url)?.telegram else { return address }
        var components = URLComponents(url: telegram, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        if !items.contains(where: { $0.name == "embed" }) { items.append(URLQueryItem(name: "embed", value: "1")) }
        components?.queryItems = items
        guard let page = components?.url else { return address }
        return endpoint.address(page).absoluteString
    }

    // MARK: - Public preview parsing

    struct Link: Equatable {
        let name: String
        let url: String
    }

    struct Post: Equatable {
        let id: Int
        let title: String
        let text: String
        let poster: String?
        let date: String
        let video: String?
        let links: [Link]
    }

    /// Every post a preview or embed page carries, in page order.
    static func posts(in html: String, channel: String) -> [Post] {
        guard let regex = try? NSRegularExpression(pattern: "data-post=\"([^\"]+)\"") else { return [] }
        let source = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
        var posts: [Post] = []
        for (index, match) in matches.enumerated() {
            let parts = source.substring(with: match.range(at: 1)).split(separator: "/")
            guard parts.count == 2, let id = Int(parts[1]) else { continue }
            let start = match.range.location
            let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            posts.append(parse(source.substring(with: NSRange(location: start, length: end - start)), id: id, channel: channel))
        }
        return posts
    }

    private static func parse(_ chunk: String, id: Int, channel: String) -> Post {
        let poster = first("background-image:url\\('([^']+)'\\)", in: chunk)
            ?? first("<video[^>]*\\bposter=\"([^\"]+)\"", in: chunk)
            ?? first("<img[^>]+src=\"([^\"]+)\"", in: chunk)
        let textHTML = first("tgme_widget_message_text[^>]*>(.*?)</div>", in: chunk) ?? ""
        let text = HTMLText.plain(textHTML)
        let title = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        let date = first("<time[^>]+datetime=\"([^\"]+)\"", in: chunk).map { String($0.prefix(10)) } ?? ""
        return Post(id: id, title: title.isEmpty ? L10n.text("Telegram post") : title, text: text, poster: poster,
                    date: date, video: video(in: chunk), links: links(in: textHTML, channel: channel, postID: id))
    }

    /// The direct video address a page carries, if any.
    static func video(in html: String) -> String? {
        first("<video[^>]*\\bsrc=\"([^\"]+)\"", in: html)
            ?? first("<source[^>]*\\bsrc=\"([^\"]+)\"", in: html)
            ?? first("property=\"og:video\"[^>]*content=\"([^\"]+)\"", in: html)
            ?? first("content=\"([^\"]+)\"[^>]*property=\"og:video\"", in: html)
    }

    /// The episode links in a post's text: its comment-thread ranges, links to other posts
    /// of the channel, and external lines. Mentions, hashtags and the channel's own
    /// address stay out.
    private static func links(in html: String, channel: String, postID: Int) -> [Link] {
        groups("<a[^>]+href=\"([^\"]+)\"[^>]*>(.*?)</a>", in: html).compactMap { match in
            let href = HTMLText.name(match[1])
            let name = HTMLText.name(match[2].replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            guard let url = URL(string: href), let host = url.host()?.lowercased() else { return nil }
            if TelegramEndpoint.hosts.contains(host) {
                let parts = url.pathComponents.filter { $0 != "/" }
                guard parts.count == 2, parts[0].lowercased() == channel.lowercased(), let id = Int(parts[1]) else { return nil }
                // The post's own address is its date link, not an episode; its comment thread is.
                let isComment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "comment" }) == true
                if id == postID, !isComment { return nil }
                return Link(name: name, url: href)
            }
            return href.contains("?q=") ? nil : Link(name: name, url: href)
        }
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        groups(pattern, in: text).first.flatMap { $0.count > 1 ? $0[1] : nil }
    }

    private static func groups(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }

    private static let reserved: Set<String> = ["joinchat", "addstickers", "addlist", "share", "iv", "proxy", "socks",
                                                "setlanguage", "confirmphone", "login", "stickers", "wallpapers", "themes",
                                                "giftcode", "boost", "premium", "passport", "invoice", "telegram", "tme"]

    /// A Telegram username: 5–32 ASCII letters, digits and underscores, starting with a letter.
    private static func isUsername(_ value: String) -> Bool {
        guard (5...32).contains(value.count), !reserved.contains(value.lowercased()),
              let first = value.first, first.isASCII, first.isLetter else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

extension Site {
    /// A public Telegram channel, browsed from its public preview.
    public var isTelegram: Bool { key.hasPrefix(TelegramSource.keyPrefix) }
}
