import Foundation

/// A playback failure turned into a localized user-facing reason (`message`), an SF Symbol (`symbol`), and
/// optional technical details (`details`: host, HTTP status, domain/code chain, upstream error) for the
/// failure screen's expandable details view (#2560).
public struct PlaybackFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case expired, serverError, offline, network, localService, certificate, unsupportedFormat, webPage, other
    }

    public let kind: Kind
    public let message: String
    public let details: String?
    public let symbol: String

    /// Whether trying another line for the same episode can recover this failure.
    /// Offline errors affect every line, so fail immediately without cycling lines.
    public var allowsAutomaticLineSwitch: Bool { kind != .offline }

    /// Whether `url` is a loopback HTTP address whose connection was refused or dropped (e.g. a plugin's
    /// own local playback server after iOS background suspension, #1642).
    public static func isLoopbackRefusal(_ url: URL, errorCode: Int?) -> Bool {
        guard let errorCode, [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(errorCode),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), ["127.0.0.1", "localhost"].contains(host) else { return false }
        return true
    }

    public init(kind: Kind, message: String, details: String? = nil, symbol: String = "play.slash.fill") {
        self.kind = kind
        self.message = message
        self.details = details
        self.symbol = symbol
    }

    /// Walks an error's `NSUnderlyingErrorKey` chain into a concise diagnostic string (`Domain code → Domain code`).
    public static func codeChain(_ error: Error?) -> String? {
        var current = error as NSError?
        var parts: [String] = []
        var last: (String, Int)?
        var depth = 0
        while let currentError = current, depth < 8 {
            if last?.0 != currentError.domain || last?.1 != currentError.code {
                parts.append("\(currentError.domain) \(currentError.code)")
                last = (currentError.domain, currentError.code)
            }
            current = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return parts.isEmpty ? nil : parts.joined(separator: " → ")
    }

    /// Classifies an AVPlayer / stream failure into a localized message and technical details.
    public static func describe(_ error: Error?, httpStatus: Int? = nil, host: String? = nil, upstream: String? = nil,
                                isLoopback: Bool = false, refused: Bool = false, language: String? = nil) -> PlaybackFailure {
        let status = httpStatus.flatMap { (400..<600).contains($0) ? $0 : nil }
        let chain = errorChain(error)
        let urlCode = chain.first(where: { $0.domain == NSURLErrorDomain })?.code
        let cfCode = chain.first(where: { $0.domain == "kCFErrorDomainCFNetwork" })?.code
        let avCode = chain.first(where: { $0.domain == "AVFoundationErrorDomain" })?.code
        let cmCode = chain.first(where: { $0.domain == "CoreMediaErrorDomain" })?.code
        let details = technicalDetails(error: error, status: status, host: host, upstream: upstream)

        // 1. Offline: no line can play without internet.
        if let urlCode, [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed].contains(urlCode) {
            return PlaybackFailure(kind: .offline,
                                   message: L10n.text("No internet connection. Check your network and try again.", language: language),
                                   details: details, symbol: "wifi.slash")
        }

        // 2. Expired or refused link (HTTP 401/403/404/410, CoreMedia -12660/-12938, NSURL -1100/-1102/-1013).
        let refusedCode = (urlCode.map { [NSURLErrorNoPermissionsToReadFile, NSURLErrorFileDoesNotExist, NSURLErrorUserAuthenticationRequired].contains($0) } ?? false)
            || (cmCode.map { [-12660, -12938].contains($0) } ?? false)
        if refused || refusedCode || [401, 403, 404, 410].contains(status ?? 0) {
            return PlaybackFailure(kind: .expired,
                                   message: L10n.text("This episode's link may have expired. Open it again, or try another line.", language: language),
                                   details: details, symbol: "clock.badge.exclamationmark")
        }

        // 3. TLS / certificate errors (NSURL/CFNetwork -1200..-1206, HLSProxy HTTP 495).
        let tlsCode = (urlCode.map { (-1206 ... -1200).contains($0) } ?? false)
            || (cfCode.map { (-1206 ... -1200).contains($0) } ?? false)
            || status == 495
            || (cmCode == -16845 && chain.contains { $0.localizedDescription.contains("HTTP 495") })
        if tlsCode {
            return PlaybackFailure(kind: .certificate,
                                   message: L10n.text("Couldn't make a secure connection to the video server. Try another line.", language: language),
                                   details: details, symbol: "lock.slash")
        }

        // 4. Server HTTP 5xx error.
        if let status, (500..<600).contains(status) {
            return PlaybackFailure(kind: .serverError,
                                   message: L10n.text("The video server returned HTTP %lld. Try again later, or switch to another line.", status, language: language),
                                   details: details, symbol: "exclamationmark.icloud")
        }
        if case .http(let code)? = error as? TVError, (500..<600).contains(code) {
            return PlaybackFailure(kind: .serverError,
                                   message: L10n.text("The video server returned HTTP %lld. Try again later, or switch to another line.", code, language: language),
                                   details: details, symbol: "exclamationmark.icloud")
        }

        // 5. Local loopback playback service refused connection (e.g. plugin's own 127.0.0.1 server after suspension).
        if isLoopback, let urlCode, [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(urlCode) {
            return PlaybackFailure(kind: .localService,
                                   message: L10n.text("Couldn't connect to the source's local playback service. Try again, or switch to another line.", language: language),
                                   details: details, symbol: "wifi.exclamationmark")
        }

        // 6. Network timeouts, DNS, unreachable/dropped connections.
        if urlCode == NSURLErrorTimedOut || (cmCode.map { [-12889, -15628].contains($0) } ?? false) {
            return PlaybackFailure(kind: .network,
                                   message: L10n.text("The video server took too long to respond. Try again, or switch to another line.", language: language),
                                   details: details, symbol: "wifi.exclamationmark")
        }
        if let urlCode, [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed].contains(urlCode) {
            return PlaybackFailure(kind: .network,
                                   message: L10n.text("The video server couldn't be found. The source may be offline; try another line.", language: language),
                                   details: details, symbol: "wifi.exclamationmark")
        }
        if let urlCode, [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost].contains(urlCode) {
            return PlaybackFailure(kind: .network,
                                   message: L10n.text("Couldn't connect to the video server. Check your network, or try another line.", language: language),
                                   details: details, symbol: "wifi.exclamationmark")
        }

        // 7. Unsupported or unreadable media container/codec.
        let unsupportedAV = avCode.map { [-11828, -11829, -11838, -11839, -11848, -11850, -11868].contains($0) } ?? false
        let unsupportedCM = cmCode.map { [1718449215, -12927, -17223].contains($0) } ?? false
        if unsupportedAV || unsupportedCM {
            return PlaybackFailure(kind: .unsupportedFormat,
                                   message: L10n.text("This video format isn't supported on this device. Try another line.", language: language),
                                   details: details, symbol: "play.slash.fill")
        }

        // 8. Yingxia's own localized errors (e.g. TVError) keep their message.
        if let tv = error as? TVError, let text = tv.errorDescription, !text.isEmpty {
            return PlaybackFailure(kind: .other, message: text, details: details, symbol: "play.slash.fill")
        }

        return PlaybackFailure(kind: .other,
                               message: L10n.text("This media cannot be played. Try another channel or source.", language: language),
                               details: details, symbol: "play.slash.fill")
    }

    private static func errorChain(_ error: Error?) -> [NSError] {
        var result: [NSError] = []
        var current = error as NSError?
        var depth = 0
        while let currentError = current, depth < 8 {
            result.append(currentError)
            current = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return result
    }

    private static func technicalDetails(error: Error?, status: Int?, host: String?, upstream: String?) -> String? {
        var header: [String] = []
        if let host, !host.isEmpty, !["127.0.0.1", "localhost", "-"].contains(host) { header.append(host) }
        if let status { header.append("HTTP \(status)") }
        if let chain = codeChain(error) { header.append(chain) }
        var lines: [String] = []
        if !header.isEmpty { lines.append(header.joined(separator: " · ")) }
        if let upstream = upstream?.trimmingCharacters(in: .whitespacesAndNewlines), !upstream.isEmpty {
            if let status, upstream == "HTTP \(status)" {} else { lines.append(upstream) }
        }
        if let raw = error?.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
           !(error is TVError), !lines.contains(raw) {
            lines.append(raw)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Bounded automatic line switching for the same catalog episode when a line fails (#2560).
/// Tries at most `limit` alternate lines automatically per episode, remembers tried lines so it never
/// loops, and resets when the viewer moves to another episode or resets playback.
public struct PlaybackLineFallback: Sendable {
    public static let limit = 2

    private struct PendingSwitch: Equatable, Sendable {
        let videoScope: String
        let episodeID: String
        let flag: String
    }

    private var videoScope: String?
    private var episodeKey: String?
    private var pendingSwitch: PendingSwitch?
    public private(set) var triedFlags: Set<String> = []
    public private(set) var automaticSwitches = 0

    public init() {}

    public mutating func reset() {
        videoScope = nil
        episodeKey = nil
        pendingSwitch = nil
        triedFlags = []
        automaticSwitches = 0
    }

    /// Tracks that `context` is the active episode/line. Switching to a different video or episode resets the budget,
    /// except when landing on the target chosen by `nextAutomatic` (e.g. a single-episode film whose lines use
    /// different names such as "HD中字" and "正片").
    public mutating func track(_ context: PlaybackHistoryContext) {
        let key = Self.episodeKey(for: context)
        if let pending = pendingSwitch,
           pending.videoScope == context.id,
           pending.episodeID == context.episodeID,
           pending.flag == context.episodeFlag {
            pendingSwitch = nil
            episodeKey = key
            triedFlags.insert(context.episodeFlag)
            return
        }
        if videoScope != context.id || episodeKey != key {
            videoScope = context.id
            episodeKey = key
            pendingSwitch = nil
            triedFlags = [context.episodeFlag]
            automaticSwitches = 0
        } else {
            triedFlags.insert(context.episodeFlag)
        }
    }

    /// Picks the next safe untried line for automatic recovery, up to `limit` switches per episode.
    public mutating func nextAutomatic(for context: PlaybackHistoryContext, candidates: [Episode],
                                       allowed: (Episode) -> Bool = { _ in true }) -> Episode? {
        track(context)
        guard automaticSwitches < Self.limit else { pendingSwitch = nil; return nil }
        guard let next = candidates.first(where: { !triedFlags.contains($0.flag) && allowed($0) }) else {
            pendingSwitch = nil
            return nil
        }
        triedFlags.insert(next.flag)
        automaticSwitches += 1
        pendingSwitch = PendingSwitch(videoScope: context.id, episodeID: next.id, flag: next.flag)
        return next
    }

    /// Picks the next line for a viewer-initiated Switch Line button: prefers an untried line, else wraps to the first.
    public func nextManual(for context: PlaybackHistoryContext, candidates: [Episode]) -> Episode? {
        let key = Self.episodeKey(for: context)
        let tried = (videoScope == context.id && episodeKey == key) ? triedFlags : [context.episodeFlag]
        return candidates.first(where: { !tried.contains($0.flag) }) ?? candidates.first
    }

    static func episodeKey(for context: PlaybackHistoryContext) -> String {
        if let number = CatalogDanmakuMatcher.episodeNumber(context.episodeName) { return "#\(number)" }
        return context.episodeName
    }
}
