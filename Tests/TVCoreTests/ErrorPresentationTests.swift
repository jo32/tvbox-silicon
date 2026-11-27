import Foundation
import Testing
@testable import TVCore

struct ErrorPresentationTests {
    @Test func promotesSpecificSingleLineReasonOntoTheCard() {
        let shown = ErrorPresentation.summarize("The source example.com returned HTTP 403.", fallback: "Try again.")
        #expect(shown.message == "The source example.com returned HTTP 403.")
        #expect(shown.details.isEmpty)
    }

    @Test func fallsBackWhenReasonIsMissingOrBlank() {
        #expect(ErrorPresentation.summarize(nil, fallback: "Try again.") == ErrorPresentation(message: "Try again.", details: ""))
        #expect(ErrorPresentation.summarize("  \n\t ", fallback: "Try again.") == ErrorPresentation(message: "Try again.", details: ""))
    }

    @Test func keepsFirstLineUpFrontAndFullTraceInDetails() {
        let trace = "Plugin error: NullPointerException\n\tat spider.Detail(Unknown Source)\n\tat host.Main.run(Main.java:10)"
        let shown = ErrorPresentation.summarize(trace, fallback: "Try again.")
        #expect(shown.message == "Plugin error: NullPointerException")
        #expect(shown.details == trace)
    }

    @Test func truncatesOverlongSingleLineAndKeepsFullTextInDetails() {
        let long = String(repeating: "a", count: ErrorPresentation.summaryLimit + 20)
        let shown = ErrorPresentation.summarize(long, fallback: "Try again.")
        #expect(shown.message.count == ErrorPresentation.summaryLimit)
        #expect(shown.message.hasSuffix("…"))
        #expect(shown.details == long)
    }

    @Test func localizesNetworkAndDecodingErrorsInAllSupportedLanguages() {
        let cases: [(Error, String)] = [
            (URLError(.notConnectedToInternet), "No internet connection. Check your network and try again."),
            (URLError(.timedOut), "The server took too long to respond. Try again, or choose another source."),
            (URLError(.cannotFindHost), "The server couldn't be found. The source may be offline."),
            (URLError(.cannotConnectToHost), "Couldn't connect to the server. It may be down or unreachable."),
            (URLError(.networkConnectionLost), "The connection was interrupted. Try again."),
            (URLError(.serverCertificateUntrusted), "Couldn't establish a secure connection to the server."),
            (DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad json")), "The source returned data Yingxia couldn't read."),
        ]
        for (error, english) in cases {
            #expect(ErrorPresentation.reason(for: error, language: "en") == english)
            for language in ["zh-Hans", "zh-Hant", "ja"] {
                let localized = ErrorPresentation.reason(for: error, language: language)
                #expect(!localized.isEmpty)
                #expect(localized != english)
            }
        }
        // Specific TVError messages stay untouched.
        #expect(ErrorPresentation.reason(for: TVError.http(502), language: "en") == "The server returned HTTP 502.")
        // Underlying URL errors (such as a failed fallback line resolve) are localized instead of leaking raw English.
        let wrapped = NSError(domain: "CatalogError", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "The request timed out.",
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
        ])
        #expect(ErrorPresentation.reason(for: wrapped, language: "zh-Hans") == "服务器响应超时，请重试或换一个来源。")
    }
}
