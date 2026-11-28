import Foundation
import Testing
@testable import TVCore

/// #1364: a global search asks every source for the simplified name, so a Traditional keyword finds what the
/// source's simplified catalogue holds. Answers each search with a result named after the page, keeps the keyword
/// it was asked for, and offers a second page so pagination is asked the same way.
private final class SimplifiedQueryProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var keywords: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let page = Int(items.first(where: { $0.name == "pg" })?.value ?? "1") ?? 1
        if let keyword = items.first(where: { $0.name == "wd" })?.value { Self.keywords.append(keyword) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"pagecount":2,"list":[{"vod_id":"p\#(page)","vod_name":"A"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The whole chain: the search field's Traditional keyword reaches the source as simplified, on the first page and on
/// every page after it, and the field and the history still show what was typed (the conversion is in `GlobalSearch`
/// and `loadMore`, not in `SearchModel.keyword`).
@Suite(.serialized) struct SimplifiedSearchTests {
    @Test @MainActor func searchAndItsLaterPagesAskSourcesTheSimplifiedKeywordAndKeepWhatWasTyped() async throws {
        SimplifiedQueryProtocol.keywords = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimplifiedQueryProtocol.self]
        let model = SearchModel(http: HTTPClient(session: URLSession(configuration: configuration)))
        let config = try Subscription.parse(Data(#"{"sites":[{"key":"cms","type":1,"api":"/provide/vod"}]}"#.utf8),
                                            origin: URL(string: "https://sources.example/sub.json")!)
        model.search("  鬼滅之刃 ", config: config)
        await model.task?.value
        // A source matching its simplified catalogue is asked for the simplified name.
        #expect(SimplifiedQueryProtocol.keywords == ["鬼灭之刃"])
        #expect(model.videoCount == 1)
        // Trimming still happens; the Traditional spelling the viewer typed is what is remembered.
        #expect(model.keyword == "鬼滅之刃")
        #expect(model.draft == "鬼滅之刃")

        // The second page is a separate request that does not go through `GlobalSearch`: it must be asked for the
        // same simplified keyword, or the results stop at the first page.
        model.loadMore(nil, config: config)
        await model.moreTask?.value
        #expect(SimplifiedQueryProtocol.keywords == ["鬼灭之刃", "鬼灭之刃"])
        #expect(model.videos(for: "cms").map(\.id) == ["p1", "p2"])
        #expect(model.keyword == "鬼滅之刃")
    }

    /// The keywords the conversion leaves alone, and the one script it changes beyond Chinese.
    @Test func simplifiedKeywordLeavesEverythingElseAsItWas() {
        // `convert` is overloaded for a chapter's texts; this is the one a keyword goes through.
        let simplified: (String) -> String = NovelScript.simplified.convert
        // Nothing Chinese to convert: the keyword is the same one the viewer typed.
        #expect(simplified("Attack on Titan") == "Attack on Titan")
        #expect(simplified("Attack ON titan 2") == "Attack ON titan 2")
        #expect(simplified("123 !@# $%^&*()") == "123 !@# $%^&*()")
        #expect(simplified("") == "")
        // Already simplified: converting a second time changes nothing.
        #expect(simplified("鬼灭之刃") == "鬼灭之刃")
        #expect(simplified(simplified("鬼滅の刃")) == simplified("鬼滅の刃"))

        // Japanese kana are left alone, and the kanji Japanese borrows from Traditional Chinese are converted like any
        // other (ICU maps 滅 → 灭): a keyword says nothing about the language it is in, so `Hant-Hans` treats 「鬼滅の刃」
        // as Chinese characters, the same transform `TitleMatch` already applies to a result's title.
        #expect(simplified("鬼滅の刃") == "鬼灭の刃")
    }
}
