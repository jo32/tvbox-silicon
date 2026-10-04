import Foundation

public enum LogLevel: String, CaseIterable, Codable, Sendable {
    case debug, info, warning, error
}

public struct LogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let category: String
    public let message: String
}

public struct LogSnapshot: Sendable {
    public let entries: [LogEntry]
    public let dropped: Int
    public let fileError: String?
}

/// Producers only take a short lock to append bounded records. Formatting and all
/// disk operations belong to the utility queue. At most one drain is scheduled.
public final class Diagnostics: @unchecked Sendable {
    public static let shared = Diagnostics()
    public let directory: URL
    private let queue = DispatchQueue(label: "tvbox.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var pending: [LogEntry] = []
    private var scheduled = false
    private var dropped = 0
    private let capacity: Int
    private let fileLimit: Int
    private let fileCount: Int
    // Queue-owned state below.
    private var reportedDropped = 0
    private var recent: [LogEntry] = []
    private var handle: FileHandle?
    private var size = 0
    private var fileError: String?
    private var retryAfter = Date.distantPast
    private let encoder = JSONEncoder()

    public init(directory: URL? = nil, capacity: Int = 512, fileLimit: Int = 2_000_000, fileCount: Int = 4) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tvbox.yingxia/Logs", isDirectory: true)
        self.capacity = max(1, capacity)
        self.fileLimit = max(16_384, fileLimit)
        self.fileCount = max(1, fileCount)
    }

    public func record(_ level: LogLevel = .info, _ category: String, _ message: String) {
        // Bound producer work even when a plugin emits an enormous line.
        let entry = LogEntry(id: UUID(), date: Date(), level: level,
                             category: String(category.prefix(80)), message: String(message.prefix(2048)))
        lock.lock()
        if pending.count < capacity { pending.append(entry) }
        else {
            dropped += 1
            if (level == .error || level == .warning), let index = pending.firstIndex(where: { $0.level == .debug || $0.level == .info }) {
                pending.remove(at: index); pending.append(entry)
            }
        }
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + .milliseconds(250)) { self.drain() } }
    }

    public func snapshot() async -> LogSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.drain()
                self.lock.lock(); let count = self.dropped; self.lock.unlock()
                continuation.resume(returning: LogSnapshot(entries: self.recent, dropped: count, fileError: self.fileError))
            }
        }
    }

    /// A stable copy, made off the UI thread; includes retained previous runs.
    public func export() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.drain()
                    if let error = self.fileError { throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: error]) }
                    let url = self.directory.appendingPathComponent("diagnostics-export.jsonl")
                    var data = Data()
                    for index in (0..<self.fileCount).reversed() {
                        let file = self.file(index)
                        if FileManager.default.fileExists(atPath: file.path) { data.append(try Data(contentsOf: file)) }
                    }
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: url)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func file(_ index: Int) -> URL { directory.appendingPathComponent("runtime-\(index).jsonl") }

    private func drain() {
        lock.lock()
        var batch = pending; pending.removeAll(keepingCapacity: true); scheduled = false
        let lost = dropped
        lock.unlock()
        if lost > reportedDropped {
            batch.append(LogEntry(id: UUID(), date: Date(), level: .warning, category: "logging", message: "Overload dropped \(lost - reportedDropped) events; total=\(lost)"))
            reportedDropped = lost
        }
        guard !batch.isEmpty else { return }
        let safe = batch.map { LogEntry(id: $0.id, date: $0.date, level: $0.level, category: Self.redact($0.category), message: Self.redact($0.message)) }
        recent.append(contentsOf: safe)
        if recent.count > 1000 { recent.removeFirst(recent.count - 1000) }
        guard Date() >= retryAfter else { return }
        do {
            try openFile()
            var buffer = Data()
            for entry in safe {
                var line = try encoder.encode(entry); line.append(10)
                if size + buffer.count + line.count > fileLimit {
                    try handle?.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true)
                    try rotate()
                }
                buffer.append(line)
            }
            try handle?.write(contentsOf: buffer); size += buffer.count
            fileError = nil
        } catch {
            try? handle?.close(); handle = nil
            fileError = Self.redact(error.localizedDescription)
            retryAfter = Date().addingTimeInterval(30)
        }
    }

    private func openFile() throws {
        guard handle == nil else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = file(0)
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        handle = try FileHandle(forWritingTo: url)
        size = Int(try handle!.seekToEnd())
    }

    private func rotate() throws {
        try handle?.close(); handle = nil
        let manager = FileManager.default
        if manager.fileExists(atPath: file(fileCount - 1).path) { try manager.removeItem(at: file(fileCount - 1)) }
        if fileCount > 1 {
            for index in stride(from: fileCount - 2, through: 0, by: -1) where manager.fileExists(atPath: file(index).path) {
                try manager.moveItem(at: file(index), to: file(index + 1))
            }
        }
        try openFile()
    }

    // Raw plugin output is untrusted. Strip URL credentials/query and common
    // authorization headers before either the viewer or disk sees the text.
    private static let patterns: [(NSRegularExpression, String)] = [
        (#"(?i)(https?://)[^\s/@]+:[^\s/@]+@"#, "$1[redacted]@"),
        (#"(?i)(https?://[^\s?#]+)[?#][^\s]*"#, "$1?[redacted]"),
        (#"(?im)\b(authorization|cookie|set-cookie|token|password|secret|api[_-]?key)\b[\"\s]*[:=][^\r\n]*"#, "$1=[redacted]")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        patterns.reduce(text) { result, rule in
            rule.0.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.1)
        }
    }

    deinit { try? handle?.close() }
}

/// Reassembles pipe fragments before redaction, with a bounded partial line.
/// Oversized lines are truncated and their remaining bytes discarded until LF.
final class DiagnosticOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private var truncated = false
    private let context: String
    private let logger: Diagnostics
    init(context: String, logger: Diagnostics = .shared) { self.context = context; self.logger = logger }

    func accept(_ data: Data, end: Bool = false) {
        lock.lock()
        for byte in data {
            if byte == 10 { emit() }
            else if partial.count < 1800 { partial.append(byte) }
            else { truncated = true }
        }
        if end { emit() }
        lock.unlock()
    }
    private func emit() {
        guard !partial.isEmpty || truncated else { return }
        logger.record(.debug, "jar.output", "\(context) " + String(decoding: partial, as: UTF8.self) + (truncated ? " [truncated]" : ""))
        partial.removeAll(keepingCapacity: true); truncated = false
    }
}
