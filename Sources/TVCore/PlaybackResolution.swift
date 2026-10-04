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
}

/// Converts the Bili spider's DASH proxy identifiers to Bilibili's progressive MP4 response.
/// The service still decides which qualities the current account is allowed to access.
enum BilibiliPlayback {
    static func resolve(_ address: String, headers supplied: [String: String], http: HTTPClient) async throws -> (url: URL, headers: [String: String])? {
        guard CatalogClient.isPluginProxy(address), let marker = address.range(of: "/proxy?") else { return nil }
        var proxy = URLComponents(); proxy.percentEncodedQuery = String(address[marker.upperBound...])
        let items = proxy.queryItems ?? []
        func parameter(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard parameter("do") == "bili" else { return nil }
        guard let aid = parameter("aid"), let cid = parameter("cid"),
              UInt64(aid) != nil, UInt64(cid) != nil else { throw TVError.invalidURL }
        var headers = supplied
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
        return (try WebAddress.resolve(url), headers)
    }
}
