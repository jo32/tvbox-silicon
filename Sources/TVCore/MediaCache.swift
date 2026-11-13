import Foundation
import CryptoKit

/// Disposable data only. History, subscriptions, pins and skip settings never live here.
/// A ticket prevents a download started before deletion from recreating deleted data.
public final class MediaCache: @unchecked Sendable {
    public static let shared = MediaCache()
    public enum Kind: String, Codable, Sendable { case artwork, danmaku, lookup, catalog }
    public struct Ticket: Sendable { fileprivate let generation: UInt64 }
    public struct Summary: Sendable {
        public let bytes: Int
        public let artwork: Int
        public let danmaku: Int
        public let lookups: Int
        public let catalogs: Int
    }
    private struct Entry: Codable {
        let kind: Kind
        let scope: String
        let bytes: Int
        let expires: Date
        var used: Date
    }
    private let lock = NSLock()
    private let root: URL
    private let budget: Int
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var frequentScopes = Set<String>()
    public func prioritize(_ scopes: Set<String>) { lock.withLock { frequentScopes = scopes } }
    public var revision: UInt64 { lock.withLock { generation } }

    public init(root: URL = URL.cachesDirectory.appending(path: "YingxiaMedia-v1"), budget: Int = 256 * 1024 * 1024) {
        self.root = root; self.budget = max(0, budget)
        if let data = try? Data(contentsOf: root.appending(path: "index.json")), data.count <= 4 * 1024 * 1024,
           let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = loaded.filter { $0.key.count == 64 && $0.key.allSatisfy { $0.isHexDigit } && $0.value.bytes >= 0 }
        }
        lock.withLock { prune(now: Date()); persist() }
    }
    public func ticket() -> Ticket { lock.withLock { Ticket(generation: generation) } }
    private func id(_ key: String, _ kind: Kind, _ scope: String) -> String {
        let data = (try? JSONEncoder().encode([kind.rawValue, scope, key])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func data(for key: String, kind: Kind, scope: String = "", now: Date = Date()) -> Data? {
        lock.withLock {
            let key = id(key, kind, scope)
            guard var entry = entries[key] else { return nil }
            guard entry.expires > now, let data = try? Data(contentsOf: root.appending(path: key)), data.count == entry.bytes else {
                erase(key); persist(); return nil
            }
            let needsSave = now.timeIntervalSince(entry.used) > 60
            entry.used = now; entries[key] = entry
            if needsSave { persist() }
            return data
        }
    }
    @discardableResult public func store(_ data: Data, for key: String, kind: Kind, scope: String = "",
                                         ttl: TimeInterval, ticket: Ticket, now: Date = Date()) -> Bool {
        lock.withLock {
            guard ticket.generation == generation, !data.isEmpty, data.count <= min(budget, 8 * 1024 * 1024), ttl > 0 else { return false }
            let key = id(key, kind, scope)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appending(path: key), options: .atomic)
                entries[key] = Entry(kind: kind, scope: scope, bytes: data.count, expires: now.addingTimeInterval(ttl), used: now)
                prune(now: now); persist()
                return entries[key] != nil
            } catch { return false } // Cache failures never prevent playback.
        }
    }
    public func remove(scope: String) {
        lock.withLock {
            generation &+= 1
            for key in entries.keys.filter({ entries[$0]?.scope == scope }) { erase(key) }
            persist()
        }
    }
    /// Remove one category in a work's scope, invalidating downloads started before the deletion.
    public func remove(kind: Kind, scope: String) {
        lock.withLock {
            generation &+= 1
            for key in entries.keys.filter({ entries[$0]?.scope == scope && entries[$0]?.kind == kind }) { erase(key) }
            persist()
        }
    }
    public func remove(_ key: String, kind: Kind, scope: String = "") {
        lock.withLock { generation &+= 1; erase(id(key, kind, scope)); persist() }
    }
    public func clear() {
        lock.withLock {
            generation &+= 1; entries.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }
    public func summary(now: Date = Date()) -> Summary {
        lock.withLock {
            prune(now: now); persist()
            return Summary(bytes: entries.values.reduce(0) { $0 + $1.bytes }, artwork: entries.values.filter { $0.kind == .artwork }.count,
                           danmaku: entries.values.filter { $0.kind == .danmaku }.count, lookups: entries.values.filter { $0.kind == .lookup }.count,
                           catalogs: entries.values.filter { $0.kind == .catalog }.count)
        }
    }
    private func erase(_ key: String) { entries[key] = nil; try? FileManager.default.removeItem(at: root.appending(path: key)) }
    private func prune(now: Date) {
        for key in entries.keys.filter({ entries[$0]!.expires <= now }) { erase(key) }
        // Lookup scope is a work, not an episode. Retain only the last 20 successful work mappings.
        let lookups = entries.filter { $0.value.kind == .lookup }.sorted { $0.value.used > $1.value.used }
        for (key, _) in lookups.dropFirst(20) { erase(key) }
        var size = entries.values.reduce(0) { $0 + $1.bytes }
        let evictionOrder = entries.sorted {
            let left = frequentScopes.contains($0.value.scope), right = frequentScopes.contains($1.value.scope)
            return left == right ? $0.value.used < $1.value.used : !left
        }
        for (key, entry) in evictionOrder where size > budget {
            size -= entry.bytes; erase(key)
        }
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appending(path: "index.json"), options: .atomic)
    }
}
