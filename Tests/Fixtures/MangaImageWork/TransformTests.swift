import Foundation
import Testing
@testable import TVCore

@Test func transformedPageIsRejectedBeforeImageDecoding() async throws {
    let server = try await ImageBodyServer.start(count: 1)
    defer { server.stop() }
    let source = "fixture-transform-" + UUID().uuidString
    do {
        _ = try await MangaImages().data(source: source, url: server.url.absoluteString, kind: .page, comic: "c", chapter: "1")
        Issue.record("oversized transformed page was accepted")
    } catch { #expect((error as? URLError)?.code == .dataLengthExceedsMaximum) }
}
