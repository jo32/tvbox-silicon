import Foundation
import Testing
@testable import TVCore

private func playlist(_ name: String, _ address: String) -> LiveSource { LiveSource(name: name, url: URL(string: address)!) }
private let huya = LiveSource(name: "Huya", url: URL(string: "huya://rooms")!)

@Test @MainActor func hiddenLiveSourcesPersistAndSync() throws {
    let suite = "hidden.live." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let news = playlist("News", "https://one.example/tv.m3u")
    let hidden = HiddenLiveSources(defaults: defaults)
    var changes = 0
    hidden.onChange = { changes += 1 }
    hidden.setHidden([huya, news], hidden: true)
    hidden.setHidden([huya], hidden: true)
    #expect(hidden.contains(huya) && hidden.contains(news))
    // Known by address: the same playlist under another name (a subscription's title) is the same one.
    #expect(hidden.contains(playlist("My list", "https://one.example/tv.m3u")))
    #expect(HiddenLiveSources(defaults: defaults).contains(huya))
    #expect(changes == 1)
    hidden.setHidden([huya], hidden: false)
    #expect(!hidden.contains(huya) && hidden.savedKeys == ["https://one.example/tv.m3u"])
    // Another device's list replaces this one's without being sent back.
    hidden.adopt(["huya://rooms"])
    #expect(hidden.contains(huya) && !hidden.contains(news) && changes == 2)
}

@Test func livePlaylistsGroupBySubscription() {
    let origin = URL(string: "https://a.example/a.json")!
    let full = Subscription(origin: origin, importedAt: Date(), sites: [Site(key: "s", name: "s", type: 3, api: "csp_S", raw: [:])],
                            lives: [playlist("IPTV", "https://a.example/iptv.m3u"), playlist("Sports", "https://a.example/sports.txt")], raw: [:])
    let other = Subscription(origin: URL(string: "https://b.example/b.json")!, importedAt: Date(), sites: [],
                             lives: [playlist("Same", "https://a.example/iptv.m3u"), playlist("Kids", "https://b.example/kids.m3u")], raw: [:])
    let m3u = Subscription(origin: URL(string: "https://c.example/tv.m3u")!, importedAt: Date(), sites: [],
                           lives: [playlist("Live TV", "https://c.example/tv.m3u")], raw: [:])
    #expect(m3u.isPlaylistOnly && !full.isPlaylistOnly && !other.isPlaylistOnly)
    let entries = [SubscriptionEntry(address: "https://c.example/tv.m3u", name: "Home"),
                   SubscriptionEntry(address: "https://a.example/a.json", name: "Big"),
                   SubscriptionEntry(address: "https://b.example/b.json", name: "")]
    let parts = [(entries[0], m3u), (entries[1], full), (entries[2], other)]
    let merged = Subscription.merge([m3u, full, other])!
    let groups = LivePlaylistGroup.make(merged.lives, subscriptions: parts.map { (entry: $0.0, document: $0.1) })
    #expect(groups.map(\.title) == [nil, "Big", "b.example · b.json"])
    // A playlist that is its own subscription is named after it; a repeat shows under the first subscription only.
    #expect(groups[0].sources.map(\.name) == ["Home"])
    #expect(groups[1].sources.map(\.name) == ["IPTV", "Sports"])
    #expect(groups[2].sources.map(\.name) == ["Kids"])
    // Hidden ones aren't passed in, and a subscription left with none has no section.
    let shown = merged.lives.filter { $0.url.absoluteString != "https://b.example/kids.m3u" }
    #expect(LivePlaylistGroup.make(shown, subscriptions: parts.map { (entry: $0.0, document: $0.1) }).map(\.title) == [nil, "Big"])
    #expect(LivePlaylistGroup.make([], subscriptions: parts.map { (entry: $0.0, document: $0.1) }).isEmpty)
}

@Test @MainActor func smallImportedFilesSyncAndLargeOnesStay() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let tag = UUID().uuidString.prefix(8)
    let small = folder.appending(path: "live-\(tag).m3u"), large = folder.appending(path: "big-\(tag).txt")
    let binary = folder.appending(path: "bin-\(tag).json")
    try Data("#EXTM3U\n#EXTINF:-1,News\nhttps://tv.example/news.m3u8\n".utf8).write(to: small)
    // Random text doesn't compress, so it can't fit the budget.
    try Data((0..<300_000).map { _ in UInt8.random(in: 0...255) }).base64EncodedData().write(to: large)
    try Data([0xff, 0xfe, 0x00, 0xd8]).write(to: binary)
    let addresses = try [large, small, binary].map { try ImportedFiles.add($0).absoluteString }
    defer { addresses.forEach(ImportedFiles.remove) }
    let texts = ImportedFiles.syncedTexts(for: addresses + ["https://web.example/tv.m3u"])
    #expect(Array(texts.keys) == [small.lastPathComponent])

    // Another device: the file arrives and its address loads.
    ImportedFiles.remove(addresses[1])
    #expect(ImportedFiles.isMissing(addresses[1]))
    #expect(ImportedFiles.adopt(texts))
    #expect(!ImportedFiles.adopt(texts))
    #expect(try ImportedFiles.data(at: URL(string: addresses[1])!) == Data(texts[small.lastPathComponent]!.utf8))
    // Names that would leave the folder are not written.
    #expect(!ImportedFiles.adopt(["../x.m3u": "x", ".hidden": "x", "": "x"]))
}
