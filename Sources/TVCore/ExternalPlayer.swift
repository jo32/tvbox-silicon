import Foundation

/// Hands a stream's address to another app, for the formats the built-in player cannot decode.
///
/// This is the answer to one specific failure: a source may return something AVFoundation will not
/// open — an unusual container, a codec it does not carry, a manifest it cannot parse. The video
/// itself is fine; only this app's player is not. 映匣 already says as much ("the video arrived, but
/// the built-in player cannot open this format"); until now that message was the end of the road.
///
/// So this type does not try to decode more formats. It offers the address to a player that might.
///
/// **Only the players whose format could be verified are listed.** The address format for each one
/// here comes from that vendor's own documentation or from its shipping code, and the source is
/// noted on the entry. A menu row that opens nothing teaches the viewer to distrust the whole menu,
/// so a player nobody could verify is left out rather than guessed at.
///
/// Two implementations were removed for exactly that reason, and the mistake is worth recording:
/// `vlc://<url>` looks obvious but VideoLAN's own developer says the pseudo-protocol is broken and
/// recommends the x-callback form instead; and Fileball publishes no URL scheme at all — it is a
/// *caller* of other players, not a callee.
///
/// Framework-light on purpose: it takes a URL and describes candidates. Whether to show the menu is
/// the caller's decision.
public struct ExternalPlayer: Identifiable, Sendable {

    /// The app, as a person would name it.
    public let name: String
    /// The scheme it registers, for probing with `canOpenURL`.
    public let scheme: String
    /// Builds the address this app opens, given the stream.
    public let make: @Sendable (URL) -> URL?
    /// Where the format was confirmed, so the next person can re-check it.
    public let source: String

    public var id: String { scheme }

    /// The players worth offering, most commonly installed first.
    public static let known: [ExternalPlayer] = [
        // https://support.firecore.com/hc/en-us/articles/215090997
        // `infuse://x-callback-url/play?url=…` — the article's own examples percent-encode the
        // nested URL, and warns that unencoded URLs fail once several parameters are present.
        ExternalPlayer(name: "Infuse", scheme: "infuse", source: "Firecore support · API for Third-Party Apps") { url in
            guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            return URL(string: "infuse://x-callback-url/play?url=" + encoded)
        },

        // https://wiki.videolan.org/Documentation:IOS/#x-callback-url and the vlc-devel patch that
        // introduced it: `vlc-x-callback://x-callback-url/stream?url=…`. Not `vlc://` — VideoLAN's
        // Felix Kühne calls that pseudo-protocol broken and points at this one instead.
        ExternalPlayer(name: "VLC", scheme: "vlc-x-callback", source: "VideoLAN wiki · Documentation:iOS · x-callback-url") { url in
            guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            return URL(string: "vlc-x-callback://x-callback-url/stream?url=" + encoded)
        },

        // Scheme list extracted from nPlayer's own Info.plist (clien.net 17502186) and the deeplink
        // list at blog.paulcoding.com: the scheme carries the protocol, as in `nplayer-https://…`.
        ExternalPlayer(name: "nPlayer", scheme: "nplayer-http", source: "nPlayer Info.plist · https://blog.paulcoding.com/posts/player-deeplinks") { url in
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = parts.scheme?.lowercased(),
                  ["http", "https", "ftp", "sftp", "smb"].contains(scheme) else { return nil }
            parts.scheme = "nplayer-" + scheme
            return parts.url
        },

        // `senplayer://x-callback-url/play?` — from the OpenList feature request that asked for this
        // exact integration (issue #2272) and from SenPlayer's own release notes, which describe
        // URLScheme playback taking a start time and returning the stop time.
        ExternalPlayer(name: "SenPlayer", scheme: "senplayer", source: "OpenList #2272 · SenPlayer 6.1.2 release notes") { url in
            guard let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            return URL(string: "senplayer://x-callback-url/play?url=" + encoded)
        },
    ]

    public init(name: String, scheme: String, source: String,
                make: @escaping @Sendable (URL) -> URL?) {
        self.name = name
        self.scheme = scheme
        self.source = source
        self.make = make
    }

    /// The address to open, or nil when this player cannot express it.
    public func address(for stream: URL) -> URL? { make(stream) }
}

#if canImport(UIKit)
import UIKit

extension ExternalPlayer {
    /// The players actually installed, in `known` order.
    ///
    /// `canOpenURL` is the only honest check: a scheme either has a handler or it does not, and it
    /// must run on the main actor because UIKit answers it there. It only answers for schemes listed
    /// in `LSApplicationQueriesSchemes` — without that, an installed app looks exactly like a
    /// missing one.
    @MainActor
    public static func installed() -> [ExternalPlayer] {
        known.filter { URL(string: $0.scheme + "://").map { UIApplication.shared.canOpenURL($0) } ?? false }
    }

    /// Opens `stream` in this player. Returns false when the player is not there or refused it.
    @MainActor
    @discardableResult
    public func open(_ stream: URL) -> Bool {
        guard let address = address(for: stream), UIApplication.shared.canOpenURL(address) else { return false }
        UIApplication.shared.open(address)
        return true
    }
}
#endif
