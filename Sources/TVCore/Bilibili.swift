import Foundation
import CryptoKit

/// Bilibili as a source of its own: a built-in site that runs the bundled Bili.js port in its
/// built-in mode (feeds, rankings, zones, PGC and search), the signed-in account, and the request
/// signing that playback needs. Playback itself is `BilibiliStreams`.
public enum Bilibili {
    public static let siteKey = "builtin.bilibili"
    static let referer = "https://www.bilibili.com"
    /// The video CDN answers 403 to AVFoundation's own user agent and to requests without the referer.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
    static var mediaHeaders: [String: String] { ["Referer": referer, "User-Agent": userAgent] }
}

extension Site {
    /// Offered with every subscription, after the subscription's own sources.
    public static let bilibili: Site = {
        let name = L10n.text("Bilibili")
        let raw: [String: JSONValue] = ["key": .string(Bilibili.siteKey), "name": .string(name), "type": .number(3), "api": .string("csp_Bili"),
                                        "searchable": .number(1), "quickSearch": .number(1), "filterable": .number(1)]
        return Site(key: Bilibili.siteKey, name: name, type: 3, api: "csp_Bili", raw: raw)
    }()
    /// A source the app provides itself; it never falls back to a subscription's JAR.
    public var isBuiltIn: Bool { isBilibili || key == Hongguo.siteKey || ShortDramas.keys.contains(key) }
    public var isBilibili: Bool { key == Bilibili.siteKey }
    public static var builtInSites: [Site] { [.bilibili, .hongguo, .xifan, .hema] }
    /// Per-source bundled configuration. Bilibili reads the account on each request so login
    /// changes start a new session; Hongguo receives localized labels without account cookies.
    var builtInExtension: JSONValue {
        if key == Hongguo.siteKey { return Hongguo.configuration }
        if ShortDramas.keys.contains(key) { return ShortDramas.configuration(name: name) }
        return .object(["builtin": .bool(true), "cookie": .string(BilibiliAccount.load().cookie)])
    }
}

extension Subscription {
    /// The subscription's sources and live playlists plus the built-in ones; the app shows this, the
    /// document keeps only its own.
    public func withBuiltInSites() -> Subscription {
        let sites = self.sites + Site.builtInSites.filter { builtin in !self.sites.contains { $0.key == builtin.key } }
        let lives = LiveSource.builtIn.filter { builtin in !self.lives.contains { $0.url == builtin.url } } + self.lives
        return Subscription(origin: origin, importedAt: importedAt, sites: sites, lives: lives, raw: raw)
    }
}

/// The signed-in Bilibili account. Kept outside disposable caches like `CloudDriveAccounts`.
public struct BilibiliAccount: Codable, Equatable, Sendable {
    public var cookie = ""
    public var name = ""
    public var vip = false
    public init() {}
    public var signedIn: Bool { cookie.contains("SESSDATA=") }

    static var fileURL: URL {
        #if os(tvOS)
        // tvOS only permits Caches; `load` restores a purged copy from user defaults.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("com.tvbox.yingxia/Bilibili/account.json")
    }
    private static let defaultsKey = "bilibiliAccount"

    public static func load() -> Self {
        if let data = try? Data(contentsOf: fileURL), let account = try? JSONDecoder().decode(Self.self, from: data) { return account }
        #if os(tvOS)
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let account = try? JSONDecoder().decode(Self.self, from: data) {
            try? account.save()
            return account
        }
        #endif
        return Self()
    }
    public func save() throws {
        let folder = Self.fileURL.deletingLastPathComponent()
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: Self.fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        #if os(tvOS)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        #endif
    }
    public static func signOut() {
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Refreshes the name and membership shown in Settings; false when the login has expired.
    public mutating func refresh() async -> Bool {
        guard signedIn, let nav = try? await BilibiliSigner.shared.json(URL(string: "https://api.bilibili.com/x/web-interface/nav")!, cookie: cookie),
              let data = nav["data"]?.object else { return signedIn }
        guard data["isLogin"] == .bool(true) else { return false }
        name = data["uname"]?.string ?? name
        vip = (data["vipStatus"]?.int ?? 0) == 1
        return true
    }
}

/// Sign in by scanning a code with the Bilibili phone app, as the web site does.
public struct BilibiliQRLogin: Sendable {
    public enum Status: Sendable, Equatable { case waiting, scanned, expired, signedIn(BilibiliAccount) }
    /// The text to encode in the QR code.
    public let code: String
    private let key: String

    public static func start() async throws -> BilibiliQRLogin {
        let reply = try await BilibiliSigner.shared.json(URL(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!, cookie: "")
        guard let data = reply["data"]?.object, let code = data["url"]?.string, let key = data["qrcode_key"]?.string, !key.isEmpty else {
            throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again."))
        }
        return BilibiliQRLogin(code: code, key: key)
    }

    public func poll() async throws -> Status {
        var components = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        Bilibili.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.data(for: request)
        let reply = try JSONDecoder().decode([String: JSONValue].self, from: body)
        let data = reply["data"]?.object ?? [:]
        switch data["code"]?.int {
        case 0: break
        case 86101: return .waiting
        case 86090: return .scanned
        default: return .expired
        }
        // The approval sets the login cookies; the redirect address carries the same values.
        var fields: [String: String] = [:]
        if let http = response as? HTTPURLResponse, let url = http.url {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) { fields[cookie.name] = cookie.value }
        }
        if let address = data["url"]?.string, let items = URLComponents(string: address)?.percentEncodedQueryItems {
            for item in items where ["DedeUserID", "DedeUserID__ckMd5", "SESSDATA", "bili_jct"].contains(item.name) && fields[item.name] == nil {
                fields[item.name] = item.value
            }
        }
        guard fields["SESSDATA"]?.isEmpty == false else { throw TVError.unsupported(L10n.text("Sign-in was approved, but Bilibili didn't return a login. Try again.")) }
        var account = BilibiliAccount()
        account.cookie = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].compactMap { name in fields[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
        _ = await account.refresh()
        try account.save()
        return .signedIn(account)
    }
}

/// Bilibili's web request conventions: a buvid device cookie and WBI-signed queries.
actor BilibiliSigner {
    static let shared = BilibiliSigner()
    private static let mixinOrder = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52]
    private var mixinKey = ""
    private var mixinDate = Date.distantPast
    private var buvid = ""
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")

    /// The account cookie plus a device id; anonymous requests without one are often refused.
    func cookie(account: String, session: URLSession = .shared) async -> String {
        if buvid.isEmpty, let reply = try? await json(URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!, cookie: "", session: session),
           let data = reply["data"]?.object, let b3 = data["b_3"]?.string, !b3.isEmpty {
            buvid = "buvid3=\(b3)" + (data["b_4"]?.string.flatMap { $0.addingPercentEncoding(withAllowedCharacters: Self.unreserved) }.map { "; buvid4=\($0)" } ?? "")
        }
        return [account, buvid].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    /// The query with `wts` and `w_rid` added.
    func sign(_ parameters: [String: String], cookie: String, session: URLSession = .shared) async throws -> String {
        if mixinKey.isEmpty || Date().timeIntervalSince(mixinDate) > 3600 {
            let nav = try await json(URL(string: "https://api.bilibili.com/x/web-interface/nav")!, cookie: cookie, session: session)
            let image = nav["data"]?.object?["wbi_img"]?.object
            func name(_ key: String) -> String { (image?[key]?.string ?? "").components(separatedBy: "/").last?.components(separatedBy: ".").first ?? "" }
            let raw = Array(name("img_url") + name("sub_url"))
            guard raw.count >= 64 else { throw TVError.unsupported(L10n.text("Bilibili refused the request. Try again later.")) }
            mixinKey = String(Self.mixinOrder.map { raw[$0] }.prefix(32))
            mixinDate = Date()
        }
        var all = parameters
        all["wts"] = String(Int(Date().timeIntervalSince1970))
        // encodeURIComponent after dropping the characters WBI removes.
        func encode(_ text: String) -> String { text.filter { !"!'()*".contains($0) }.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? "" }
        let query = all.keys.sorted().map { "\(encode($0))=\(encode(all[$0]!))" }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8)).map { String(format: "%02x", $0) }.joined()
        return query + "&w_rid=" + digest
    }

    nonisolated func json(_ url: URL, cookie: String, session: URLSession = .shared) async throws -> [String: JSONValue] {
        var request = URLRequest(url: url, timeoutInterval: 15)
        var headers = Bilibili.mediaHeaders
        headers["Referer"] = Bilibili.referer + "/"
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 { throw TVError.http(status) }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}

extension Bilibili {
    /// What a cast from the phone plays: a video part (aid, with cid when known) or a PGC episode.
    public static func castChannel(aid: Int, cid: Int, episode: Int, http: HTTPClient = HTTPClient()) async throws -> Channel {
        let signer = BilibiliSigner.shared
        let cookie = await signer.cookie(account: BilibiliAccount.load().cookie)
        var aid = aid, cid = cid, title = ""
        if episode > 0 {
            let reply = try await signer.json(URL(string: "https://api.bilibili.com/pgc/view/web/season?ep_id=\(episode)")!, cookie: cookie)
            let result = reply["result"]?.object
            let episodes = (result?["episodes"]?.array ?? []) + (result?["section"]?.array ?? []).flatMap { $0.object?["episodes"]?.array ?? [] }
            if let match = episodes.compactMap(\.object).first(where: { $0["id"]?.int == episode }) {
                aid = match["aid"]?.int ?? aid; cid = match["cid"]?.int ?? cid
                title = [result?["title"]?.string, match["title"]?.string, match["long_title"]?.string].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        if aid > 0, cid == 0 || title.isEmpty {
            let reply = try await signer.json(URL(string: "https://api.bilibili.com/x/web-interface/view?aid=\(aid)")!, cookie: cookie)
            let data = reply["data"]?.object
            if cid == 0 { cid = data?["cid"]?.int ?? 0 }
            if title.isEmpty {
                let part = data?["pages"]?.array?.compactMap(\.object).first { $0["cid"]?.int == cid }?["part"]?.string
                let pages = data?["pages"]?.array?.count ?? 0
                title = [data?["title"]?.string, pages > 1 ? part : nil].compactMap { $0 }.joined(separator: " · ")
            }
        }
        guard aid > 0, cid > 0 else { throw TVError.unsupported(L10n.text("The phone sent a video this app can't open.")) }
        let address = "http://127.0.0.1:9978/proxy?do=bili&aid=\(aid)&cid=\(cid)" + (episode > 0 ? "&ep=\(episode)" : "")
        guard let resolved = try await BilibiliPlayback.resolve(address, headers: mediaHeaders, http: http) else { throw TVError.invalidURL }
        return Channel(name: title.isEmpty ? L10n.text("Bilibili") : title, group: L10n.text("Bilibili"), url: resolved.url, headers: resolved.headers)
    }
}

extension Bilibili {
    /// A live room's stream as HLS (TS where offered, else fMP4), at the best quality the account may watch.
    public static func liveChannel(room: Int) async throws -> Channel { try await liveStream(room: room).channel }

    /// A live room's stream at `quality` (Bilibili's live qn; 10000 is the original), with the qualities
    /// the room offers this account (as `bilibili-live://room/<id>?qn=` addresses) and the one served.
    public static func liveStream(room: Int, quality: Int = 10000) async throws -> (channel: Channel, qualities: [StreamQuality], current: Int?) {
        let signer = BilibiliSigner.shared
        let cookie = await signer.cookie(account: BilibiliAccount.load().cookie)
        let reply = try await signer.json(URL(string: "https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo?room_id=\(room)&protocol=0,1&format=0,1,2&codec=0&qn=\(quality)&platform=web&ptype=8")!, cookie: cookie)
        let data = reply["data"]?.object
        guard reply["code"]?.int == 0, data?["live_status"]?.int == 1 else { throw TVError.unsupported(L10n.text("This live room is not broadcasting right now.")) }
        let playurl = data?["playurl_info"]?.object?["playurl"]?.object
        let streams = playurl?["stream"]?.array?.compactMap(\.object) ?? []
        var offered: [Int] = [], current: Int?
        func address(format: String) -> String? {
            for stream in streams where stream["protocol_name"]?.string == "http_hls" {
                for entry in stream["format"]?.array?.compactMap(\.object) ?? [] where entry["format_name"]?.string == format {
                    for codec in entry["codec"]?.array?.compactMap(\.object) ?? [] where codec["codec_name"]?.string == "avc" {
                        guard let base = codec["base_url"]?.string, let host = codec["url_info"]?.array?.first?.object else { continue }
                        offered = codec["accept_qn"]?.array?.compactMap(\.int) ?? []
                        current = codec["current_qn"]?.int
                        return (host["host"]?.string ?? "") + base + (host["extra"]?.string ?? "")
                    }
                }
            }
            return nil
        }
        // TS first: its 4-second segments buffer smoothly, while the fMP4 playlist's 1-second segments, which
        // start at the window's oldest edge, leave AVPlayer refilling at every segment and stuttering.
        guard let stream = address(format: "ts") ?? address(format: "fmp4") else { throw TVError.unsupported(L10n.text("This live room has no stream this device can play.")) }
        let info = try? await signer.json(URL(string: "https://api.live.bilibili.com/room/v1/Room/get_info?room_id=\(room)")!, cookie: cookie)
        let title = info?["data"]?.object?["title"]?.string ?? L10n.text("Bilibili Live")
        let names = Dictionary((playurl?["g_qn_desc"]?.array ?? []).compactMap { entry -> (Int, String)? in
            guard let object = entry.object, let qn = object["qn"]?.int, let name = object["desc"]?.string else { return nil }
            return (qn, name)
        }) { first, _ in first }
        let qualities = offered.sorted(by: >).compactMap { qn in
            URL(string: "\(BilibiliLive.scheme)://room/\(room)?qn=\(qn)").map { StreamQuality(id: qn, label: names[qn] ?? "\(qn)", url: $0) }
        }
        let channel = Channel(name: title, group: L10n.text("Bilibili Live"), url: try WebAddress.resolve(stream),
                              headers: ["Referer": "https://live.bilibili.com/", "User-Agent": userAgent])
        return (channel, qualities, current)
    }
}

extension Bilibili {
    /// The cid in a Bilibili media address (…/upgcxcode/…/<cid>-<n>-<quality>.mp4), as the phone app casts it.
    public static func castCID(_ url: URL) -> Int? {
        guard url.path.contains("xcode"), let match = url.lastPathComponent.firstMatch(of: /^(\d+)-\d+-\d+\.(mp4|m4s|flv)$/) else { return nil }
        return Int(match.1)
    }

    /// The video a cast part belongs to. A DLNA cast names only the part (cid) and the title, so the
    /// title is searched and the results checked for that part. Returns its aid, or nil.
    public static func castVideo(cid: Int, title: String) async -> Int? {
        let keyword = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cid > 0, !keyword.isEmpty else { return nil }
        let signer = BilibiliSigner.shared
        let cookie = await signer.cookie(account: BilibiliAccount.load().cookie)
        guard let query = try? await signer.sign(["search_type": "video", "keyword": keyword, "page": "1"], cookie: cookie),
              let reply = try? await signer.json(URL(string: "https://api.bilibili.com/x/web-interface/wbi/search/type?" + query)!, cookie: cookie) else { return nil }
        let candidates = (reply["data"]?.object?["result"]?.array ?? []).compactMap { $0.object?["aid"]?.int }.prefix(6)
        for aid in candidates {
            guard let view = try? await signer.json(URL(string: "https://api.bilibili.com/x/web-interface/view?aid=\(aid)")!, cookie: cookie),
                  let data = view["data"]?.object else { continue }
            let parts = (data["pages"]?.array ?? []).compactMap { $0.object?["cid"]?.int } + [data["cid"]?.int].compactMap { $0 }
            if parts.contains(cid) { return aid }
        }
        return nil
    }
}
