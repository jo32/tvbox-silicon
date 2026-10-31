import Foundation
import Testing
@testable import TVCore

@Test func conversionAheadPreparesEachArchiveOfTheJarSourcesOnce() throws {
    let config = try Subscription.parse(Data(#"""
    {"spider":"https://a.example/shared.jar;md5;00",
     "sites":[{"key":"1","api":"csp_Alpha","type":3},
              {"key":"2","api":"csp_Beta","type":3,"jar":"./own.jar"},
              {"key":"3","api":"csp_Gamma","type":3},
              {"key":"4","api":"csp_Alpha","type":3},
              {"key":"5","api":"csp_Hidden","type":3,"hide":1},
              {"key":"6","api":"https://a.example/api","type":1},
              {"key":"7","api":"https://a.example/x.js","type":3},
              {"key":"8","api":"csp_Bad.Name","type":3}]}
    """#.utf8), origin: URL(string: "https://a.example/tv.json")!)
    let expected: [PluginConversionAhead.Archive] = [
        .init(url: URL(string: "https://a.example/shared.jar")!, spiders: ["Alpha", "Gamma"]),
        .init(url: URL(string: "https://a.example/own.jar")!, spiders: ["Beta"]),
    ]
    #expect(PluginConversionAhead.archives(config.sites, origin: config.origin, spider: config.spiderURL) == expected)
    // The app passes the merged subscription; each source keeps its own subscription's spider.
    let merged = try #require(Subscription.merge([config]))
    #expect(PluginConversionAhead.archives(merged.sites, origin: merged.origin, spider: merged.spiderURL) == expected)
}

@Test func conversionAheadWaitsForAQuietDevice() {
    let free = PluginConversionAhead.Conditions(active: true, lowPower: false, thermal: .fair, availableMemory: 900 << 20, idle: 45)
    #expect(free.allowsWork)
    var busy = free; busy.idle = 0
    #expect(!busy.allowsWork, "a plugin request is running or just ended")
    var away = free; away.active = false
    #expect(!away.allowsWork, "the app is in the background")
    var saving = free; saving.lowPower = true
    #expect(!saving.allowsWork, "Low Power Mode")
    var hot = free; hot.thermal = .serious
    #expect(!hot.allowsWork, "the device is hot")
    var tight = free; tight.availableMemory = 300 << 20
    #expect(!tight.allowsWork, "memory is short")
}

@Test func aRunningPluginRequestKeepsConversionAheadAway() {
    PluginConversionAhead.requestStarted()
    #expect(PluginConversionAhead.current().idle == 0)
    PluginConversionAhead.requestEnded()
    #expect(PluginConversionAhead.current().idle < 30, "the request only just ended")
}
