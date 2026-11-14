import Foundation

/// A book source list that a page of lists links to, for the viewer to add.
public struct NovelSourceOffer: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var address: URL
    public var id: URL { address }
    public init(name: String, address: URL) { self.name = name; self.address = address }
}

/// Pages that index Legado book source lists. A Legado subscription source (订阅源: a `sourceUrl` with article rules and
/// no `bookSourceUrl`) opens such a page inside Legado, and the page marks each list with a one-tap import link
/// (`legado://import/bookSource?src=…`). Yingxia reads those links and offers the lists instead of a feed reader.
public enum NovelSourceIndex {
    /// The pages a Legado subscription source opens: its `sortUrl` entries (`name::url`, one per line or `&&`), else its
    /// `sourceUrl`; scripted addresses are skipped. Nil when `data` isn't a subscription source, empty when it is one
    /// with no page to read.
    public static func pages(from data: Data) -> [URL]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let objects = (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? (value as? [String: Any]).map { [$0] } ?? []
        let feeds = objects.filter {
            $0["bookSourceUrl"] == nil && $0["sourceUrl"] is String && ($0["ruleArticles"] != nil || $0["sortUrl"] != nil || $0["singleUrl"] != nil)
        }
        guard !feeds.isEmpty, feeds.count * 2 >= objects.count else { return nil }
        var seen = Set<String>(), pages: [URL] = []
        for feed in feeds {
            let base = (feed["sourceUrl"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let sorts = (feed["sortUrl"] as? String ?? "")
                .components(separatedBy: "\n").flatMap { $0.components(separatedBy: "&&") }
                .map { line in (line.range(of: "::").map { String(line[$0.upperBound...]) } ?? line).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for text in sorts.isEmpty ? [base?.absoluteString ?? ""] : sorts {
                guard !text.contains("{{"), !text.hasPrefix("@js"), !text.hasPrefix("<js"),
                      let url = URL(string: text, relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url.absoluteString).inserted else { continue }
                pages.append(url)
            }
        }
        return Array(pages.prefix(5))
    }

    /// The book source lists a web page links to with Legado import links, each named after the closest paragraph,
    /// heading or bold text before its link ("XIU2精品书源"), else after its file. Subscription-source, theme and other
    /// import links are left out.
    public static func offers(inPage data: Data, origin: URL) -> [NovelSourceOffer] {
        guard let html = String(data: data, encoding: .utf8), html.contains("://") else { return [] }
        let text = html as NSString
        var offers: [NovelSourceOffer] = [], seen = Set<URL>(), segmentStart = 0
        for match in links.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let raw = decodeEntities(text.substring(with: match.range))
            let lower = raw.lowercased()
            guard lower.contains("booksource"), let link = URL(string: raw), let inner = NovelSources.importAddress(link),
                  let address = URL(string: inner.absoluteString, relativeTo: origin)?.absoluteURL,
                  ["http", "https"].contains(address.scheme?.lowercased() ?? "") else { continue }
            defer { segmentStart = match.range.location + match.range.length }
            guard seen.insert(address).inserted else { continue }
            let before = text.substring(with: NSRange(location: segmentStart, length: match.range.location - segmentStart))
            offers.append(NovelSourceOffer(name: label(before) ?? NovelSources.title(of: address), address: address))
        }
        return offers
    }

    /// Downloads the pages and gathers the lists they offer. Throws when none offers any.
    public static func offers(pages: [URL], http: HTTPClient) async throws -> [NovelSourceOffer] {
        var offers: [NovelSourceOffer] = [], failure: (any Error)?
        for page in pages {
            do {
                let (data, finalURL) = try await http.get(page, headers: ["User-Agent": HTTPClient.subscriptionUserAgent])
                for offer in Self.offers(inPage: data, origin: finalURL) where !offers.contains(where: { $0.address == offer.address }) { offers.append(offer) }
            } catch { failure = error }
        }
        if offers.isEmpty, let failure, pages.count == 1 { throw failure }
        guard !offers.isEmpty else {
            throw TVError.unsupported(L10n.text("This is a Legado subscription source (订阅源), not a book source list. Add the address of a book source list instead."))
        }
        return offers
    }

    private static let links = try! NSRegularExpression(pattern: #"(?i)\b(?:legado|yuedu)://[^\s"'<>]+"#)
    private static let labels = try! NSRegularExpression(pattern: #"(?is)<(p|h[1-6]|summary|strong|b|dt|th)\b[^>]*>(.*?)</\1\s*>"#)
    private static let tags = try! NSRegularExpression(pattern: #"<[^>]*>"#)

    /// The text of the last labelling element in `html`, without its tags.
    static func label(_ html: String) -> String? {
        let text = html as NSString
        for match in labels.matches(in: html, range: NSRange(location: 0, length: text.length)).reversed() {
            let inner = text.substring(with: match.range(at: 2))
            let plain = decodeEntities(tags.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length), withTemplate: " "))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !plain.isEmpty, !plain.contains("://"), plain.count <= 60 { return plain }
        }
        return nil
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
