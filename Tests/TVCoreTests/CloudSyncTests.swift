import Foundation
import Testing
@testable import TVCore

@MainActor private final class MemoryCloud: CloudValueStore {
    var values: [String: Data] = [:]
    var synchronizations = 0
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
    func synchronize() -> Bool { synchronizations += 1; return true }
}

/// One device holding names by id, with its own ledger folder and defaults.
@MainActor private final class Device {
    var names: [String: String]
    var others: [String: String]
    let defaults: UserDefaults
    let sync: CloudSync
    init(_ cloud: MemoryCloud, names: [String: String] = [:]) {
        self.names = names
        others = [:]
        defaults = UserDefaults(suiteName: "cloudsync." + UUID().uuidString)!
        sync = CloudSync(cloud: cloud, directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), defaults: defaults)
        sync.register("names", current: { [unowned self] in self.names },
                      apply: { [unowned self] in self.names = Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0.value) }) })
        sync.register("others", current: { [unowned self] in self.others },
                      apply: { [unowned self] in self.others = Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0.value) }) })
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

/// A player's history and sync ledger are separate: going offline can delay a saved position's upload.
@MainActor private final class HistoryDevice {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let history: PlaybackHistory
    let sync: CloudSync
    private let suite = "history-sync." + UUID().uuidString

    init(_ cloud: MemoryCloud) {
        history = PlaybackHistory(file: directory.appending(path: "history.json"))
        sync = CloudSync(cloud: cloud, directory: directory.appending(path: "sync"), defaults: UserDefaults(suiteName: suite)!)
        let history = history
        sync.register("history", modifiedAt: { $0.updatedAt }, current: { Dictionary(uniqueKeysWithValues: history.entries.map { ($0.id, $0) }) },
                      apply: { history.adopt($0.map(\.value)) })
    }

    func record(_ episode: String, position: Double = 60, at date: Date) {
        let context = PlaybackHistoryContext(origin: URL(string: "https://example.com/sub.json")!, sourceKey: "source", sourceName: "Source",
                                             videoID: "series", videoName: "Series", episodeID: episode, episodeName: "Episode " + episode, episodeFlag: "line")
        history.record(context, position: position, duration: 1800, now: date)
    }

    func clean() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@Test @MainActor func aDelayedHistoryUploadDoesNotReplaceMoreRecentViewing() {
    let cloud = MemoryCloud(), start = Date(timeIntervalSince1970: 4_000_000)
    let mac = HistoryDevice(cloud), phone = HistoryDevice(cloud)
    defer { mac.clean(); phone.clean() }
    mac.record("17", at: start)
    // The Mac's upload is delayed until after the phone has watched and uploaded episode 18.
    phone.record("18", at: start.addingTimeInterval(60))
    phone.sync.flush(now: start.addingTimeInterval(90))
    mac.sync.flush(now: start.addingTimeInterval(120))
    phone.sync.flush(now: start.addingTimeInterval(150))
    #expect(mac.history.entries.first?.context.episodeID == "18")
    #expect(phone.history.entries.first?.context.episodeID == "18")
    #expect(PlaybackHistory(file: phone.directory.appending(path: "history.json")).entries.first?.context.episodeID == "18")
}

@Test @MainActor func deliberatelyRewatchingAnEarlierEpisodeStillSyncsWithAClockBehind() {
    let cloud = MemoryCloud(), start = Date(timeIntervalSince1970: 4_000_000)
    let mac = HistoryDevice(cloud), phone = HistoryDevice(cloud)
    defer { mac.clean(); phone.clean() }
    phone.record("18", at: start)
    phone.sync.flush(now: start)
    mac.sync.flush(now: start)
    // Having seen episode 18, the viewer deliberately goes back on a device whose clock is behind.
    mac.record("17", at: start.addingTimeInterval(-60))
    mac.sync.flush(now: start.addingTimeInterval(30))
    phone.sync.flush(now: start.addingTimeInterval(60))
    #expect(phone.history.entries.first?.context.episodeID == "17")
    #expect((phone.history.entries.first?.updatedAt ?? .distantPast) > start)
    // Rewinding within the same episode is also a new viewing event, not a maximum-position merge.
    phone.record("17", position: 20, at: start.addingTimeInterval(90))
    phone.sync.flush(now: start.addingTimeInterval(120))
    mac.sync.flush(now: start.addingTimeInterval(150))
    #expect(mac.history.entries.first?.position == 20)
}

@Test @MainActor func oldUploadTimeStampsDoNotMakeStaleHistoryNewer() throws {
    let cloud = MemoryCloud(), start = Date(timeIntervalSince1970: 4_000_000)
    let mac = HistoryDevice(cloud), phone = HistoryDevice(cloud)
    defer { mac.clean(); phone.clean() }
    mac.record("17", at: start)
    phone.record("18", at: start.addingTimeInterval(60))
    phone.sync.flush(now: start.addingTimeInterval(90))
    // An old app version stamped its delayed upload at upload time rather than viewing time.
    let old = mac.history.entries[0]
    var legacy = CloudSyncLedger<PlaybackHistoryEntry>()
    legacy.note([old.id: old], now: start.addingTimeInterval(120))
    cloud.values["sync.history"] = try #require(CloudSync.encode(legacy))
    phone.sync.flush(now: start.addingTimeInterval(150))
    mac.sync.flush(now: start.addingTimeInterval(180))
    #expect(phone.history.entries.first?.context.episodeID == "18")
    #expect(mac.history.entries.first?.context.episodeID == "18")
}

@Test @MainActor func delayedHistoryDoesNotResurrectARemovedShow() {
    let cloud = MemoryCloud(), start = Date(timeIntervalSince1970: 4_000_000)
    let mac = HistoryDevice(cloud), phone = HistoryDevice(cloud)
    defer { mac.clean(); phone.clean() }
    mac.record("17", at: start)
    phone.record("18", at: start.addingTimeInterval(60))
    phone.sync.flush(now: start.addingTimeInterval(90))
    phone.history.clear()
    phone.sync.flush(now: start.addingTimeInterval(120))
    mac.sync.flush(now: start.addingTimeInterval(150))
    phone.sync.flush(now: start.addingTimeInterval(180))
    #expect(mac.history.entries.isEmpty)
    #expect(phone.history.entries.isEmpty)
    // Deliberate playback after the deletion is still allowed to add the show again.
    mac.record("17", at: start.addingTimeInterval(200))
    mac.sync.flush(now: start.addingTimeInterval(230))
    phone.sync.flush(now: start.addingTimeInterval(260))
    #expect(phone.history.entries.first?.context.episodeID == "17")
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

/// Another profile than the main one is open (#1456): its library neither goes up nor takes the cloud's, and the main
/// library merges once it is back.
@Test @MainActor func suspendedNothingIsSentOrTakenUntilResumed() {
    let cloud = MemoryCloud()
    let phone = Device(cloud, names: ["a": "Alpha"]), tv = Device(cloud, names: ["b": "Beta"])
    tv.sync.flush()
    phone.sync.isSuspended = true
    phone.sync.start()
    phone.sync.flush()
    phone.sync.changed("names")
    phone.sync.receive(reason: nil, keys: ["sync.names"])
    #expect(phone.names == ["a": "Alpha"] && cloud.values["sync.names"].flatMap { CloudSync.decode(CloudSyncLedger<String>.self, from: $0) }?.values == ["b": "Beta"])
    phone.sync.isSuspended = false
    #expect(phone.names == ["a": "Alpha", "b": "Beta"])
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

/// A TV that signs out of one account and into another shows what that account has, never what the first one
/// left on the device (#584).
@Test @MainActor func anotherICloudAccountShowsItsOwnItemsAndKeepsTheOldOnesOut() {
    let cloud = MemoryCloud()
    let tv = Device(cloud, names: ["a": "Alpha"])
    tv.sync.flush(now: Date(timeIntervalSince1970: 1_000_000))
    // The second account already synced a show from another device.
    cloud.values = [:]
    let phone = Device(cloud, names: ["b": "Beta"])
    phone.sync.flush(now: Date(timeIntervalSince1970: 1_000_100))
    tv.sync.receive(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
    #expect(tv.names == ["b": "Beta"])
    let ledger = CloudSync.decode(CloudSyncLedger<String>.self, from: cloud.values["sync.names"] ?? Data())
    #expect(ledger?.records["a"] == nil)
}

/// An account that never synced starts from what the device holds, so switching to it keeps the subscriptions
/// and favorites instead of emptying them.
@Test @MainActor func anICloudAccountThatNeverSyncedStartsWithWhatTheDeviceHolds() {
    let cloud = MemoryCloud()
    let tv = Device(cloud, names: ["a": "Alpha"])
    tv.sync.flush()
    cloud.values = [:]
    tv.sync.receive(reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
    #expect(tv.names == ["a": "Alpha"])
    let ledger = CloudSync.decode(CloudSyncLedger<String>.self, from: cloud.values["sync.names"] ?? Data())
    #expect(ledger?.records["a"]?.value == "Alpha")
}

/// Coming back to the front asks iCloud for what changed while the app was away; what it brings, another
/// account's copy included, merges when the store's notification arrives (#584). Before `start()` nothing
/// happens, so the first merge still waits for the saved subscriptions.
@Test @MainActor func aForegroundRefreshAsksICloudAndTheNotificationMerges() {
    let cloud = MemoryCloud()
    let phone = Device(cloud, names: ["a": "Alpha"])
    phone.sync.flush()
    let tv = Device(cloud)
    tv.sync.refresh()
    #expect(cloud.synchronizations == 0 && tv.names.isEmpty)
    tv.sync.start()
    #expect(cloud.synchronizations == 1 && tv.names == ["a": "Alpha"])
    phone.names["b"] = "Beta"
    phone.sync.flush()
    tv.sync.refresh()
    #expect(cloud.synchronizations == 2 && tv.names == ["a": "Alpha"])
    tv.sync.receive(reason: NSUbiquitousKeyValueStoreServerChange, keys: ["sync.names"])
    #expect(tv.names == ["a": "Alpha", "b": "Beta"])
}

/// An initial sync carries the whole store, not just the keys the notification happened to name.
@Test @MainActor func anInitialSyncMergesEveryKindNotJustTheKeysItNames() {
    let cloud = MemoryCloud()
    let phone = Device(cloud, names: ["a": "Alpha"])
    phone.others = ["c": "Charlie"]
    phone.sync.flush()
    let tv = Device(cloud)
    tv.sync.receive(reason: NSUbiquitousKeyValueStoreInitialSyncChange, keys: ["sync.names"])
    #expect(tv.names == ["a": "Alpha"])
    #expect(tv.others == ["c": "Charlie"])
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
