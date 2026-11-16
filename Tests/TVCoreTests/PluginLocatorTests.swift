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

/// A one-file ZIP that stores the file uncompressed (method 0).
private func storedArchive(name: String, contents: Data) -> Data {
    var data = Data()
    func put(_ value: Int, _ width: Int) { for byte in 0..<width { data.append(UInt8(value >> (8 * byte) & 0xff)) } }
    let file = Data(name.utf8)
    put(0x0403_4b50, 4); put(10, 2); put(0, 2); put(0, 2); put(0, 4); put(0, 4)
    put(contents.count, 4); put(contents.count, 4); put(file.count, 2); put(0, 2)
    data.append(file); data.append(contents)
    let directory = data.count
    put(0x0201_4b50, 4); put(10, 2); put(10, 2); put(0, 2); put(0, 2); put(0, 4); put(0, 4)
    put(contents.count, 4); put(contents.count, 4); put(file.count, 2); put(0, 2); put(0, 2)
    put(0, 2); put(0, 2); put(0, 4); put(0, 4)
    data.append(file)
    let size = data.count - directory
    put(0x0605_4b50, 4); put(0, 2); put(0, 2); put(1, 2); put(1, 2); put(size, 4); put(directory, 4); put(0, 2)
    return data
}

@Test func storedEntriesAreReadFromArchivesAndTheirSlices() {
    let dex = Data("dex\n035\u{0}Lcom/github/catvod/spider/Stored;".utf8)
    let archive = storedArchive(name: "classes.dex", contents: dex)
    #expect(ZipArchive.entries(in: archive, where: { $0.hasSuffix(".dex") }) == [dex])
    #expect(PluginLocator.spiderClasses(inArchive: archive) == ["Stored"])
    // The archive is read in place, so a slice that doesn't start at index 0 must read the same.
    let padded = Data([1, 2, 3]) + archive
    #expect(ZipArchive.entries(in: padded[3...], where: { $0.hasSuffix(".dex") }) == [dex])
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
