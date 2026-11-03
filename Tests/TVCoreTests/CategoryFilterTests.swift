import Foundation
import Testing
@testable import TVCore

/// Issue #358: a source's `filters` (类型, 地区, 年份…) were dropped, so its finer categories could not be chosen.
@Test func homeFiltersAttachToTheirCategories() throws {
    let json = try JSONDecoder().decode([String: JSONValue].self, from: Data(#"""
    {"class": [{"type_id": "1", "type_name": "电影"}, {"type_id": 2, "type_name": "剧集"}],
     "filters": {"1": [
        {"key": "cateId", "name": "类型", "value": [{"n": "全部", "v": ""}, {"n": "动作片", "v": "6"}, {"n": "喜剧片", "v": "7"}]},
        {"key": "year", "name": "年份", "init": "2024", "value": [{"n": "2024", "v": 2024}, {"n": "2023", "v": 2023}]},
        {"key": "one", "name": "只有一个", "value": [{"n": "全部", "v": ""}]},
        {"name": "没有 key", "value": [{"n": "a", "v": "a"}, {"n": "b", "v": "b"}]}
     ]}}
    """#.utf8))
    let page = CatalogPage(json: json, origin: URL(string: "https://example.com")!)
    let movies = try #require(page.categories.first)
    #expect(movies.filters.map(\.key) == ["cateId", "year"])
    #expect(movies.filters[0].options.map(\.name) == ["全部", "动作片", "喜剧片"])
    #expect(movies.filters[1].options.map(\.value) == ["2024", "2023"])
    #expect(CategoryFilter.initialChoices(movies.filters) == ["cateId": "", "year": "2024"])
    #expect(page.categories[1].id == "2" && page.categories[1].filters.isEmpty)
}

@Test func homeFiltersSentAsTextAreRead() {
    let filters = #"{"5": [{"key": "area", "name": "地区", "value": [{"n": "全部", "v": ""}, {"n": "美国", "v": "美国"}]}]}"#
    let page = CatalogPage(json: ["class": .array([.object(["type_id": .string("5"), "type_name": .string("综艺")])]), "filters": .string(filters)],
                           origin: URL(string: "https://example.com")!)
    #expect(page.categories.first?.filters.first?.options.last?.value == "美国")
}

@Test func filterChoicesReachEachKindOfSource() throws {
    let choices = ["area": "美国", "cateId": "", "year": "2024"]
    let json = #"{"area":"美国","year":"2024"}"#
    #expect(CatalogClient.filterParameters(choices, siteType: 3) == ["filters": json])
    #expect(CatalogClient.filterParameters(choices, siteType: 1) == ["f": json])
    #expect(CatalogClient.filterParameters(choices, siteType: 4) == ["ext": Data(json.utf8).base64EncodedString()])
    #expect(CatalogClient.filterParameters(["cateId": ""], siteType: 3).isEmpty)

    // Base64 can hold `+`, which a server reads as a space unless it is escaped.
    let base = URL(string: "https://example.com/config.json")!
    let config = try Subscription.parse(Data(#"{"sites":[{"key":"a","api":"https://example.com/api?token=a+b","type":4}]}"#.utf8), origin: base)
    let client = CatalogClient(site: config.sites[0], origin: base)
    let ext = Data(">>>???".utf8).base64EncodedString()
    #expect(ext == "Pj4+Pz8/")
    let url = try client.requestURL(["t": "1", "ext": ext])
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(query.percentEncodedQuery?.contains("token=a+b") == true)
    #expect(query.queryItems?.first { $0.name == "ext" }?.value == ext)
    #expect(!(query.percentEncodedQueryItems?.first { $0.name == "ext" }?.value?.contains("+") ?? true))
}

@Test func aFilteredCategoryMayBeEmpty() {
    #expect(LiteSites.unusable(["list": .array([])], params: ["t": "1", "pg": "1"]) != nil)
    #expect(LiteSites.unusable(["list": .array([])], params: ["t": "1", "pg": "1", "filters": #"{"year":"1990"}"#]) == nil)
}

@MainActor @Test func categoryPagesKeepTheirFilters() async {
    let model = CatalogBrowser()
    let filtered = CatalogBrowser.Request.list(category: "1", query: "", page: 1, filters: ["year": "2024"])
    await model.load(filtered) { _ in CatalogPage(json: ["pagecount": .number(3)], origin: URL(string: "https://example.com")!) }
    #expect(model.filters == ["year": "2024"])
    await model.load(.list(category: model.category, query: "", page: 2, filters: model.filters)) { request in
        #expect(request == .list(category: "1", query: "", page: 2, filters: ["year": "2024"]))
        return CatalogPage(json: [:], origin: URL(string: "https://example.com")!)
    }
    #expect(model.page == 2 && model.filters == ["year": "2024"])
    await model.load(.home) { _ in CatalogPage(json: ["list": .array([.object(["vod_id": .string("a"), "vod_name": .string("a")])])], origin: URL(string: "https://example.com")!) }
    #expect(model.filters.isEmpty)
}

/// A category-only home opens its first category with that category's opening filter choices.
@MainActor @Test func firstCategoryOpensWithItsInitialFilters() async {
    let model = CatalogBrowser()
    let home = try! JSONDecoder().decode([String: JSONValue].self, from: Data(#"""
    {"class": [{"type_id": "1", "type_name": "电影"}],
     "filters": {"1": [{"key": "year", "name": "年份", "init": "2024", "value": [{"n": "2024", "v": "2024"}, {"n": "2023", "v": "2023"}]}]}}
    """#.utf8))
    await model.load(.home) { request in
        if request != .home { #expect(request == .list(category: "1", query: "", page: 1, filters: ["year": "2024"])) }
        return CatalogPage(json: request == .home ? home : [:], origin: URL(string: "https://example.com")!)
    }
    #expect(model.request == .list(category: "1", query: "", page: 1, filters: ["year": "2024"]))
    #expect(model.filters == ["year": "2024"])
}

private let filterSpider = #"""
export default {
    async category(tid, pg, filter, extend) { return JSON.stringify({ list: [{ vod_id: tid, vod_name: JSON.stringify(extend) }] }); }
};
"""#

@Test func javaScriptSpidersGetTheFilterChoices() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = try await ScriptSession.start(api: "https://scripts.example/filters.js", key: "test", ext: "", profile: folder.appendingPathComponent("profile"), label: "test", source: filterSpider)
    defer { session.close() }
    func extend(_ params: [String: String]) async throws -> [String: String] {
        let envelope = try await session.call(params)
        let result = try #require(envelope["result"]?.string, "\(envelope)")
        let page = try JSONDecoder().decode([String: JSONValue].self, from: Data(result.utf8))
        let name = try #require(page["list"]?.array?.first?.object?["vod_name"]?.string)
        return try JSONDecoder().decode([String: String].self, from: Data(name.utf8))
    }
    #expect(try await extend(["t": "1", "pg": "1", "filters": #"{"area":"美国"}"#]) == ["area": "美国"])
    #expect(try await extend(["t": "1", "pg": "1"]).isEmpty)
}
