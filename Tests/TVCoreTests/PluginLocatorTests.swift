import Foundation
import Testing
@testable import TVCore

private func fixture(_ name: String, _ ext: String) throws -> Data {
    try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
}

@Test func spiderClassesAreReadFromPlainAndDisguisedArchives() throws {
    let expected: Set<String> = ["XBPQ", "AppGet"]
    #expect(PluginLocator.spiderClasses(inArchive: try fixture("plugin-classes", "jar")) == expected)
    // Some subscriptions serve archives behind image bytes; recorded offsets shift with the prefix.
    #expect(PluginLocator.spiderClasses(inArchive: try fixture("plugin-classes-disguised", "png")) == expected)
    #expect(PluginLocator.spiderClasses(inArchive: Data("not an archive".utf8)).isEmpty)
}

@Test func missingSpiderClassIsNamedFromTheHostError() {
    #expect(PluginClassMissing.className(in: "java.lang.ClassNotFoundException: com.github.catvod.spider.XBPQ\n\tat x") == "XBPQ")
    #expect(PluginClassMissing.className(in: "java.lang.ClassNotFoundException: okhttp3.Call") == nil)
}

@Test func pluginArchivesListMostUsedFirst() throws {
    let config = try Subscription.parse(Data(#"""
    {"spider":"https://a.example/shared.jar;md5;00",
     "sites":[{"key":"1","api":"csp_A","type":3,"jar":"https://a.example/rare.jar"},
              {"key":"2","api":"csp_B","type":3,"jar":"https://a.example/common.jar"},
              {"key":"3","api":"csp_C","type":3,"jar":"https://a.example/common.jar"},
              {"key":"4","api":"https://a.example/api","type":1}]}
    """#.utf8), origin: URL(string: "https://a.example/tv.json")!)
    #expect(config.pluginArchives.map(\.lastPathComponent) == ["common.jar", "rare.jar", "shared.jar"])
}
