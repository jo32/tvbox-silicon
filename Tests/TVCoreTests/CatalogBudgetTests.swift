import Foundation
import Testing
@testable import TVCore

@Test func catalogComplexityRejectsDepthAndStructuralWidth() async throws {
    let deep = Data(("{\"list\":" + String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65) + "}").utf8)
    await #expect(throws: (any Error).self) { _ = try await CatalogResponseParser.decode(deep) }
    let wide = Data(("{\"list\":[" + Array(repeating: "0", count: 100_001).joined(separator: ",") + "]}").utf8)
    await #expect(throws: (any Error).self) { _ = try await CatalogResponseParser.decode(wide) }
}
@Test func catalogComplexityDoesNotCountQuotedBracketsOrEscapedQuotes() async throws {
    let value = String(repeating: "[\\\"{,", count: 200)
    let data = try JSONEncoder().encode(["value": value, "empty": ""])
    let parsed = try await CatalogResponseParser.decode(data, maximumBytes: data.count)
    #expect(parsed["value"]?.string == value)
    await #expect(throws: (any Error).self) { _ = try await CatalogResponseParser.decode(data, maximumBytes: data.count - 1) }
}
@Test func searchPayloadIncludesLongMetadataAndPreservesExistingBudget() {
    let site = Site(key: "one", name: "one", type: 1, api: "https://one.invalid", raw: [:])
    func result(_ synopsis: String) -> SearchSourceResult {
        SearchSourceResult(site: site, page: CatalogPage(json: ["list": .array([.object([
            "vod_id": .string("a"), "vod_name": .string("title"), "vod_content": .string(synopsis)
        ])])], origin: URL(string: "https://one.invalid")!), error: nil)
    }
    let first = result("small"), oversized = result(String(repeating: "x", count: 4096))
    var budget = SearchPayloadBudget(maximumBytes: 3000, maximumItems: 10)
    let accepted = budget.reserve(SearchPayloadBudget.cost(first))
    #expect(accepted)
    let before = budget.used
    let rejected = budget.reserve(SearchPayloadBudget.cost(oversized))
    #expect(!rejected)
    #expect(budget.used == before)
}
@Test func searchPageDropsUnusedCategoryAndFilterPayloads() {
    let page = CatalogPage(json: ["class": .array([.object(["type_id": .string("a"), "type_name": .string("Unused")])]),
                                  "list": .array([]), "pagecount": .number(9)], origin: URL(string: "https://one.invalid")!)
    let result = SearchPayloadBudget.trimmed(page)
    #expect(result.categories.isEmpty)
    #expect(result.pageCount == 9)
}

@MainActor @Test func rejectedSearchResultDoesNotDiscardExistingCards() throws {
    let site = Site(key: "one", name: "one", type: 1, api: "https://one.invalid", raw: [:])
    let model = SearchModel()
    let page = CatalogPage(json: ["list": .array([.object(["vod_id": .string("small"), "vod_name": .string("existing")])])], origin: URL(string: "https://one.invalid")!)
    model.accept(SearchSourceResult(site: site, page: page, error: nil))
    let huge = CatalogPage(json: ["list": .array([.object(["vod_id": .string("large"), "vod_content": .string(String(repeating: "x", count: 33 << 20))])])], origin: URL(string: "https://one.invalid")!)
    let rejected = try #require(model.retain(SearchSourceResult(site: site, page: huge, error: nil)))
    #expect(rejected.error != nil)
    #expect(rejected.page == nil)
    #expect(model.results.first?.page?.videos.first?.id == "small")
}
@Test func concurrentCatalogDecodesAndCancelledCallerRemainIndependent() async throws {
    let data = Data("{\"list\":[]}".utf8)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<40 { group.addTask { _ = try await CatalogResponseParser.decode(data) } }
        try await group.waitForAll()
    }
    let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await CatalogResponseParser.decode(data) }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try await CatalogResponseParser.decode(data)["list"]?.array?.isEmpty == true)
}

@Test func validLargeCatalogStillDecodesAndMalformedJSONIsRejected() async throws {
    let data = Data(("{\"list\":[" + Array(repeating: "0", count: 20_000).joined(separator: ",") + "]}").utf8)
    #expect(try await CatalogResponseParser.decode(data)["list"]?.array?.count == 20_000)
    await #expect(throws: (any Error).self) { _ = try await CatalogResponseParser.decode(Data("{\"list\":[1,}".utf8)) }
}
@Test func retainedItemCountIsBoundedSeparatelyFromBytes() {
    var budget = SearchPayloadBudget(maximumBytes: 1_000_000, maximumItems: 2)
    let first = budget.reserve(.init(bytes: 1, items: 2))
    let overflow = budget.reserve(.init(bytes: 1, items: 1))
    #expect(first)
    #expect(!overflow)
    #expect(budget.used == .init(bytes: 1, items: 2))
}

@MainActor @Test func rejectedSourceMetadataIsNotRetainedOutsideTheBudget() {
    let model = SearchModel()
    let site = Site(key: "large-source", name: "large", type: 1, api: "https://one.invalid",
                    raw: ["ext": .string(String(repeating: "x", count: 33 << 20))])
    let answer = model.retain(SearchSourceResult(site: site, page: nil, error: "failed"))
    let retained = [answer].compactMap { $0 }
    let cost = retained.reduce(SearchPayloadBudget.Cost()) { $0 + SearchPayloadBudget.cost($1) }
    #expect(cost.bytes <= 32 << 20)
    #expect(answer == nil)
    #expect(model.resultLimitMessage != nil)
}
@MainActor @Test func rejectedAnswersCannotExceedTheRetainedItemLimit() {
    let model = SearchModel()
    let site = Site(key: "one", name: "one", type: 1, api: "https://one.invalid", raw: [:])
    var retained = [SearchSourceResult]()
    for _ in 0..<24_010 {
        let answer = model.retain(SearchSourceResult(site: site, page: nil, error: "failed"))
        retained.append(contentsOf: [answer].compactMap { $0 })
    }
    let cost = retained.reduce(SearchPayloadBudget.Cost()) { $0 + SearchPayloadBudget.cost($1) }
    #expect(cost.items <= 24_000)
    #expect(cost.bytes <= 32 << 20)
}
@Test func unicodeJSONEncodingsCannotHideStructuralDepth() async throws {
    // The low byte of U+0122 is 0x22, which must not act as a structural quote in a UTF-16 scan.
    let deep = "{\"Ģ\":" + String(repeating: "[", count: 80) + "0" + String(repeating: "]", count: 80) + "}"
    for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32, .utf32LittleEndian, .utf32BigEndian] {
        let data = try #require(deep.data(using: encoding))
        await #expect(throws: (any Error).self) { _ = try await CatalogResponseParser.decode(data) }
    }
}
@Test func supportedUnicodeJSONEncodingsKeepValidValues() async throws {
    let value = "{\"Ģ\":\"[\\\"{}\"}"
    for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32, .utf32LittleEndian, .utf32BigEndian] {
        let data = try #require(value.data(using: encoding))
        let parsed = try await CatalogResponseParser.decode(data)
        #expect(parsed["Ģ"]?.string == "[\"{}")
    }
}

@Test func retainedMergedSourceIncludesItsOriginAndSpider() throws {
    let path = String(repeating: "folder/", count: 150)
    let origin = try #require(URL(string: "https://origin.invalid/" + path))
    let spider = try #require(URL(string: "https://archive.invalid/" + path))
    var site = Site(key: "two@branch", name: "Two", type: 1, api: "/catalog", raw: ["key": .string("two")])
    let before = SearchPayloadBudget.cost(SearchSourceResult(site: site, page: nil, error: nil))
    site.provenance = SourceProvenance(origin: origin, spider: spider)
    let after = SearchPayloadBudget.cost(SearchSourceResult(site: site, page: nil, error: nil))
    #expect(after.bytes >= before.bytes + origin.absoluteString.utf8.count + spider.absoluteString.utf8.count)
    #expect(after.items == before.items)
}

@Test func normalizedUTF8OutputAlsoFitsTheByteBudget() async throws {
    let json = "{\"text\":\"" + String(repeating: "漢", count: 100) + "\"}"
    let data = try #require(json.data(using: .utf16LittleEndian))
    #expect(data.count < json.utf8.count)
    await #expect(throws: (any Error).self) { _ = try await CatalogResponseParser.decode(data, maximumBytes: data.count) }
}

@Test func smallMultilingualCatalogsShareOneNormalizedByteBoundary() async throws {
    let json = #"{"title":"春の海 🎬 Café","tags":["[a]","\"b\""]}"#
    let samples: [(String.Encoding, [UInt8])] = [
        (.utf8, [0xef, 0xbb, 0xbf]), (.utf16LittleEndian, [0xff, 0xfe]), (.utf16BigEndian, [0xfe, 0xff]),
        (.utf32LittleEndian, [0xff, 0xfe, 0, 0]), (.utf32BigEndian, [0, 0, 0xfe, 0xff])
    ]
    for (encoding, marker) in samples {
        let bytes = try #require(json.data(using: encoding))
        for data in [bytes, Data(marker) + bytes] {
            let limit = max(data.count, json.utf8.count)
            let parsed = try await CatalogResponseParser.decode(data, maximumBytes: limit)
            #expect(parsed["title"]?.string == "春の海 🎬 Café")
            #expect(parsed["tags"]?.array == [.string("[a]"), .string("\"b\"")])
            await #expect(throws: URLError(.dataLengthExceedsMaximum)) {
                _ = try await CatalogResponseParser.decode(data, maximumBytes: limit - 1)
            }
        }
    }
}

@Test func stringEscapesSurviveButRawNULAndPartialCodeUnitsAreRejected() async throws {
    for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
        let escaped = try #require(#"{"title":"A\u0000B"}"#.data(using: encoding))
        #expect(try await CatalogResponseParser.decode(escaped)["title"]?.string == "A\0B")
        let invalid = try #require("{\"title\":\"A\0B\"}".data(using: encoding))
        await #expect(throws: URLError(.cannotDecodeContentData)) { _ = try await CatalogResponseParser.decode(invalid) }
        if encoding != .utf8 {
            await #expect(throws: URLError(.cannotDecodeContentData)) { _ = try await CatalogResponseParser.decode(escaped + Data([32])) }
        }
    }
}
