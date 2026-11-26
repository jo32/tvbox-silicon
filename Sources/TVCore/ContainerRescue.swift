import Foundation
import os

/// What a file is, from its first bytes. AVFoundation goes by a link's name and the server's Content-Type alone: an MP4
/// served as `application/octet-stream` from an address without an extension (cloud drives' object storage, plugins'
/// proxies) fails with -11828 "Cannot Open", and an MKV, FLV, AVI or MPEG-PS behind a name or type that says MP4
/// with -11829 "damaged". Android players read the bytes instead; so does this.
public enum MediaSniff {
    public enum Kind: Sendable, Equatable {
        case mp4, quickTime, transportStream
        /// A song or other sound file, with its MIME type.
        case audio(String)
        case hlsPlaylist, dashManifest
        /// An HTML page (an episode's page on a video site that was never parsed), or a JSON answer.
        case webPage, json
        /// A container FFmpeg reads and AVPlayer doesn't: Matroska/WebM, AVI, FLV, ASF/WMV, RealMedia, MPEG-PS,
        /// MPEG-TS in 192-byte packets (M2TS), disc images.
        case repackage
        case image
        case unknown

        /// The MIME type that makes AVPlayer open it as it is (`MediaTypeHint`), if it can.
        public var mimeType: String? {
            switch self {
            case .mp4: "video/mp4"
            case .quickTime: "video/quicktime"
            case .transportStream: "video/mp2t"
            case .audio(let type): type
            case .hlsPlaylist: "application/vnd.apple.mpegurl"
            default: nil
            }
        }

        /// A short name for reports.
        public var label: String {
            switch self {
            case .mp4: "mp4"
            case .quickTime: "mov"
            case .transportStream: "ts"
            case .audio(let type): type
            case .hlsPlaylist: "m3u8"
            case .dashManifest: "mpd"
            case .webPage: "html"
            case .json: "json"
            case .repackage: "ffmpeg"
            case .image: "image"
            case .unknown: "unknown"
            }
        }
    }

    public static func kind(_ head: Data) -> Kind {
        let bytes = [UInt8](head.prefix(1024))
        guard bytes.count >= 4 else { return .unknown }
        func text(_ range: Range<Int>) -> String { range.upperBound <= bytes.count ? String(decoding: bytes[range], as: UTF8.self) : "" }
        if bytes.count >= 12 {
            let box = text(4..<8)
            if box == "ftyp" { return text(8..<12) == "qt  " ? .quickTime : .mp4 }
            if ["moov", "mdat", "free", "skip", "wide", "pnot"].contains(box), bytes[0..<4].reduce(0, { $0 << 8 | Int($1) }) >= 8 { return .mp4 }
        }
        if bytes[0] == 0x47, bytes.count > 188, bytes[188] == 0x47, bytes.count <= 376 || bytes[376] == 0x47 { return .transportStream }
        if bytes.count > 196, bytes[4] == 0x47, bytes[196] == 0x47 { return .repackage }
        if Remux.handles(Data(bytes)) { return .repackage }
        if text(0..<4) == "fLaC" { return .audio("audio/flac") }
        if text(0..<3) == "ID3" { return .audio("audio/mpeg") }
        if bytes.count >= 12, text(0..<4) == "RIFF", text(8..<12) == "WAVE" { return .audio("audio/wav") }
        if bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return .audio("audio/aac") }
        if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 { return .audio("audio/mpeg") }
        if bytes[0..<4].elementsEqual([0x89, 0x50, 0x4E, 0x47]) || bytes[0..<3].elementsEqual([0xFF, 0xD8, 0xFF])
            || text(0..<4) == "GIF8" || text(0..<2) == "BM" || bytes.count >= 12 && text(0..<4) == "RIFF" && text(8..<12) == "WEBP" { return .image }
        // Text: skip a byte-order mark and white space.
        var start = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
        while start < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[start]) { start += 1 }
        let lead = String(decoding: bytes[start...], as: UTF8.self).lowercased()
        if lead.hasPrefix("#extm3u") { return .hlsPlaylist }
        if lead.hasPrefix("<"), DashManifest.names(Data(bytes)) { return .dashManifest }
        if ["<!doctype html", "<html", "<head", "<body", "<script", "<meta", "<title", "<div", "<!--"].contains(where: lead.hasPrefix) { return .webPage }
        if lead.hasPrefix("{") || lead.hasPrefix("[") { return .json }
        return .unknown
    }
}

/// The container AVPlayer is told an address holds (`AVURLAssetOverrideMIMETypeKey`), once its bytes said so
/// (`ContainerRescue`). The player reads it when it makes the item.
public enum MediaTypeHint {
    private static let hints = OSAllocatedUnfairLock<[URL: String]>(initialState: [:])

    public static func set(_ mimeType: String, for url: URL) {
        hints.withLock {
            if $0.count > 32 { $0.removeAll() }
            $0[url] = mimeType
        }
    }
    public static func mimeType(for url: URL) -> String? { hints.withLock { $0[url] } }
}

/// A link AVPlayer refused to open (-11828 "Cannot Open", -11829 "damaged": 566 and 226 installs in a week) played
/// anyway: its first bytes say what it is (`MediaSniff`), and it plays the way that suits it. AVPlayer is told the
/// container when it can play it; a DASH manifest plays as HLS; anything else FFmpeg reads is repackaged; a forward-only
/// FLV stream plays live. A web page is no video at all, and says so.
public enum ContainerRescue {
    public enum Plan: Sendable {
        /// Open the address again, telling AVPlayer this MIME type.
        case mimeType(String)
        /// The DASH manifest's representations as a local HLS master playlist.
        case dash(URL)
        /// Repackage these bytes (`Remux.open`).
        case repackage(RemuxSource)
        /// A live stream's local HLS playlist (`FLVLive`).
        case live(URL)
        /// An HTML page: the source handed out a video site's page, not its video.
        case webPage
        /// Nothing more to try; why, for the report.
        case nothing(String)
    }

    /// AVFoundation's "Cannot Open" (-11828, Core Media -12847) and "damaged" (-11829, -12848): what it says when it
    /// can't tell, or can't read, the container.
    public static func refusedContainer(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let error = current {
            if error.domain == "AVFoundationErrorDomain", [-11828, -11829].contains(error.code) { return true }
            if [NSOSStatusErrorDomain, "CoreMediaErrorDomain"].contains(error.domain), [-12847, -12848].contains(error.code) { return true }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// The first wait before a passing failure is tried again; tests shorten it.
    nonisolated(unsafe) static var retryBase = 0.5

    /// Whether an address can be read again here: an HTTP(S) link, or a cloud drive's stream.
    public static func handles(_ url: URL) -> Bool {
        ["http", "https", CloudStreams.scheme].contains(url.scheme?.lowercased() ?? "") && !Remux.isRemuxed(url)
    }

    /// How to play `url` now that AVPlayer refused it. `hinted`: AVPlayer was already told the container and still
    /// refused, so FFmpeg reads it this time. `renewal` gives a fresh link to the same file once this one expires.
    public static func plan(for url: URL, headers: [String: String], hinted: Bool,
                            renewal: (@Sendable () async -> CloudStreams.Source?)? = nil) async -> Plan {
        await plan(for: url, headers: headers, hinted: hinted, renewal: renewal, session: CloudByteStream.session)
    }

    static func plan(for url: URL, headers: [String: String], hinted: Bool, renewal: (@Sendable () async -> CloudStreams.Source?)?,
                     session: URLSession) async -> Plan {
        if url.scheme == CloudStreams.scheme {
            // The drive's file reached AVPlayer through the app's loader, which told it the container: FFmpeg's turn.
            guard let source = await CloudStreams.remuxSource(for: url) else { return .nothing("stream closed") }
            return .repackage(source)
        }
        // A gateway's passing 502 or a dropped connection is asked again a little later, three times at most.
        var head = Head(), backoff = Backoff(base: retryBase, ceiling: 2, attempts: 3)
        while true {
            do {
                head = try await Head.fetch(url, headers: headers, session: session)
                if TransientRetry.transientStatuses.contains(head.status), let wait = backoff.next() {
                    try await Task.sleep(for: .seconds(wait)); continue
                }
                break
            } catch {
                if TransientRetry.isTransient(error), let wait = backoff.next(), (try? await Task.sleep(for: .seconds(wait))) != nil { continue }
                return .nothing("head \(Diagnostics.describe(error))")
            }
        }
        guard (200..<300).contains(head.status) else { return .nothing("status=\(head.status)") }
        let kind = MediaSniff.kind(head.bytes)
        Diagnostics.shared.record(.info, "player", "unopened link sniffed kind=\(kind.label) host=\(url.host() ?? "-") type=\(head.contentType ?? "-") ranges=\(head.ranged) hinted=\(hinted)")
        switch kind {
        case .webPage, .json: return .webPage
        case .image: return .nothing("image")
        case .dashManifest:
            do {
                let document = head.complete ? head.bytes : try await Head.whole(url, headers: headers, session: session)
                guard let dash = DashManifest.dash(document, url: url) else { return .nothing("mpd without SegmentBase") }
                guard let master = try await DashStreams.stream(dash, headers: headers, danmaku: nil, session: session) else { return .nothing("mpd without video") }
                return .dash(master)
            } catch { return .nothing("mpd \(Diagnostics.describe(error))") }
        case .hlsPlaylist:
            return hinted ? .nothing("m3u8 refused") : .mimeType(kind.mimeType!)
        case .mp4, .quickTime, .transportStream, .audio:
            if !hinted, let type = kind.mimeType { return .mimeType(type) }
            return await repackaged(url, headers: headers, head: head, renewal: renewal)
        case .repackage, .unknown:
            return await repackaged(url, headers: headers, head: head, renewal: renewal)
        }
    }

    /// The local HLS master for a link that names a DASH manifest (`.mpd`), which AVPlayer would refuse; nil when it
    /// isn't one this reads (`DashManifest`).
    public static func dashManifest(_ url: URL, headers: [String: String]) async -> URL? {
        guard let data = try? await Head.whole(url, headers: headers, session: CloudByteStream.session), DashManifest.names(data),
              let dash = DashManifest.dash(data, url: url) else { return nil }
        do { return try await DashStreams.stream(dash, headers: headers, danmaku: nil, session: CloudByteStream.session) }
        catch {
            Diagnostics.shared.failure("player", "mpd host=\(url.host() ?? "-")", error)
            return nil
        }
    }

    /// FFmpeg reads the file through byte ranges; a stream that answers none plays live when it is FLV.
    private static func repackaged(_ url: URL, headers: [String: String], head: Head, renewal: (@Sendable () async -> CloudStreams.Source?)?) async -> Plan {
        do { return .repackage(try await Remux.httpSource(url, headers: headers, renewal: renewal)) }
        catch is Remux.NoByteRanges {
            guard head.bytes.starts(with: Data("FLV".utf8)) else { return .nothing("no byte ranges") }
            do { return .live(try await FLVLive.open(url, headers: headers)) }
            catch { return .nothing("flv live \(Diagnostics.describe(error))") }
        } catch { return .nothing("remux \(Diagnostics.describe(error))") }
    }

    /// A link's first bytes (up to 64 KB), from a range request a server may answer whole.
    struct Head {
        static let limit = 64 << 10
        var status = 0
        var bytes = Data()
        var contentType: String?
        /// Whether the server answered the range (206).
        var ranged = false
        /// Whether `bytes` is the whole document.
        var complete = false

        static func fetch(_ url: URL, headers: [String: String], session: URLSession) async throws -> Head {
            var request = URLRequest(url: url, timeoutInterval: 20)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (stream, response) = try await session.bytes(for: request)
            var head = Head()
            let http = response as? HTTPURLResponse
            head.status = http?.statusCode ?? 0
            head.contentType = http?.value(forHTTPHeaderField: "Content-Type")
            head.ranged = head.status == 206
            head.bytes.reserveCapacity(limit)
            var ended = true
            for try await byte in stream {
                head.bytes.append(byte)
                if head.bytes.count >= limit { ended = false; break }
            }
            stream.task.cancel()
            let total = http?.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/").last.flatMap { Int($0) }
            head.complete = ended && (total.map { $0 <= head.bytes.count } ?? true)
            return head
        }

        /// The whole document (a manifest larger than the head), at most 4 MB.
        static func whole(_ url: URL, headers: [String: String], session: URLSession) async throws -> Data {
            var request = URLRequest(url: url, timeoutInterval: 20)
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw TVError.http(status) }
            return data.prefix(4 << 20)
        }
    }
}
