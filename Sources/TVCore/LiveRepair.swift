import Foundation
import AVFoundation

/// Live HLS whose source asks for repair (`repair: "discontinuity"` in the play result; Yingxia's Douyu
/// script does), read through a resource loader. When a room is new to Douyu's edge server, the
/// edge starts it at MEDIA-SEQUENCE 0 and marks that first segment as a discontinuity in some reloads
/// of the playlist but not in others. AVPlayer stops on the contradiction a few seconds in (CoreMedia
/// -12312, "Media Entry discontinuity value does not match previous playlist"); a second try plays
/// because the edge has moved past segment 0 by then. Nothing comes before a stream's first segment,
/// so a discontinuity there means nothing and the loader drops it. Only the playlists pass through
/// here: their segment addresses are made absolute and load from the CDN directly.
public enum LiveRepair {
    public static let scheme = "tvbox-live-repair"
    /// The same loader for a video's playlist whose ad segments are cut (`AdSkip`).
    public static let adScheme = "tvbox-ad-skip"
    nonisolated(unsafe) private static var hostHeaders: [String: [String: String]] = [:]
    private static let lock = NSLock()

    /// The address AVPlayer opens for one of these playlists; the server's playlists are asked for with `headers`.
    static func address(_ url: URL, headers: [String: String]? = nil, skipsAds: Bool = false) -> URL {
        if let headers, let host = url.host()?.lowercased() { lock.withLock { hostHeaders[host] = headers } }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = skipsAds ? adScheme : scheme
        return components?.url ?? url
    }

    /// The headers the playlist's server was asked with.
    static func headers(for url: URL) -> [String: String] {
        lock.withLock { hostHeaders[url.host()?.lowercased() ?? ""] ?? [:] }
    }

    /// The playlist on the server behind an address from `address`.
    static func upstream(_ url: URL) -> URL? {
        guard url.scheme == scheme || url.scheme == adScheme, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// The source behind the repair route, for a playback-owned HTTP adapter.
    public static func sourceURL(for url: URL) -> URL? { upstream(url) }

    public static func repairedMediaPlaylist(_ text: String, identity: String?, rewriteLine: (String) -> String) -> String {
        var lines = text.components(separatedBy: .newlines)
        if text.contains("#EXT-X-STREAM-INF") { return lines.map(rewriteLine).joined(separator: "\n") }
        let first = sequenceStart(lines)
        lines = droppingInitialDiscontinuity(lines, first: first)
        guard let identity, !text.contains("#EXT-X-ENDLIST") else { return lines.map(rewriteLine).joined(separator: "\n") }
        return stableLines(lines, first: first, playlist: identity, rewriteLine: rewriteLine)
    }

    /// An asset for an address from `address`, or nil for any other address.
    public static func asset(for url: URL) -> AVURLAsset? {
        guard url.scheme == scheme || url.scheme == adScheme else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(RepairedPlaylistLoader.shared, queue: RepairedPlaylistLoader.shared.queue)
        return asset
    }

    nonisolated(unsafe) private static var segmentNames: [String: [Int: String]] = [:]
    private static let hostsKey = "liveRepairHosts"

    /// Remembers that the playlists of `url`'s server contradicted themselves between reloads, so that its
    /// streams open through the loader from now on (`contradicts`).
    public static func noteContradiction(_ url: URL?) {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased() else { return }
        var hosts = UserDefaults.standard.stringArray(forKey: hostsKey) ?? []
        guard !hosts.contains(host) else { return }
        hosts.append(host)
        UserDefaults.standard.set(Array(hosts.suffix(32)), forKey: hostsKey)
    }

    /// Whether a playlist of `url`'s server has contradicted itself before.
    static func contradicts(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        return UserDefaults.standard.stringArray(forKey: hostsKey)?.contains(host) ?? false
    }

    /// A live media playlist whose segments keep the address they first had. Some relays sign every segment
    /// address anew in each reload of the playlist; AVPlayer takes a changed address for the same
    /// MEDIA-SEQUENCE as a contradiction and stops (-12312, "Media Entry URL not match previous playlist").
    /// `playlist` names the playlist across its reloads.
    static func steady(_ text: String, playlist: String) -> String {
        guard !text.contains("#EXT-X-STREAM-INF"), !text.contains("#EXT-X-ENDLIST") else { return text }
        let lines = text.components(separatedBy: "\n")
        return stableLines(lines, first: sequenceStart(lines), playlist: playlist) { $0 }
    }

    private static func sequenceStart(_ lines: [String]) -> Int {
        let sequenceTag = "#EXT-X-MEDIA-SEQUENCE:"
        return lines.first { $0.hasPrefix(sequenceTag) }.flatMap { Int($0.dropFirst(sequenceTag.count).trimmingCharacters(in: .whitespaces)) } ?? 0
    }

    private static func droppingInitialDiscontinuity(_ lines: [String], first: Int) -> [String] {
        guard first == 0 else { return lines }
        let boundary = lines.firstIndex { $0.hasPrefix("#EXTINF") } ?? lines.endIndex
        return lines[..<boundary].filter { $0.trimmingCharacters(in: .whitespaces) != "#EXT-X-DISCONTINUITY" } + lines[boundary...]
    }

    private static func stableLines(_ input: [String], first: Int, playlist: String, rewriteLine: (String) -> String) -> String {
        var lines = input
        for index in lines.indices where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            lines[index] = rewriteLine(lines[index])
        }
        return lock.withLock {
            if segmentNames[playlist] == nil, segmentNames.count >= 16 { segmentNames.removeAll() }
            var names = segmentNames[playlist] ?? [:]
            // A stream that started over counts from a low number again: its old addresses are another stream's.
            if let lowest = names.keys.min(), first < lowest { names.removeAll() }
            names = names.filter { $0.key >= first }
            var number = first
            for index in lines.indices {
                let value = lines[index].trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, !value.hasPrefix("#") else { continue }
                if let known = names[number] { lines[index] = known } else {
                    lines[index] = rewriteLine(value)
                    names[number] = lines[index]
                }
                number += 1
            }
            segmentNames[playlist] = names
            return lines.joined(separator: "\n")
        }
    }

    /// A playlist with absolute addresses (other playlists back through this scheme, segments and keys
    /// to the CDN) and without a discontinuity before the stream's first segment.
    static func rewrite(_ text: String, origin: URL, skipsAds: Bool = false) -> String {
        let master = text.contains("#EXT-X-STREAM-INF")
        var text = text
        if skipsAds, !master, let cleaned = AdSkip.clean(text, origin: origin) {
            Diagnostics.shared.record(.info, "player", "ads removed runs=\(cleaned.runs) seconds=\(Int(cleaned.seconds)) host=\(cleaned.host)")
            text = cleaned.text
        }
        func resolve(_ value: String) -> String {
            guard let url = URL(string: value, relativeTo: origin)?.absoluteURL else { return value }
            return (master ? address(url, skipsAds: skipsAds) : url).absoluteString
        }
        let lines = text.components(separatedBy: .newlines)
        return droppingInitialDiscontinuity(lines, first: sequenceStart(lines)).map { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return line }
            if !value.hasPrefix("#") { return resolve(value) }
            guard let match = line.firstMatch(of: /URI="([^"]+)"/) else { return line }
            return line.replacingCharacters(in: match.1.startIndex..<match.1.endIndex, with: resolve(String(match.1)))
        }.joined(separator: "\n")
    }
}

/// Answers AVPlayer's requests for `tvbox-live-repair://` playlists from the server. Requests stay on
/// one serial queue; the download re-enters it to respond, so a cancelled request gets nothing late.
private final class RepairedPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = RepairedPlaylistLoader()
    let queue = DispatchQueue(label: "tvbox.live.playlists")
    private var pending: [ObjectIdentifier: (request: AVAssetResourceLoadingRequest, task: Task<Void, Never>)] = [:]

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, let upstream = LiveRepair.upstream(url) else { return false }
        let id = ObjectIdentifier(request)
        let task = Task { [weak self] in
            let result: Result<Data, Error>
            do {
                var fetch = URLRequest(url: upstream, timeoutInterval: 15)
                LiveRepair.headers(for: upstream).forEach { fetch.setValue($1, forHTTPHeaderField: $0) }
                let (data, response) = try await URLSession.shared.data(for: fetch)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { throw TVError.http(status) }
                let playlist = LiveRepair.rewrite(String(decoding: data, as: UTF8.self), origin: response.url ?? upstream, skipsAds: url.scheme == LiveRepair.adScheme)
                result = .success(Data((url.scheme == LiveRepair.scheme ? LiveRepair.steady(playlist, playlist: url.absoluteString) : playlist).utf8))
            } catch {
                if !(error is CancellationError) { Diagnostics.shared.record(.warning, "live", "repaired playlist host=\(upstream.host() ?? "-") \(error.localizedDescription)") }
                result = .failure(error)
            }
            self?.queue.async { [weak self] in
                guard let self, let request = self.pending.removeValue(forKey: id)?.request, !request.isCancelled else { return }
                switch result {
                case .success(let data): request.dataRequest?.respond(with: data); request.finishLoading()
                case .failure(let error): request.finishLoading(with: error)
                }
            }
        }
        pending[id] = (request, task)
        return true
    }
    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        pending.removeValue(forKey: ObjectIdentifier(request))?.task.cancel()
    }
}
