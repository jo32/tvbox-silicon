import Foundation

/// Turns a failure into a clear, localized reason shown directly on an error card (`message`), keeping
/// multi-line or lengthy technical text behind "Show details" (`details`) instead of hiding a specific
/// one-line reason behind a generic prompt (#1675).
public struct ErrorPresentation: Equatable, Sendable {
    public let message: String
    public let details: String

    public init(message: String, details: String = "") {
        self.message = message
        self.details = details
    }

    static let summaryLimit = 220

    /// Promotes a concise specific reason onto the card; keeps multi-line or oversized dumps in `details`.
    public static func summarize(_ raw: String?, fallback: String) -> ErrorPresentation {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return ErrorPresentation(message: fallback, details: "") }
        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return ErrorPresentation(message: fallback, details: "") }
        if lines.count == 1, first.count <= summaryLimit {
            return ErrorPresentation(message: first, details: "")
        }
        let summary = first.count > summaryLimit ? String(first.prefix(summaryLimit - 1)) + "…" : first
        return ErrorPresentation(message: summary, details: trimmed)
    }

    /// A localized reason for `error`, preserving Yingxia's own specific messages (`TVError`, `PluginFailure`)
    /// and translating raw URL/decoding failures into the app's selected language.
    public static func reason(for error: Error, language: String? = nil) -> String {
        if let tv = error as? TVError, let text = tv.errorDescription, !text.isEmpty { return text }
        if error is DecodingError {
            return L10n.text("The source returned data Yingxia couldn't read.", language: language)
        }
        if let network = urlReason(for: error, language: language) { return network }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [3840, 4864, 4865].contains(ns.code) {
            return L10n.text("The source returned data Yingxia couldn't read.", language: language)
        }
        return error.localizedDescription
    }

    static func urlReason(for error: Error, language: String? = nil) -> String? {
        var current = error as NSError?
        while let currentError = current {
            if currentError.domain == NSURLErrorDomain {
                switch currentError.code {
                case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed:
                    return L10n.text("No internet connection. Check your network and try again.", language: language)
                case NSURLErrorTimedOut:
                    return L10n.text("The server took too long to respond. Try again, or choose another source.", language: language)
                case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                    return L10n.text("The server couldn't be found. The source may be offline.", language: language)
                case NSURLErrorCannotConnectToHost:
                    return L10n.text("Couldn't connect to the server. It may be down or unreachable.", language: language)
                case NSURLErrorNetworkConnectionLost:
                    return L10n.text("The connection was interrupted. Try again.", language: language)
                case -1206 ... -1200:
                    return L10n.text("Couldn't establish a secure connection to the server.", language: language)
                default: break
                }
            } else if currentError.domain == "kCFErrorDomainCFNetwork", (-1206 ... -1200).contains(currentError.code) {
                return L10n.text("Couldn't establish a secure connection to the server.", language: language)
            }
            current = currentError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }
}
