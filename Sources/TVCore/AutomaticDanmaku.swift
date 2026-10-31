import Foundation

public enum OfficialVideoPage {
    /// Allow listed, episode-specific public pages only. Strip tracking and credentials.
    public static func validated(_ address: String) -> URL? {
        guard var parts = URLComponents(string: address), ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil, let host = parts.host?.lowercased() else { return nil }
        let patterns: [String: String] = ["www.iqiyi.com": #"^/v_[a-zA-Z0-9]+\.html$"#,
            "v.qq.com": #"^/x/(?:cover/[a-zA-Z0-9]+/[a-zA-Z0-9]+|page/[a-zA-Z0-9]+)\.html$"#,
            "v.youku.com": #"^/v_show/id_[a-zA-Z0-9=]+\.html$"#,
            "www.mgtv.com": #"^/b/[0-9]+/[0-9]+\.html$"#,
            "www.bilibili.com": #"^/bangumi/play/ep[0-9]+/?$"#]
        guard let pattern = patterns[host], parts.path.range(of: pattern, options: .regularExpression) != nil else { return nil }
        parts.scheme = "https"; parts.host = host; parts.query = nil; parts.fragment = nil
        return parts.url
    }
}

public struct DanmakuTrack: Codable, Hashable, Sendable {
    public let number: Int?
    public let title: String
    public let page: URL?
    public let id: String?
    public init(number: Int?, title: String, page: URL? = nil, id: String? = nil) {
        self.number = number; self.title = title; self.page = page; self.id = id
    }
}
public struct DanmakuMapping: Codable, Sendable {
    public let provider: String
    public let title: String
    public let year: String?
    public let tracks: [DanmakuTrack]
    public init(provider: String, title: String, year: String?, tracks: [DanmakuTrack]) {
        self.provider = provider; self.title = title; self.year = year; self.tracks = tracks
    }
    public func track(for context: PlaybackHistoryContext) -> DanmakuTrack? {
        guard CatalogDanmakuMatcher.normalized(title) == CatalogDanmakuMatcher.normalized(context.videoName),
              context.year == nil || year == nil || context.year == year else { return nil }
        if let number = CatalogDanmakuMatcher.episodeNumber(context.episodeName) {
            let matches = tracks.filter { $0.number == number }
            return matches.count == 1 ? matches.first : nil
        }
        let movies = ["正片", "电影", "hd", "1080p", "720p", "完整版", "蓝光"]
        return tracks.count == 1 && movies.contains(CatalogDanmakuMatcher.normalized(context.episodeName)) ? tracks.first : nil
    }
}
public struct AutomaticDanmakuResult: Codable, Sendable {
    public let comments: [CatalogDanmakuComment]
    public let track: String
    public let source: String
    public var cached = false
    public var state: String
    public init(comments: [CatalogDanmakuComment], track: String, source: String, cached: Bool = false, state: String) {
        self.comments = comments; self.track = track; self.source = source; self.cached = cached; self.state = state
    }
}

/// Bounded, cancellable requests are injectable for deterministic protocol and cache acceptance.
public struct DanmakuHTTP: Sendable {
    public var send: @Sendable (URLRequest) async throws -> Data
    public init(send: @escaping @Sendable (URLRequest) async throws -> Data = Self.live) { self.send = send }
    public static func live(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: request.value(forHTTPHeaderField: "X-AppId") == nil ? nil : DandanplayRedirectPolicy.shared)
        guard let response = response as? HTTPURLResponse else { throw TVError.invalidConfiguration }
        guard (200..<300).contains(response.statusCode) else {
            throw TVError.unsupported(L10n.text("The server returned HTTP %lld.", response.statusCode))
        }
        guard response.expectedContentLength <= CatalogDanmakuParser.maximumBytes else { throw TVError.invalidConfiguration }
        var data = Data()
        for try await byte in bytes {
            guard data.count < CatalogDanmakuParser.maximumBytes else { throw TVError.invalidConfiguration }
            data.append(byte)
        }
        try Task.checkCancellation(); return data
    }
    func json(_ url: URL, body: Data? = nil, referer: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data = try await send(request)
        guard data.count <= CatalogDanmakuParser.maximumBytes, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TVError.invalidConfiguration }
        return root
    }
}

public struct OfficialDanmakuCatalog: Sendable {
    public let http: DanmakuHTTP
    public init(http: DanmakuHTTP = .init()) { self.http = http }
    public func iqiyi(_ context: PlaybackHistoryContext) async throws -> DanmakuMapping? {
        var url = URLComponents(string: "https://mesh.if.iqiyi.com/portal/lw/search/homePageV3")!
        url.queryItems = ["key": context.videoName, "current_page": "1", "mode": "1", "source": "input", "pcv": "13.074.22699",
            "version": "13.074.22699", "pageNum": "1", "pageSize": "25", "pu": "", "u": UUID().uuidString,
            "userVip": "0", "vipType": "-1", "osShortName": "win10"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let root = try await http.json(url.url!, referer: "https://www.iqiyi.com/")
        return Self.parseIQiyi(root, context: context)
    }
    public static func parseIQiyi(_ root: [String: Any], context: PlaybackHistoryContext) -> DanmakuMapping? {
        let templates = (root["data"] as? [String: Any])?["templates"] as? [[String: Any]] ?? []
        let albums = templates.flatMap { item -> [[String: Any]] in
            if let album = item["albumInfo"] as? [String: Any] { return [album] }
            return item["intentAlbumInfos"] as? [[String: Any]] ?? []
        }
        let matches = albums.filter { album in
            guard let title = album["title"] as? String, CatalogDanmakuMatcher.normalized(HTMLText.plain(title)) == CatalogDanmakuMatcher.normalized(context.videoName) else { return false }
            let year = (album["year"] as? [String: Any])?["value"] as? String ?? album["superscript"] as? String
            return context.year == nil || year == context.year
        }
        // Repeated templates for the same album are common; remakes remain ambiguous.
        var seen = Set<String>()
        let unique = matches.filter { seen.insert(String(describing: $0["qipuId"] ?? $0["pageUrl"] ?? "")).inserted }
        guard unique.count == 1, let album = unique.first else { return nil }
        let tracks = (album["videos"] as? [[String: Any]] ?? []).compactMap { row -> DanmakuTrack? in
            let label = (row["number"] as? String) ?? (row["number"] as? NSNumber)?.stringValue ?? ""
            guard let number = Int(label), number > 0, let address = row["pageUrl"] as? String,
                  let page = OfficialVideoPage.validated(address) else { return nil }
            return DanmakuTrack(number: number, title: row["title"] as? String ?? label, page: page)
        }
        // Movies may have a single official page but no numbered videos.
        let movie = (album["channel"] as? String ?? "").hasPrefix("电影,")
        let fallback = movie ? (album["pageUrl"] as? String).flatMap(OfficialVideoPage.validated).map { [DanmakuTrack(number: nil, title: "正片", page: $0)] } : nil
        return DanmakuMapping(provider: "iqiyi", title: HTMLText.plain(album["title"] as? String ?? ""),
            year: (album["year"] as? [String: Any])?["value"] as? String, tracks: tracks.isEmpty ? fallback ?? [] : tracks)
    }
    public func tencent(_ context: PlaybackHistoryContext) async throws -> DanmakuMapping? {
        let endpoint = URL(string: "https://pbaccess.video.qq.com/trpc.videosearch.mobile_search.MultiTerminalSearch/MbSearch?vplatform=2")!
        let payload: [String: Any] = ["version": "25071701", "clientType": 1, "query": context.videoName, "pagenum": 0,
            "pagesize": 30, "uuid": UUID().uuidString, "isPrefetch": true, "isneedQc": true,
            "extraInfo": ["multi_terminal_pc": "1", "themeType": "1", "sugRelatedIds": "{}", "appVersion": ""]]
        let root = try await http.json(endpoint, body: JSONSerialization.data(withJSONObject: payload), referer: "https://v.qq.com/")
        let data = root["data"] as? [String: Any] ?? [:]
        let boxes = data["areaBoxList"] as? [[String: Any]] ?? []
        let items = boxes.flatMap { $0["itemList"] as? [[String: Any]] ?? [] } + ((data["normalList"] as? [String: Any])?["itemList"] as? [[String: Any]] ?? [])
        var seen = Set<String>()
        let matches = items.filter { item in
            guard let info = item["videoInfo"] as? [String: Any], let title = info["title"] as? String,
                  CatalogDanmakuMatcher.normalized(HTMLText.plain(title)) == CatalogDanmakuMatcher.normalized(context.videoName),
                  (info["playFlag"] as? Int) != 2, let id = (item["doc"] as? [String: Any])?["id"] as? String,
                  id.range(of: #"^[a-zA-Z0-9]+$"#, options: .regularExpression) != nil else { return false }
            let year = (info["year"] as? NSNumber)?.stringValue ?? info["year"] as? String
            return (context.year == nil || context.year == year) && seen.insert(id).inserted
        }
        guard matches.count == 1, let item = matches.first, let info = item["videoInfo"] as? [String: Any],
              let cid = (item["doc"] as? [String: Any])?["id"] as? String else { return nil }
        let initial = try await tencentPage(cid: cid, pageContext: "cid=\(cid)&detail_page_type=1&req_from=web_vsite&req_type=0")
        var tracks = Self.tencentTracks(initial, cid: cid)
        // Fetch only the tab containing the current episode, never crawl the whole series.
        if let number = CatalogDanmakuMatcher.episodeNumber(context.episodeName), !tracks.contains(where: { $0.number == number }) {
            let tabs = Self.tencentTabs(initial)
            if let tab = tabs.first(where: { tab in
                let title = tab["title"] as? String ?? ""
                let bounds = title.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                return bounds.count == 2 && bounds[0] <= number && number <= bounds[1]
            }), let page = tab["page_context"] as? String {
                tracks += Self.tencentTracks(try await tencentPage(cid: cid, pageContext: page), cid: cid)
            }
        }
        var pages = Set<URL>()
        tracks = tracks.filter { $0.page.map { pages.insert($0).inserted } ?? false }
        return DanmakuMapping(provider: "tencent", title: HTMLText.plain(info["title"] as? String ?? ""),
            year: (info["year"] as? NSNumber)?.stringValue ?? info["year"] as? String, tracks: tracks)
    }
    private func tencentPage(cid: String, pageContext: String) async throws -> [String: Any] {
        let url = URL(string: "https://pbaccess.video.qq.com/trpc.universal_backend_service.page_server_rpc.PageServer/GetPageData?video_appid=3000010&vversion_name=8.2.96&vversion_platform=2")!
        let body: [String: Any] = ["has_cache": 1, "page_params": ["req_from": "web_vsite", "page_id": "vsite_episode_list", "page_type": "detail_operation",
            "id_type": "1", "page_size": "", "cid": cid, "vid": "", "lid": "", "page_num": "", "page_context": pageContext, "detail_page_type": "1"]]
        return try await http.json(url, body: JSONSerialization.data(withJSONObject: body), referer: "https://v.qq.com/")
    }
    private static func tencentModules(_ root: [String: Any]) -> [[String: Any]] {
        let data = root["data"] as? [String: Any] ?? [:]
        return (data["module_list_datas"] as? [[String: Any]] ?? []).flatMap { $0["module_datas"] as? [[String: Any]] ?? [] }
    }
    static func tencentTabs(_ root: [String: Any]) -> [[String: Any]] {
        tencentModules(root).flatMap { module -> [[String: Any]] in
            guard let text = (module["module_params"] as? [String: Any])?["tabs"] as? String,
                  let data = text.data(using: .utf8) else { return [] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        }
    }
    public static func tencentTracks(_ root: [String: Any], cid: String) -> [DanmakuTrack] {
        tencentModules(root).flatMap { ($0["item_data_lists"] as? [String: Any])?["item_datas"] as? [[String: Any]] ?? [] }.compactMap { item in
            guard let p = item["item_params"] as? [String: Any], p["is_trailer"] as? String != "1",
                  let vid = p["vid"] as? String, let page = OfficialVideoPage.validated("https://v.qq.com/x/cover/\(cid)/\(vid).html") else { return nil }
            let label = p["union_title"] as? String ?? p["title"] as? String ?? ""
            let number = (p["episode"] as? String).flatMap(Int.init) ?? CatalogDanmakuMatcher.episodeNumber(label)
            guard number != nil else { return nil }
            return DanmakuTrack(number: number, title: label, page: page)
        }
    }
}
