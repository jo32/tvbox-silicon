import Foundation

/// A public Telegram channel as a source of its own, read from Telegram's public preview
/// (`t.me/s/<channel>`) without signing in: the viewer adds the channel's address
/// (`https://t.me/<channel>`) as a subscription, and its posts list as titles. A post's
/// episodes are the video it carries, the episode-range links into its comment thread
/// (short-drama channels post one range per comment), and any external "main line" link;
/// playback resolves a comment or embed page to its direct video address when the public
/// page carries one, and otherwise hands the page to the usual web detection. Private
/// channels and invite links have no public preview and are not accepted.
public enum TelegramSource {
    static let keyPrefix = "builtin.telegram."
    static let api = "csp_YingxiaTelegram"

    /// The public channel a Telegram address names: `t.me/<channel>`, its preview
    /// `t.me/s/<channel>`, or a post in it. Invite links (`t.me/+…`, `t.me/joinchat/…`)
    /// and private channels (`t.me/c/…`) name none.
    public static func channel(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), ["t.me", "telegram.me", "telegram.dog", "www.t.me"].contains(host) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
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

    /// A subscription holding just this channel's source.
    public static func subscription(_ channel: String, origin: URL) -> Subscription {
        Subscription(origin: origin, importedAt: Date(), sites: [site(channel)], lives: [], raw: [:])
    }

    static func site(_ channel: String) -> Site {
        let key = keyPrefix + channel.lowercased(), name = "Telegram @\(channel)"
        let raw: [String: JSONValue] = ["key": .string(key), "name": .string(name), "type": .number(3), "api": .string(api),
                                        "searchable": .number(1), "quickSearch": .number(1),
                                        "ext": .object(["channel": .string(channel)])]
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
        if let address = params["play"] { return try await play(address, http: http) }
        if let ids = params["ids"], let id = Int(ids) {
            return ["list": .array([.object(try details(try await post(channel: channel, id: id, http: http), channel: channel))])]
        }
        let page = max(1, Int(params["pg"] ?? "") ?? 1)
        let posts = try await fetchPage(channel: channel, page: page, http: http)
        if let query = params["wd"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let found = posts.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.text.localizedCaseInsensitiveContains(query) }
            return ["list": .array(found.map { .object(videoFields($0)) }), "pagecount": .number(1)]
        }
        // The preview page holds about twenty posts; a non-empty page may have older ones, so the count
        // stays high until a page comes back empty (#2234).
        let pageCount = posts.isEmpty ? page : 1000
        return ["class": .array([.object(["type_id": .string("latest"), "type_name": .string(L10n.text("Latest"))])]),
                "list": .array(posts.map { .object(videoFields($0)) }), "pagecount": .number(pageCount)]
    }

    /// A direct media address plays as-is. A Telegram embed or comment page is read for the
    /// video address it carries, so playback stays in the app; a page without one (an
    /// external line, or a video too large for the public widget) goes to web detection.
    private static func play(_ address: String, http: HTTPClient) async throws -> [String: JSONValue] {
        let header: JSONValue = .object(["Referer": .string("https://t.me/"), "User-Agent": .string(HTTPClient.userAgent)])
        if CatalogClient.isDirectMedia(address) { return ["parse": .number(0), "url": .string(address), "header": header] }
        if let url = try? WebAddress.resolve(address), let html = try? await fetch(url, http: http), let video = video(in: html) {
            return ["parse": .number(0), "url": .string(video), "header": header]
        }
        return ["parse": .number(1), "url": .string(address), "header": header]
    }

    /// The preview page's posts, newest first.
    private static func latest(channel: String, http: HTTPClient) async throws -> [Post] {
        try await fetchPage(channel: channel, page: 1, http: http)
    }

    /// One page of the channel's posts, newest first. The preview page holds about twenty posts;
    /// older ones come from `?before=<oldest id>`, so page N walks from the newest page down to it.
    private static func fetchPage(channel: String, page: Int, http: HTTPClient) async throws -> [Post] {
        var before: Int? = nil
        var posts: [Post] = []
        for _ in 1...page {
            let html = try await fetch(previewURL(channel: channel, before: before), http: http)
            posts = Array(posts(in: html, channel: channel).reversed())
            guard let oldest = posts.last?.id else { return [] }
            before = oldest
        }
        return posts
    }

    /// The preview page, or the older posts before a post id.
    static func previewURL(channel: String, before: Int?) -> URL {
        if let before {
            return URL(string: "https://t.me/s/\(channel)?before=\(before)")!
        }
        return URL(string: "https://t.me/s/\(channel)")!
    }

    /// One post, from its embed page; the preview page is the fallback when the embed
    /// page carries no post of its own.
    private static func post(channel: String, id: Int, http: HTTPClient) async throws -> Post {
        if let html = try? await fetch(URL(string: "https://t.me/\(channel)/\(id)?embed=1")!, http: http),
           let post = posts(in: html, channel: channel).first(where: { $0.id == id }) { return post }
        guard let post = try await latest(channel: channel, http: http).first(where: { $0.id == id }) else {
            throw TVError.unsupported(L10n.text("This Telegram post is no longer in the channel's public preview."))
        }
        return post
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
    static func details(_ post: Post, channel: String) throws -> [String: JSONValue] {
        var episodes: [(name: String, address: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ address: String) {
            guard seen.insert(address).inserted else { return }
            episodes.append((lineName(name.isEmpty ? L10n.text("Play") : name), address))
        }
        if let video = post.video { add(L10n.text("Play"), video) }
        for link in post.links { add(link.name, embedAddress(link.url)) }
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

    /// A Telegram post or comment address as its embed page, which carries the video.
    static func embedAddress(_ address: String) -> String {
        guard var components = URLComponents(string: address), let host = components.host?.lowercased(),
              host == "t.me" || host == "telegram.me" else { return address }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "embed" }) { items.append(URLQueryItem(name: "embed", value: "1")) }
        components.queryItems = items
        return components.url?.absoluteString ?? address
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
            if host == "t.me" || host == "telegram.me" || host == "telegram.dog" {
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
