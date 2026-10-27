import Foundation

public struct PlaybackChoice: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let address: String
    static func parse(_ value: JSONValue?, prefix: String = "", fallbackName: String) -> [PlaybackChoice] {
        if let text = value?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [PlaybackChoice(id: 0, name: fallbackName, address: prefix + text)]
        }
        guard let values = value?.array else { return [] }
        var choices: [PlaybackChoice] = []
        for index in stride(from: 0, to: values.count - values.count % 2, by: 2) {
            guard let name = values[index].string, let address = values[index + 1].string,
                  !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            choices.append(PlaybackChoice(id: index / 2, name: name.isEmpty ? fallbackName : name, address: prefix + address))
        }
        return choices
    }
}

public struct PlaybackPlan: Sendable {
    public let choices: [PlaybackChoice]
    public let headers: [String: String]
    public let group: String
    public let requiresWebDetection: Bool
    /// Site click when that is non-empty, otherwise the play result click.
    public let click: String
    /// `json:` or `parse:` copied off the front of the address. Empty when the prefix is already joined on, or there is none.
    public let webPlayURL: String
    /// The play result's subtitle files (`subs`).
    public let subtitles: [ExternalSubtitle]
    public init(choices: [PlaybackChoice], headers: [String: String], group: String, requiresWebDetection: Bool, click: String = "", webPlayURL: String = "",
                subtitles: [ExternalSubtitle] = []) {
        self.choices = choices
        self.headers = headers
        self.group = group
        self.requiresWebDetection = requiresWebDetection
        self.click = click
        self.webPlayURL = webPlayURL
        self.subtitles = subtitles
    }
}

/// Resolves the Bili spider's proxy identifiers: Bilibili's DASH streams as HLS (`BilibiliStreams`),
/// else its progressive MP4. The service still decides which qualities the current account may play.
enum BilibiliPlayback {
    static func resolve(_ address: String, headers supplied: [String: String], http: HTTPClient) async throws -> (url: URL, headers: [String: String])? {
        guard CatalogClient.isPluginProxy(address), let marker = address.range(of: "/proxy?") else { return nil }
        var proxy = URLComponents(); proxy.percentEncodedQuery = String(address[marker.upperBound...])
        let items = proxy.queryItems ?? []
        func parameter(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard parameter("do") == "bili" else { return nil }
        guard let aid = parameter("aid"), let cid = parameter("cid"),
              UInt64(aid) != nil, UInt64(cid) != nil else { throw TVError.invalidURL }
        do {
            if let stream = try await BilibiliStreams.stream(aid: aid, cid: cid, episode: parameter("ep").flatMap { UInt64($0) != nil ? $0 : nil }, session: http.session) {
                return (stream, Bilibili.mediaHeaders)
            }
        } catch let refusal as BilibiliStreams.Refusal {
            throw TVError.unsupported(refusal.message)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Diagnostics.shared.record(.warning, "bilibili", "dash failed aid=\(aid) cid=\(cid): \(error.localizedDescription); trying MP4")
        }
        var headers = supplied
        let account = BilibiliAccount.load()
        if account.signedIn { headers["Cookie"] = account.cookie }
        if !headers.keys.contains(where: { $0.lowercased() == "referer" }) { headers["Referer"] = "https://www.bilibili.com/" }
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = HTTPClient.userAgent }
        var endpoint = URLComponents(string: "https://api.bilibili.com/x/player/playurl")!
        endpoint.queryItems = [URLQueryItem(name: "avid", value: aid), URLQueryItem(name: "cid", value: cid),
                               URLQueryItem(name: "qn", value: parameter("qn") ?? "16"), URLQueryItem(name: "fnval", value: "0"), URLQueryItem(name: "fnver", value: "0")]
        let (data, _) = try await http.get(endpoint.url!, headers: headers)
        let response = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard response["code"]?.int == 0 else {
            throw TVError.unsupported(response["message"]?.string ?? L10n.text("The API did not return a single playback URL."))
        }
        let media = response["data"]?.object
        let files = media?["durl"]?.array ?? []
        guard files.count == 1, let url = files.first?.object?["url"]?.string,
              (media?["format"]?.string ?? "").lowercased().contains("mp4") else {
            throw TVError.unsupported(L10n.text("This video has no single MP4 stream available for this account."))
        }
        headers["Cookie"] = nil
        let resolved = try WebAddress.resolve(url)
        DanmakuSource.register(resolved, bilibiliCID: cid, duration: media?["timelength"]?.int.map { Double($0) / 1000 })
        return (resolved, headers)
    }
}
