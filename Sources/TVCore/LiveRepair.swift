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
    nonisolated(unsafe) private static var hostHeaders: [String: [String: String]] = [:]
    private static let lock = NSLock()

    /// The address AVPlayer opens for one of these playlists; the server's playlists are asked for with `headers`.
    static func address(_ url: URL, headers: [String: String]? = nil) -> URL {
        if let headers, let host = url.host()?.lowercased() { lock.withLock { hostHeaders[host] = headers } }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url ?? url
    }

    /// The headers the playlist's server was asked with.
    static func headers(for url: URL) -> [String: String] {
        lock.withLock { hostHeaders[url.host()?.lowercased() ?? ""] ?? [:] }
    }

    /// The playlist on the server behind an address from `address`.
    static func upstream(_ url: URL) -> URL? {
        guard url.scheme == scheme, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }

    /// An asset for an address from `address`, or nil for any other address.
    public static func asset(for url: URL) -> AVURLAsset? {
        guard url.scheme == scheme else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(RepairedPlaylistLoader.shared, queue: RepairedPlaylistLoader.shared.queue)
        return asset
    }

    /// A playlist with absolute addresses (other playlists back through this scheme, segments and keys
    /// to the CDN) and without a discontinuity before the stream's first segment.
    static func rewrite(_ text: String, origin: URL) -> String {
        let master = text.contains("#EXT-X-STREAM-INF")
        func resolve(_ value: String) -> String {
            guard let url = URL(string: value, relativeTo: origin)?.absoluteURL else { return value }
            return (master ? address(url) : url).absoluteString
        }
        let lines = text.components(separatedBy: .newlines)
        let firstSegment = lines.firstIndex { $0.hasPrefix("#EXTINF") } ?? lines.endIndex
        let sequenceTag = "#EXT-X-MEDIA-SEQUENCE:"
        let sequence = lines.first { $0.hasPrefix(sequenceTag) }.flatMap { Int($0.dropFirst(sequenceTag.count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return lines.indices.compactMap { index -> String? in
            let line = lines[index]
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { return line }
            if value == "#EXT-X-DISCONTINUITY", sequence == 0, index < firstSegment { return nil }
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
                result = .success(Data(LiveRepair.rewrite(String(decoding: data, as: UTF8.self), origin: response.url ?? upstream).utf8))
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
