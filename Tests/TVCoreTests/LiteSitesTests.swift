import Foundation
import Testing
@testable import TVCore

struct LiteSitesTests {
    func site(_ api: String, ext: JSONValue? = nil, type: Int = 3) -> Site {
        Site(key: api, name: api, type: type, api: api, raw: ext.map { ["ext": $0] } ?? [:])
    }

    @Test func portedClassesStayJarSourcesWithAPortFirst() throws {
        let ported = site("csp_Jianpian")
        #expect(ported.liteScript?.absoluteString == "assets://sites/Jianpian.js")
        #expect(ported.runtime == .jar)
        #expect(ported.preferredRuntime == .javascript)
        #expect(site("csp_NoSuchPort").liteScript == nil)
        #expect(site("csp_Jianpian", type: 1).liteScript == nil)
    }

    @Test func scriptExtKeepsTheJar() {
        // drpy-style loaders hand the spider a script; the port cannot run it.
        #expect(site("csp_Jianpian", ext: .string("./js/site.js")).liteScript == nil)
        #expect(site("csp_Jianpian", ext: .string("https://host/a.py?x=1")).liteScript == nil)
        #expect(site("csp_Jianpian", ext: .string("https://host/filters.json")).liteScript != nil)
        #expect(site("csp_Jianpian", ext: .object(["filter": .string("a.js")])).liteScript != nil)
    }

    @Test func emptyAnswersFallBackExceptSearchAndLaterPages() {
        let empty: [String: JSONValue] = ["list": .array([])]
        let item: [String: JSONValue] = ["list": .array([.object(["vod_id": .string("1")])])]
        #expect(LiteSites.unusable(empty, params: [:]) != nil)
        #expect(LiteSites.unusable(["class": .array([.object(["type_id": .string("1")])])], params: [:]) == nil)
        #expect(LiteSites.unusable(empty, params: ["t": "1", "pg": "1"]) != nil)
        #expect(LiteSites.unusable(empty, params: ["t": "1", "pg": "2"]) == nil)
        #expect(LiteSites.unusable(item, params: ["t": "1", "pg": "1"]) == nil)
        #expect(LiteSites.unusable(empty, params: ["wd": "x", "pg": "1"]) == nil)
        #expect(LiteSites.unusable(empty, params: ["ids": "1"]) != nil)
        #expect(LiteSites.unusable(item, params: ["ids": "1"]) == nil)
        #expect(LiteSites.unusable(["parse": .number(0), "url": .string("")], params: ["play": "x"]) != nil)
        #expect(LiteSites.unusable(["parse": .number(0), "url": .string("https://a/b.m3u8")], params: ["play": "x"]) == nil)
    }

    @Test func fallbackCoolsDownPerSource() async {
        let fallback = LiteFallback()
        #expect(await fallback.prefersPort("a"))
        await fallback.record("a")
        #expect(await !fallback.prefersPort("a"))
        #expect(await fallback.prefersPort("b"))
    }
}
