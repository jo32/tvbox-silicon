import Foundation

/// One play on its way to the first frame, counted for the play success rate in error reports (`player.stats`,
/// read with `Scripts/error-reports.py --stats`). Each play ends one way: it `started` (the picture moved), it
/// `failed` before that (the error screen), or it was `abandoned` (closed or replaced while still loading).
/// A play that started after a retry rung (another line, a repackaging, a reconnection) also counts as
/// `recovered rung=<rung>`, the last rung tried.
///
/// Only coarse fields go out, as counts summed on the device: whether it is live, how the stream reaches the
/// player (`direct`, `local-proxy`, `file`, or the app's own scheme), and a known container format. Never an
/// address, host, title, source or search. The app build and platform travel once with each upload.
public struct PlayAttempt: Sendable {
    public enum Outcome: String, Sendable { case started, failed, abandoned }

    public let live: Bool
    public let format: String
    /// The last retry rung tried before the outcome.
    public private(set) var rung: String?
    public private(set) var outcome: Outcome?
    private let reports: ErrorReports

    /// `address`: the episode's or channel's own address, for its format only.
    public init(live: Bool, address: URL, reports: ErrorReports = .shared) {
        self.live = live
        self.format = Self.format(address)
        self.reports = reports
    }

    /// A retry rung is trying to save this play (`"line"`, `"repackage"`, ...): a short constant, never data.
    public mutating func retrying(_ rung: String) {
        guard outcome == nil else { return }
        let name = String(rung.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(16))
        self.rung = name.isEmpty ? "other" : name
    }

    /// Counts the play once, the first time it ends; `playing` is the address the player was given, if any.
    public mutating func resolve(_ outcome: Outcome, playing url: URL?) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        for message in messages(outcome, via: Self.via(url)) { reports.count(message) }
    }

    func messages(_ outcome: Outcome, via: String) -> [String] {
        let fields = "live=\(live ? 1 : 0) via=\(via) format=\(format)"
        var messages = ["attempt \(fields)", "\(outcome.rawValue) \(fields)"]
        if outcome == .started, let rung { messages.append("recovered rung=\(rung) \(fields)") }
        return messages
    }

    /// How the stream reaches the player: `none` before it got an address.
    static func via(_ url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased() else { return "none" }
        switch scheme {
        case "http", "https":
            let host = url.host()?.lowercased() ?? ""
            return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) ? "local-proxy" : "direct"
        case "file": return "file"
        default:
            // The app's own resource-loader schemes (drives, downloads); anything else is one bucket.
            return scheme.count <= 16 && scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) ? scheme : "other"
        }
    }

    static let formats: Set<String> = ["m3u8", "mp4", "mkv", "flv", "ts", "mpd", "m4v", "mov", "webm", "avi", "wmv", "rmvb", "mp3", "m4a", "flac"]

    /// A known container format from the address, `none` without an extension, `other` for the rest.
    static func format(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return "none" }
        if ext == "m3u" { return "m3u8" }
        return formats.contains(ext) ? ext : "other"
    }
}
