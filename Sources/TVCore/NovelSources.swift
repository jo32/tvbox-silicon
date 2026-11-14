import Foundation

/// A subscribed Legado book source file: one address that lists many sources.
public struct NovelSourceList: Codable, Hashable, Sendable, Identifiable {
    public var address: URL
    public var count: Int
    public var updated: Date
    public var id: URL { address }
}

/// The Legado book source lists the viewer subscribed to, their sources, and which sources are switched on.
/// A list is added like any subscription (Add Subscription detects it) and feeds the Novels section.
public final class NovelSources: @unchecked Sendable {
    public static let shared = NovelSources()
    /// Posted on the main queue when lists or switches change.
    public static let changedNotification = Notification.Name("NovelSources.changed")

    private let lock = NSLock()
    private var listed: [NovelSourceList]
    private var sourcesByList: [URL: [NovelSource]] = [:]
    /// The viewer's own on/off choices, over the list's `enabled`.
    private var switches: [String: Bool]
    /// Lists a page of lists offered (see `NovelSourceIndex`), for Book Sources to add one by one.
    private var offered: [NovelSourceOffer]
    private static var listsFile: URL { NovelLibrary.root.appendingPathComponent("lists.json") }
    private static var switchesFile: URL { NovelLibrary.root.appendingPathComponent("switches.json") }
    private static var offersFile: URL { NovelLibrary.root.appendingPathComponent("offers.json") }
    private static var folder: URL { NovelLibrary.root.appendingPathComponent("Lists", isDirectory: true) }
    private static func file(_ url: URL) -> URL { folder.appendingPathComponent(PluginChecksum.sha256(Data(url.absoluteString.utf8)) + ".json") }

    init() {
        listed = (try? JSONDecoder().decode([NovelSourceList].self, from: Data(contentsOf: Self.listsFile))) ?? []
        switches = (try? JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: Self.switchesFile))) ?? [:]
        offered = (try? JSONDecoder().decode([NovelSourceOffer].self, from: Data(contentsOf: Self.offersFile))) ?? []
        // A complete list is 20 MB of JSON and takes a second or more to read on Apple TV, so the saved lists load off
        // the main thread; views fill in on `changedNotification`, and lookups that need a source wait (`loaded()`).
        let saved = listed.map(\.address)
        loading = Task.detached(priority: .userInitiated) { [weak self] in
            var read: [URL: [NovelSource]] = [:]
            for address in saved {
                if let data = try? Data(contentsOf: Self.file(address)) { read[address] = NovelSource.list(from: data) ?? [] }
            }
            guard let self else { return }
            self.lock.withLock {
                // A list added meanwhile is newer; a list removed meanwhile stays removed.
                for (address, sources) in read where self.sourcesByList[address] == nil && self.listed.contains(where: { $0.address == address }) {
                    self.sourcesByList[address] = sources
                }
            }
            if !read.isEmpty { self.changed() }
        }
    }

    private var loading: Task<Void, Never>?
    /// Returns once the saved lists are read.
    public func loaded() async { await loading?.value }

    public var lists: [NovelSourceList] { lock.withLock { listed } }
    public var isEmpty: Bool { lock.withLock { listed.isEmpty } }

    /// Every source of every list, in list order; a key listed twice keeps its first copy.
    public var all: [NovelSource] {
        lock.withLock {
            var seen = Set<String>()
            return listed.flatMap { sourcesByList[$0.address] ?? [] }.filter { seen.insert($0.key).inserted }
        }
    }
    public func sources(in list: URL) -> [NovelSource] { lock.withLock { sourcesByList[list] ?? [] } }
    public var enabled: [NovelSource] { all.filter(isEnabled) }
    public func source(_ key: String) -> NovelSource? { all.first { $0.key == key } }

    public func isEnabled(_ source: NovelSource) -> Bool { lock.withLock { switches[source.key] ?? !source.disabledByList } }
    public func setEnabled(_ enabled: Bool, for keys: [String]) {
        lock.withLock {
            for key in keys { switches[key] = enabled }
            save()
        }
        changed()
    }

    // MARK: Lists

    /// Adds (or replaces) a list from data already downloaded from `address`. Throws when it isn't one.
    @discardableResult
    public func add(_ address: URL, data: Data) throws -> NovelSourceList {
        guard let sources = NovelSource.list(from: data), !sources.isEmpty else {
            throw TVError.unsupported(L10n.text("This address is not a Legado book source list."))
        }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try data.write(to: Self.file(address), options: .atomic)
        let list = NovelSourceList(address: address, count: sources.count, updated: Date())
        lock.withLock {
            sourcesByList[address] = sources
            if let index = listed.firstIndex(where: { $0.address == address }) { listed[index] = list } else { listed.append(list) }
            save()
        }
        changed()
        Diagnostics.shared.record(.info, "novel.list", "host=\(address.host() ?? "-") sources=\(sources.count)")
        return list
    }

    /// The lists the last page of lists offered; adding a list leaves it here, shown as added.
    public var offers: [NovelSourceOffer] { lock.withLock { offered } }
    /// Replaces the offered lists (an empty array clears them).
    public func offer(_ offers: [NovelSourceOffer]) {
        lock.withLock { offered = offers; save() }
        changed()
    }

    /// Downloads a list again.
    @discardableResult
    public func refresh(_ address: URL) async throws -> NovelSourceList {
        let (data, _) = try await HTTPClient().get(address, headers: ["User-Agent": HTTPClient.subscriptionUserAgent], limit: HTTPClient.subscriptionLimit)
        return try add(address, data: data)
    }

    public func remove(_ address: URL) {
        lock.withLock {
            listed.removeAll { $0.address == address }
            sourcesByList[address] = nil
            save()
        }
        try? FileManager.default.removeItem(at: Self.file(address))
        changed()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: NovelLibrary.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(listed) { try? data.write(to: Self.listsFile, options: .atomic) }
        if let data = try? JSONEncoder().encode(switches) { try? data.write(to: Self.switchesFile, options: .atomic) }
        if let data = try? JSONEncoder().encode(offered) { try? data.write(to: Self.offersFile, options: .atomic) }
    }

    private func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
    }

    /// A list's name for rows: its file name, or its host.
    public static func title(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if !name.isEmpty, name != "/", name.count <= 40 { return (url.host().map { $0 + " · " } ?? "") + name }
        return url.host() ?? url.absoluteString
    }

    /// The address a Legado import link carries (`legado://import/bookSource?src=…`, `yuedu://booksource/importonline?src=…`),
    /// or nil when `url` isn't one.
    public static func importAddress(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "legado" || scheme == "yuedu",
              let src = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "src" })?.value else { return nil }
        return URL(string: src)
    }
}
