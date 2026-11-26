import Foundation

/// Links AVPlayer gives up on at once that other players play: this device reads them first and hands AVPlayer
/// something it opens.
///
/// - A server that ignores the byte range AVPlayer asks for first (CoreMedia -12939: the whole body, or a body with
///   no Content-Length, often behind a `.php` or extension-less address). What it really sends decides the way:
///   an HLS playlist plays through the loopback relay (`MediaRelay`) as HLS; a continuous MPEG-TS or FLV stream is
///   cut into live HLS (`TSLive`, `FLVLive`); an MKV and the like is repackaged (`Remux`); a file is served by the
///   relay with byte ranges, from a copy kept as it downloads when its server answers none.
/// - A server whose certificate AVPlayer refuses (NSURLErrorDomain -1200 to -1204: expired, self-signed, made out
///   to another host): the same ways, with the certificate of the link's own host accepted (and an older TLS on
///   it). Every other host, those its playlists name included, is checked as usual.
///
/// Each episode tries this once (`Attempt`), within `budget`; a link that still fails is reported as it was.
public enum PlaybackRescue {
    /// Why AVPlayer gave up on a link.
    public enum Trouble: String, Sendable {
        /// CoreMedia -12939: the server ignored the byte range AVPlayer asked for.
        case ignoredRange = "range"
        /// The server's certificate or TLS was refused.
        case insecure = "tls"
    }

    /// Whether an episode tried this already, and how it plays now.
    public struct Attempt: Sendable {
        public var tried = false
        /// An item of the episode became ready: a failure after that is no failure to open.
        public var ready = false
        /// The address AVPlayer opens instead, the way it was made (`Rescued.rung`), the link it stands for, why,
        /// and when the rescue began.
        public var address: URL?
        public var rung: String?
        public var origin: URL?
        public var trouble: Trouble?
        public var began: ContinuousClock.Instant?
        public init() {}
    }

    /// How long reading a link and opening what it sends may take, all of it.
    public static let budget: Duration = .seconds(20)

    /// What AVPlayer opens instead, and which way it was made (for the logs): `rescue-hls`, `rescue-ts`, `rescue-flv`, `rescue-remux`, `rescue-file`.
    public struct Rescued: Sendable {
        public let url: URL
        public let rung: String
    }

    /// The trouble behind a failure, through its underlying errors; nil for any other failure.
    public static func trouble(_ error: Error?) -> Trouble? {
        var current = error as NSError?
        while let error = current {
            if ["CoreMediaErrorDomain", NSOSStatusErrorDomain].contains(error.domain), error.code == -12939 { return .ignoredRange }
            if [NSURLErrorDomain, "kCFErrorDomainCFNetwork"].contains(error.domain), (-1204 ... -1200).contains(error.code) { return .insecure }
            // The HLS proxy answers 495 for a certificate the system refused (`HLSProxy.gatewayStatus`).
            if error.domain == "CoreMediaErrorDomain", error.code == -16845, error.localizedDescription.contains("HTTP 495") { return .insecure }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    /// What a link's first bytes are.
    public enum Body: String, Sendable, Equatable {
        case playlist, transportStream, flv
        /// A container the repackager opens and AVPlayer doesn't (`Remux.handles`).
        case container
        /// A file AVPlayer may open: MP4, QuickTime, MP3, AAC, or anything not recognised.
        case file
        /// A web page or an error message: nothing to play.
        case page
    }

    /// What `head`, a response's first bytes, is.
    public static func sniff(_ head: Data, contentType: String? = nil) -> Body {
        var bytes = [UInt8](head.prefix(4096))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let text = String(decoding: bytes.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") { return .playlist }
        if bytes.count >= 3, bytes[0] == 0x46, bytes[1] == 0x4C, bytes[2] == 0x56 { return .flv }
        if transportStream(bytes) { return .transportStream }
        if transportStream(bytes, packet: 192, sync: 4) { return .container } // M2TS: a Blu-ray file, repackaged
        if Remux.handles(Data(bytes)) { return .container }
        let lower = text.prefix(256).lowercased()
        if lower.hasPrefix("<!doctype") || lower.hasPrefix("<html") || lower.hasPrefix("<?xml") || lower.hasPrefix("{") || lower.hasPrefix("<head") {
            return .page
        }
        return .file
    }

    /// MPEG-TS packets: sync bytes 188 apart, at least three of them (or, for M2TS, 192 apart behind a 4-byte time).
    static func transportStream(_ bytes: [UInt8], packet: Int = 188, sync: Int? = nil) -> Bool {
        guard let first = sync ?? bytes.prefix(packet).firstIndex(of: 0x47) else { return false }
        let positions = Array(stride(from: first, to: bytes.count, by: packet))
        return positions.count >= 3 && positions.allSatisfy { bytes[$0] == 0x47 }
    }

    /// The file extension AVPlayer is given for a file whose first bytes are `head`.
    static func fileExtension(_ head: Data, original: String) -> String {
        let bytes = [UInt8](head.prefix(12))
        if bytes.count >= 8, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
            return bytes.count >= 12 && String(decoding: bytes[8..<12], as: UTF8.self) == "qt  " ? "mov" : "mp4"
        }
        if bytes.starts(with: Array("ID3".utf8)) || bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] & 0xF6 == 0xF2 { return "mp3" }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] & 0xF6 == 0xF0 { return "aac" }
        let known = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "flac"]
        return known.contains(original.lowercased()) ? original.lowercased() : "mp4"
    }

    /// Opens `url` the way its first bytes ask for, and returns what AVPlayer opens instead. Throws when the link
    /// answers with an error, sends a web page or an endless sound, can't be read either, or takes over `budget`.
    public static func open(_ url: URL, headers: [String: String], trouble: Trouble) async throws -> Rescued {
        try await withThrowingTaskGroup(of: Rescued?.self) { group in
            group.addTask { try await openNow(url, headers: headers, trouble: trouble) }
            group.addTask { try await Task.sleep(for: budget); return nil }
            defer { group.cancelAll() }
            if let rescued = try await group.next() ?? nil { return rescued }
            group.cancelAll()
            // What the cancelled try still opened is closed again.
            while let late = try? await group.next() { if let late { stop(late.url) } }
            throw TVError.unsupported("no answer within \(budget)")
        }
    }

    private static func openNow(_ url: URL, headers: [String: String], trouble: Trouble) async throws -> Rescued {
        let trusting = trouble == .insecure
        let session = RelaySession(origin: url, headers: headers, trusting: trusting)
        let head: Data, response: HTTPURLResponse
        do { (head, response) = try await session.probe(url) }
        catch { session.close(); throw error }
        let body = sniff(head, contentType: response.mimeType)
        Diagnostics.shared.record(.info, "rescue", "probe host=\(url.host() ?? "-") trouble=\(trouble.rawValue) status=\(response.statusCode) type=\(response.mimeType ?? "-") length=\(response.expectedContentLength) body=\(body.rawValue)")
        do {
            switch body {
            case .playlist:
                let address = try await MediaRelay.shared.add(session, entry: url, kind: .playlist, fileExtension: "m3u8")
                return remember(Rescued(url: address, rung: "rescue-hls"), Entry(session: session.id))
            case .transportStream:
                session.close()
                return remember(Rescued(url: try await TSLive.open(url, headers: headers, trusting: trusting), rung: "rescue-ts"), Entry())
            case .flv:
                session.close()
                return remember(Rescued(url: try await FLVLive.open(url, headers: headers, trusting: trusting), rung: "rescue-flv"), Entry())
            case .container:
                let address = try await MediaRelay.shared.add(session, entry: url, kind: .media, fileExtension: url.pathExtension.isEmpty ? "bin" : url.pathExtension)
                let source = try await Remux.httpSource(address, headers: [:])
                let remuxed = try await Remux.open(source, headers: headers)
                return remember(Rescued(url: remuxed, rung: "rescue-remux"), Entry(session: session.id, relay: address))
            case .file:
                let name = fileExtension(head, original: url.pathExtension)
                // Radio: AVPlayer can't take a sound with no end from a server that answers no range, nor can a copy.
                if response.expectedContentLength < 0, ["mp3", "aac"].contains(name) { throw TVError.unsupported("an endless sound") }
                let address = try await MediaRelay.shared.add(session, entry: url, kind: .media, fileExtension: name)
                return remember(Rescued(url: address, rung: "rescue-file"), Entry(session: session.id))
            case .page:
                throw TVError.unsupported("the link sends a web page")
            }
        } catch {
            MediaRelay.shared.remove(session.id)
            session.close()
            throw error
        }
    }

    /// Whether `url` is an address `open` returned that is still open.
    public static func owns(_ url: URL) -> Bool { lock.withLock { opened[url] != nil } }

    /// Closes what `open` opened for `url`; any other address is left alone.
    public static func stop(_ url: URL) {
        guard let entry = lock.withLock({ opened.removeValue(forKey: url) }) else { return }
        if let session = entry.session { MediaRelay.shared.remove(session) }
        Remux.stop(url)
    }

    /// The address of `url` once what serves it listens again (iOS takes back a suspended app's sockets); nil when
    /// it was closed. A repackaged stream relistens through `Remux.relisten`, after the relay it reads from, which
    /// has to come back on its own port, as the repackager keeps its address.
    public static func relisten(_ url: URL) async throws -> URL? {
        guard let entry = lock.withLock({ opened[url] }) else { return nil }
        let fresh: URL?
        if Remux.isRemuxed(url) {
            if let relay = entry.relay {
                guard try await MediaRelay.shared.relisten(relay) == relay else {
                    Diagnostics.shared.record(.warning, "rescue", "relay came back on another port; the repackaged stream ends")
                    return nil
                }
            }
            fresh = try await Remux.relisten(url)
        } else {
            fresh = try await MediaRelay.shared.relisten(url)
        }
        guard let fresh else { return nil }
        lock.withLock { if let entry = opened.removeValue(forKey: url) { opened[fresh] = entry } }
        return fresh
    }

    /// What is behind an address `open` returned: the relay session, and the relay address a repackager reads.
    struct Entry: Sendable {
        var session: String?
        var relay: URL?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var opened: [URL: Entry] = [:]

    private static func remember(_ rescued: Rescued, _ entry: Entry) -> Rescued {
        lock.withLock { opened[rescued.url] = entry }
        return rescued
    }
}
