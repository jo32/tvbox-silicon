import CommonCrypto
import Foundation

/// Ximalaya (喜马拉雅) for Legado audio sources (听书, #1130). The sources in circulation read albums through Ximalaya's
/// app API, which changed under them: `fmobile-album/album/track` now answers every request with ret 11
/// ("请求参数出错啦"), and the older `mobile/others/ca/album/track` still lists an album's tracks but with every play
/// address blank. So, without editing the sources:
/// - a track list asked of the retired address is asked of the older one and handed back in the shape the source reads;
/// - each blank play address becomes the track's page, `https://www.ximalaya.com/sound/<id>`;
/// - when such a chapter plays, its sound comes from the web player's own track info. Only what the web player would
///   play signed out (free tracks): a paid track says so.
enum XimalayaAudio {
    private static let appHost = "mobile.ximalaya.com"
    private static let retired = "/fmobile-album/album/track/"
    private static let listing = "/mobile/others/ca/album/track/"
    private static let playFields = ["playPathAacv224", "playPathAacv164", "playUrl64", "playUrl32"]
    /// The web player's key for its track addresses (AES-128, ECB).
    private static let key: [UInt8] = [0xaa, 0xad, 0x3e, 0x4f, 0xd5, 0x40, 0xb0, 0xf7, 0x9d, 0xca, 0x95, 0x60, 0x6e, 0x72, 0xbf, 0x93]

    /// A page of an album's track list, as the older address names it.
    struct Page: Equatable {
        var album: Int, ascending: Bool, page: Int, size: Int
        var url: URL { URL(string: "http://\(XimalayaAudio.appHost)\(XimalayaAudio.listing)\(album)/\(ascending)/\(page)/\(size)")! }

        init(album: Int, ascending: Bool, page: Int, size: Int) {
            self.album = album; self.ascending = ascending; self.page = page; self.size = size
        }
        /// The page an address lists: the older address, or the retired one's query.
        init?(_ url: URL) {
            guard url.host?.lowercased() == XimalayaAudio.appHost else { return nil }
            let path = url.path
            if path.hasPrefix(XimalayaAudio.listing) {
                let parts = path.dropFirst(XimalayaAudio.listing.count).split(separator: "/")
                guard parts.count >= 4, let album = Int(parts[0]), let page = Int(parts[2]), let size = Int(parts[3]) else { return nil }
                self.init(album: album, ascending: parts[1] != "false", page: page, size: size)
            } else if path.hasPrefix(XimalayaAudio.retired) {
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
                guard let album = value("albumId").flatMap({ Int($0) }) else { return nil }
                self.init(album: album, ascending: value("isAsc") != "false", page: max(1, value("pageId").flatMap { Int($0) } ?? 1),
                          size: min(200, max(1, value("pageSize").flatMap { Int($0) } ?? 200)))
            } else { return nil }
        }
    }

    /// Each album's last page, from its first answer: sources ask for up to 40 pages, and those past the end are
    /// answered here, empty, instead of by Ximalaya.
    nonisolated(unsafe) private static var lastPages: [Int: Int] = [:]
    private static let lock = NSLock()

    /// Where a source's request goes instead: the older track list for the retired one. Nil for every other address.
    static func request(for url: URL) -> URL? {
        guard url.host?.lowercased() == appHost, url.path.hasPrefix(retired), let page = Page(url) else { return nil }
        return page.url
    }

    /// An answer given without asking Ximalaya: a page past the album's last.
    static func localAnswer(requested: URL) -> Data? {
        guard let page = Page(requested), let last = lock.withLock({ lastPages[page.album] }), page.page > last else { return nil }
        return answer(list: [], page: page, last: last, total: nil, album: nil, retired: requested.path.hasPrefix(retired))
    }

    /// A track list made readable to the source: blank play addresses become track pages, and an answer to the retired
    /// address takes its shape (`data.list`). Nil when the answer isn't a track list.
    static func adapt(_ data: Data, requested: URL) -> Data? {
        guard let page = Page(requested), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tracks = object["tracks"] as? [String: Any], let list = tracks["list"] as? [[String: Any]] else { return nil }
        let last = (tracks["maxPageId"] as? NSNumber)?.intValue
        if let last { lock.withLock { lastPages[page.album] = last; if lastPages.count > 200 { lastPages.removeAll() } } }
        let filled = list.map { track -> [String: Any] in
            guard playFields.allSatisfy({ ((track[$0] as? String) ?? "").isEmpty }), let id = (track["trackId"] as? NSNumber)?.intValue else { return track }
            var track = track
            for field in playFields { track[field] = soundPage(id) }
            return track
        }
        return answer(list: filled, page: page, last: last ?? page.page, total: (tracks["totalCount"] as? NSNumber)?.intValue,
                      album: object["album"], retired: requested.path.hasPrefix(retired))
    }

    private static func answer(list: [[String: Any]], page: Page, last: Int, total: Int?, album: Any?, retired: Bool) -> Data? {
        var tracks: [String: Any] = ["list": list, "pageId": page.page, "pageSize": page.size, "maxPageId": last]
        if let total { tracks["totalCount"] = total }
        var object: [String: Any] = ["ret": 0, "msg": "0", "tracks": tracks]
        if let album { object["album"] = album }
        // The retired address answered `data.list`; the older one `tracks.list`. Both are given.
        if retired { object["data"] = tracks }
        return try? JSONSerialization.data(withJSONObject: object)
    }

    static func soundPage(_ track: Int) -> String { "https://www.ximalaya.com/sound/\(track)" }

    /// The track a chapter's sound address names, when it is a Ximalaya track page.
    static func track(in address: String) -> Int? {
        guard let url = URL(string: address), let host = url.host?.lowercased(), host == "www.ximalaya.com" || host == "ximalaya.com" || host == "m.ximalaya.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "sound" else { return nil }
        return Int(parts[1])
    }

    /// The track's sound, from the web player's track info.
    static func sound(track: Int, fetch: @Sendable (URLRequest) async throws -> Data = { try await URLSession.shared.data(for: $0).0 }) async throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        var request = URLRequest(url: URL(string: "https://www.ximalaya.com/mobile-playpage/track/v3/baseInfo/\(stamp)?device=web&trackId=\(track)&trackQualityLevel=1")!,
                                 timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.ximalaya.com/sound/\(track)", forHTTPHeaderField: "Referer")
        return try sound(from: await fetch(request))
    }

    static func sound(from data: Data) throws -> URL {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (object["ret"] as? NSNumber)?.intValue == 0,
              let info = object["trackInfo"] as? [String: Any] else {
            throw TVError.unsupported(L10n.text("Ximalaya didn't give this chapter's audio. Try again later."))
        }
        let addresses = (info["playUrlList"] as? [[String: Any]] ?? [])
            .sorted { (($0["qualityLevel"] as? NSNumber)?.intValue ?? 0) > (($1["qualityLevel"] as? NSNumber)?.intValue ?? 0) }
            .compactMap { ($0["url"] as? String).flatMap(decrypt) }
            .compactMap { URL(string: $0) }.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        guard info["isAuthorized"] as? Bool != false, let first = addresses.first else {
            throw TVError.unsupported(L10n.text("This chapter is paid on Ximalaya and can't be played here."))
        }
        return first
    }

    /// A track address as the web player receives it: URL-safe Base64 of AES-128-ECB with PKCS7 padding.
    static func decrypt(_ text: String) -> String? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let input = Data(base64Encoded: base64), !input.isEmpty, input.count % kCCBlockSizeAES128 == 0 else { return nil }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { bytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        key, key.count, nil, bytes.baseAddress, input.count, out.baseAddress, out.count, &moved)
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: output.prefix(moved), encoding: .utf8)
    }
}
