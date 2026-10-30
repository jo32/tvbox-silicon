import Foundation
import Testing
@testable import TVCore

@MainActor private final class MemoryCloud: CloudValueStore {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
    func synchronize() -> Bool { true }
}

/// One device holding names by id, with its own ledger folder and defaults.
@MainActor private final class Device {
    var names: [String: String]
    let defaults: UserDefaults
    let sync: CloudSync
    init(_ cloud: MemoryCloud, names: [String: String] = [:]) {
        self.names = names
        defaults = UserDefaults(suiteName: "cloudsync." + UUID().uuidString)!
        sync = CloudSync(cloud: cloud, directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), defaults: defaults)
        sync.register("names", current: { [unowned self] in self.names },
                      apply: { [unowned self] in self.names = Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0.value) }) })
    }
}

@Test @MainActor func additionsAndRemovalsReachTheOtherDevice() {
    let cloud = MemoryCloud()
    let phone = Device(cloud), tv = Device(cloud)
    phone.names["a"] = "Alpha"
    phone.sync.flush()
    tv.sync.flush()
    #expect(tv.names == ["a": "Alpha"])
    tv.names["a"] = nil
    tv.sync.flush()
    phone.sync.flush()
    #expect(phone.names.isEmpty)
    // The removal is remembered, so the phone's next pass doesn't bring it back.
    tv.sync.flush()
    #expect(tv.names.isEmpty)
}

@Test @MainActor func twoDevicesAddingAtOnceKeepBoth() {
    let cloud = MemoryCloud()
    let phone = Device(cloud, names: ["a": "Alpha"]), mac = Device(cloud, names: ["b": "Beta"])
    phone.sync.flush()
    mac.sync.flush()
    phone.sync.flush()
    #expect(phone.names == ["a": "Alpha", "b": "Beta"])
    #expect(mac.names == phone.names)
}

@Test @MainActor func theNewerEditOfOneItemWins() {
    let cloud = MemoryCloud()
    let phone = Device(cloud, names: ["a": "Alpha"]), mac = Device(cloud)
    let start = Date(timeIntervalSince1970: 1_000_000)
    phone.sync.flush(now: start)
    mac.sync.flush(now: start.addingTimeInterval(1))
    mac.names["a"] = "Renamed"
    mac.sync.flush(now: start.addingTimeInterval(10))
    // The phone's edit is earlier, so the Mac's stays on both.
    phone.names["a"] = "Older"
    phone.sync.flush(now: start.addingTimeInterval(5))
    #expect(phone.names == ["a": "Renamed"])
    mac.sync.flush(now: start.addingTimeInterval(11))
    #expect(mac.names == ["a": "Renamed"])
}

@Test func aLocalEditIsStampedAfterWhatItReplacesEvenWithAClockBehind() {
    let ahead = Date(timeIntervalSince1970: 2_000_000)
    var ledger = CloudSyncLedger<String>()
    ledger.merge({ var other = CloudSyncLedger<String>(); other.note(["a": "Remote"], now: ahead); return other }())
    ledger.note(["a": "Local"], now: ahead.addingTimeInterval(-60))
    #expect(ledger.records["a"]!.stamp > ahead)
    ledger.note([:], now: ahead.addingTimeInterval(-60))
    #expect(ledger.records["a"]!.value == nil)
}

@Test func oldRemovalsArePrunedButRecentOnesStay() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    var ledger = CloudSyncLedger<String>()
    ledger.note(["old": "x", "new": "y", "kept": "z"], now: now.addingTimeInterval(-200 * 86400))
    ledger.note(["new": "y", "kept": "z"], now: now.addingTimeInterval(-100 * 86400))
    ledger.note(["kept": "z"], now: now.addingTimeInterval(-1))
    ledger.prune(before: now.addingTimeInterval(-CloudSync.removalLifetime))
    #expect(Set(ledger.records.keys) == ["new", "kept"])
}

@Test @MainActor func turnedOffNothingIsSentOrTaken() {
    let cloud = MemoryCloud()
    let phone = Device(cloud, names: ["a": "Alpha"])
    phone.defaults.set(false, forKey: CloudSync.enabledKey)
    phone.sync.flush()
    #expect(cloud.values.isEmpty)
    phone.sync.setEnabled(true)
    #expect(cloud.values["sync.names"] != nil)
}

@Test @MainActor func anotherICloudAccountGetsThisDevicesItemsInsteadOfRemovals() {
    let cloud = MemoryCloud()
    let phone = Device(cloud, names: ["a": "Alpha"])
    phone.sync.flush()
    phone.names = [:]
    cloud.values = [:]
    phone.sync.receive(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
    let ledger = CloudSync.decode(CloudSyncLedger<String>.self, from: cloud.values["sync.names"] ?? Data())
    #expect(ledger?.records.isEmpty ?? true)
}

@Test func orderedListsMergeByPlaceWithTheNewerItemFirstOnATie() {
    let early = Date(timeIntervalSince1970: 10), late = Date(timeIntervalSince1970: 20)
    #expect(CloudSync.ranks(["x", "y", "x"]) == ["x": 0, "y": 1])
    let items = [CloudSyncItem(id: "b", value: 0, stamp: early), CloudSyncItem(id: "a", value: 1, stamp: early),
                 CloudSyncItem(id: "c", value: 0, stamp: late)]
    #expect(CloudSync.ordered(items) == ["c", "b", "a"])
}

@Test func ledgersRoundTripCompressed() throws {
    var ledger = CloudSyncLedger<[String]>()
    ledger.note(["a": Array(repeating: "same text", count: 200)], now: Date())
    let data = try #require(CloudSync.encode(ledger))
    #expect(data.count < 400)
    #expect(CloudSync.decode(CloudSyncLedger<[String]>.self, from: data) == ledger)
}

@Test @MainActor func adoptedFavoritesPutTheNewestChangeFirst() {
    let favorites = Favorites(defaults: UserDefaults(suiteName: "favorites." + UUID().uuidString)!)
    let song = { (id: String) in FavoriteItem.music(MusicTrack(platform: .qq, songID: id, title: id, artists: ["A"])) }
    favorites.toggle(song("1"))
    favorites.toggle(song("2"))
    let base = Date(timeIntervalSince1970: 100)
    favorites.adopt([CloudSyncItem(id: song("1").key, value: song("1"), stamp: base),
                     CloudSyncItem(id: song("3").key, value: song("3"), stamp: base.addingTimeInterval(5)),
                     CloudSyncItem(id: song("2").key, value: song("2"), stamp: base)])
    #expect(favorites.items.map(\.key) == [song("3").key, song("2").key, song("1").key])
}

@Test @MainActor func adoptedHistoryKeepsTheNewestEntriesAndDropsRemovedOnes() {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: file) }
    let history = PlaybackHistory(file: file)
    let context = { (video: String) in
        PlaybackHistoryContext(origin: URL(string: "https://example.com/sub.json")!, sourceKey: "s", sourceName: "S",
                               videoID: video, videoName: video, episodeID: "1", episodeName: "1", episodeFlag: "line")
    }
    history.record(context("gone"), position: 10, duration: 100)
    let newer = PlaybackHistoryEntry(context: context("new"), position: 20, duration: 100, updatedAt: Date())
    let older = PlaybackHistoryEntry(context: context("old"), position: 30, duration: 100, updatedAt: Date().addingTimeInterval(-60))
    history.adopt([older, newer])
    #expect(history.entries.map(\.context.videoID) == ["new", "old"])
    #expect(PlaybackHistory(file: file).entries.count == 2)
}
