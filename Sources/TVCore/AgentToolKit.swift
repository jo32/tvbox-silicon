import Foundation

// The pure parts of the assistant's app tools (App/Agent/Tools, Docs/agent.md "Tools"): reading the model's arguments,
// ids that carry no secrets, capped lists, line ranges, find-and-replace and diffs of the viewer's scripts, and a
// timeout. Kept here, apart from the app, so they are tested with the rest of TVCore.

/// The arguments a model sent to a tool, read leniently (a number may arrive as text) but checked: a value of the
/// wrong kind is an `AgentToolError` the model reads, never a silent default.
public struct AgentArguments: Sendable {
    public let values: [String: JSONValue]
    public init(_ values: [String: JSONValue]) { self.values = values }

    /// Whether the model sent `key` at all (null counts as not sent).
    public func has(_ key: String) -> Bool {
        guard let value = values[key] else { return false }
        return value != .null
    }

    /// Trimmed text; nil when missing or empty. Numbers read as their text.
    public func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        switch value {
        case .null: return nil
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number: return value.string
        default: throw AgentToolError("`\(key)` must be text.")
        }
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = try string(key) else { throw AgentToolError("Missing required argument `\(key)`.") }
        return value
    }

    /// Text exactly as sent, whitespace and newlines kept (a script's content).
    public func text(_ key: String) throws -> String? {
        guard let value = values[key], value != .null else { return nil }
        guard case .string(let text) = value else { throw AgentToolError("`\(key)` must be text.") }
        return text
    }

    public func int(_ key: String) throws -> Int? {
        guard let value = values[key], value != .null else { return nil }
        switch value {
        case .number(let number) where number.rounded() == number && abs(number) < 1e12: return Int(number)
        case .string(let text):
            if let number = Int(text.trimmingCharacters(in: .whitespaces)) { return number }
        default: break
        }
        throw AgentToolError("`\(key)` must be a whole number.")
    }

    /// A whole number in `range`, or `fallback` when missing.
    public func int(_ key: String, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        let value = try int(key) ?? fallback
        guard range.contains(value) else {
            throw AgentToolError("`\(key)` must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    public func double(_ key: String) throws -> Double? {
        guard let value = values[key], value != .null else { return nil }
        switch value {
        case .number(let number) where number.isFinite: return number
        case .string(let text):
            if let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite { return number }
        default: break
        }
        throw AgentToolError("`\(key)` must be a number.")
    }

    public func bool(_ key: String) throws -> Bool? {
        guard let value = values[key], value != .null else { return nil }
        if let flag = Self.flag(value) { return flag }
        throw AgentToolError("`\(key)` must be true or false.")
    }

    /// true/false, also as text ("on", "off", "yes", "no") or 1/0.
    public static func flag(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let number) where number == 0 || number == 1: return number == 1
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// A list of texts; one text alone counts as a list of one.
    public func strings(_ key: String) throws -> [String]? {
        guard let value = values[key], value != .null else { return nil }
        switch value {
        case .array(let items):
            return try items.map { item in
                guard let text = item.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw AgentToolError("`\(key)` must be a list of texts.")
                }
                return text
            }
        case .string, .number: return try string(key).map { [$0] } ?? []
        default: throw AgentToolError("`\(key)` must be a list of texts.")
        }
    }

    /// One of `allowed`, compared without case; nil when missing.
    public func choice(_ key: String, _ allowed: [String]) throws -> String? {
        guard let value = try string(key) else { return nil }
        guard let match = allowed.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            throw AgentToolError("`\(key)` must be one of: \(allowed.joined(separator: ", ")).")
        }
        return match
    }

    /// A time as seconds: a number, or text like "90", "1:30" or "1:02:03".
    public func seconds(_ key: String) throws -> Double? {
        guard let value = values[key], value != .null else { return nil }
        if case .number(let number) = value, number.isFinite { return number }
        if let text = value.string, let seconds = Self.seconds(text) { return seconds }
        throw AgentToolError("`\(key)` must be seconds, or a time like 1:30 or 1:02:03.")
    }

    public static func seconds(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let negative = trimmed.hasPrefix("-")
        let body = negative || trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let number = Double(part), number >= 0, number.isFinite else { return nil }
            // Minutes and seconds after the first part stay under 60.
            if index > 0, number >= 60 { return nil }
            total = total * 60 + number
        }
        return negative ? -total : total
    }

    /// Keys the model sent that the tool doesn't take, so a misspelled one is reported instead of ignored.
    public func unknownKeys(_ allowed: Set<String>) -> [String] { values.keys.filter { !allowed.contains($0) }.sorted() }
}

public enum AgentToolKit {
    /// The first `limit` items, and how many were left out.
    public static func capped<T>(_ items: [T], limit: Int) -> (items: [T], more: Int) {
        let limit = max(0, limit)
        return (Array(items.prefix(limit)), max(0, items.count - limit))
    }

    /// A short, stable digest of text that must not be shown (an address that may carry a token), for ids:
    /// FNV-1a, 64 bits, as 16 hex digits. The same on every device and launch.
    public static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// An id the model passes back to another tool: `prefix_` and the parts, as base64url JSON. It names what a
    /// tool needs to find the thing again, so it still works after the app restarts.
    public static func encodeID(_ prefix: String, _ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        let text = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return prefix + "_" + text
    }

    /// The parts of an `encodeID` id with this prefix, exactly `count` of them.
    public static func decodeID(_ id: String, prefix: String, count: Int) throws -> [String] {
        let wrong = AgentToolError("`\(id)` is not a valid id here. Use an id a tool returned.")
        guard id.hasPrefix(prefix + "_") else { throw wrong }
        var text = String(id.dropFirst(prefix.count + 1)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let parts = try? JSONDecoder().decode([String].self, from: data),
              parts.count == count else { throw wrong }
        return parts
    }

    /// `text` cut to `limit` characters, ending in "…" when cut.
    public static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(max(0, limit - 1))) + "…"
    }

    /// Runs `operation`, giving up after `seconds` with an `AgentToolError`, even when the operation doesn't stop
    /// when cancelled (a plugin call): the answer then comes back at once and the operation is left to finish.
    public static func withTimeout<T: Sendable>(_ seconds: Double, _ what: String = "The request",
                                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation)
                let work = Task { do { race.finish(.success(try await operation())) } catch { race.finish(.failure(error)) } }
                race.work = work
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    if race.finish(.failure(AgentToolError("\(what) timed out after \(Int(seconds.rounded())) seconds."))) { work.cancel() }
                }
            }
        } onCancel: {
            if race.finish(.failure(CancellationError())) { race.work?.cancel() }
        }
    }

    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var done = false
        var work: Task<Void, Never>? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
        private var stored: Task<Void, Never>?
        func start(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if let early { lock.unlock(); continuation.resume(with: early); return }
            self.continuation = continuation
            lock.unlock()
        }
        /// True for the first result, which is the answer.
        @discardableResult func finish(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            guard !done else { lock.unlock(); return false }
            done = true
            guard let continuation else { early = result; lock.unlock(); return true }
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return true
        }
    }
}

/// The viewer's own scripts as the assistant reads and edits them.
public enum AgentScriptText {
    public struct Excerpt: Equatable, Sendable {
        /// The lines, each as `<number>| <line>`.
        public let text: String
        public let first: Int
        public let last: Int
        public let total: Int
        /// Lines after `last` were left out to keep the answer small; `last + 1` reads on.
        public let truncated: Bool
    }

    public static func lines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Lines `from` through `to` (1-based, inclusive), numbered, at most `maxLines` lines and about `maxBytes` bytes.
    public static func excerpt(_ text: String, from: Int?, to: Int?, maxLines: Int = 200, maxBytes: Int = 6_000) throws -> Excerpt {
        let all = lines(text)
        let total = text.isEmpty ? 0 : all.count
        guard total > 0 else { return Excerpt(text: "", first: 0, last: 0, total: 0, truncated: false) }
        let first = from ?? 1
        guard first >= 1, first <= total else { throw AgentToolError("`start_line` must be between 1 and \(total).") }
        let wanted = min(to ?? total, total)
        guard wanted >= first else { throw AgentToolError("`end_line` must not be before `start_line`.") }
        let width = String(total).count
        var output: [String] = [], bytes = 0, last = first - 1
        for number in first...wanted {
            let line = String(all[number - 1])
            let shown = line.count > 400 ? String(line.prefix(399)) + "…" : line
            let row = String(repeating: " ", count: width - String(number).count) + "\(number)| " + shown
            if output.count >= maxLines || (bytes + row.utf8.count > maxBytes && !output.isEmpty) { break }
            output.append(row); bytes += row.utf8.count + 1; last = number
        }
        return Excerpt(text: output.joined(separator: "\n"), first: first, last: last, total: total, truncated: last < wanted)
    }

    /// Replaces `find` with `replacement`. With `expected`, exactly that many occurrences must be there; without, it
    /// must occur exactly once, so a patch never lands in the wrong place.
    public static func replacing(_ find: String, with replacement: String, in text: String, expected: Int? = nil) throws -> (text: String, count: Int) {
        guard !find.isEmpty else { throw AgentToolError("`find` must not be empty.") }
        let count = text.components(separatedBy: find).count - 1
        guard count > 0 else { throw AgentToolError("`find` doesn't occur in the script. Read the lines again and copy them exactly.") }
        if let expected {
            guard count == expected else { throw AgentToolError("`find` occurs \(count) times, not \(expected).") }
        } else if count != 1 {
            throw AgentToolError("`find` occurs \(count) times. Add surrounding lines to make it unique, or pass `occurrences`.")
        }
        return (text.replacingOccurrences(of: find, with: replacement), count)
    }

    /// A unified diff of two versions of `name`, with `context` lines around each change, at most `maxLines` lines.
    public static func unifiedDiff(old: String, new: String, name: String, context: Int = 3, maxLines: Int = 160) -> String {
        let a = lines(old).map(String.init), b = lines(new).map(String.init)
        let operations = diff(a, b)
        guard operations.contains(where: { if case .same = $0 { return false } else { return true } }) else { return "" }
        // Each operation's line numbers in the old and the new text.
        var rows: [(op: Operation, old: Int, new: Int)] = []
        var i = 0, j = 0
        for op in operations {
            rows.append((op, i, j))
            switch op {
            case .same: i += 1; j += 1
            case .removed: i += 1
            case .added: j += 1
            }
        }
        // Changes closer than twice the context share a hunk.
        let changes = rows.indices.filter { if case .same = rows[$0].op { return false } else { return true } }
        var groups: [(first: Int, last: Int)] = []
        for change in changes {
            if let last = groups.last, change - last.last <= context * 2 + 1 { groups[groups.count - 1].last = change }
            else { groups.append((change, change)) }
        }
        var output = ["--- \(name)", "+++ \(name)"]
        for group in groups {
            let start = max(0, group.first - context), stop = min(rows.count - 1, group.last + context)
            let hunk = rows[start...stop]
            let oldCount = hunk.filter { if case .added = $0.op { return false } else { return true } }.count
            let newCount = hunk.filter { if case .removed = $0.op { return false } else { return true } }.count
            output.append("@@ -\(hunk.first!.old + (oldCount == 0 ? 0 : 1)),\(oldCount) +\(hunk.first!.new + (newCount == 0 ? 0 : 1)),\(newCount) @@")
            for row in hunk {
                switch row.op {
                case .same(let line): output.append(" " + line)
                case .removed(let line): output.append("-" + line)
                case .added(let line): output.append("+" + line)
                }
            }
        }
        if output.count > maxLines {
            let left = output.count - maxLines
            output = Array(output.prefix(maxLines)) + ["… \(left) more lines"]
        }
        return output.joined(separator: "\n")
    }

    enum Operation: Equatable { case same(String), removed(String), added(String) }

    /// A shortest line diff: the common start and end are kept, and the middle is matched by longest common
    /// subsequence when it is small enough; a larger middle reads as removed, then added.
    static func diff(_ a: [String], _ b: [String]) -> [Operation] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let x = Array(a[prefix..<(a.count - suffix)]), y = Array(b[prefix..<(b.count - suffix)])
        var middle: [Operation] = []
        if x.count * y.count > 4_000_000 {
            middle = x.map(Operation.removed) + y.map(Operation.added)
        } else if !x.isEmpty || !y.isEmpty {
            let width = y.count + 1
            var table = [Int32](repeating: 0, count: (x.count + 1) * width)
            for i in stride(from: x.count - 1, through: 0, by: -1) {
                for j in stride(from: y.count - 1, through: 0, by: -1) {
                    table[i * width + j] = x[i] == y[j] ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
            var i = 0, j = 0
            while i < x.count || j < y.count {
                if i < x.count, j < y.count, x[i] == y[j] { middle.append(.same(x[i])); i += 1; j += 1 }
                else if i < x.count, j == y.count || table[(i + 1) * width + j] >= table[i * width + j + 1] { middle.append(.removed(x[i])); i += 1 }
                else { middle.append(.added(y[j])); j += 1 }
            }
        }
        return a[..<prefix].map(Operation.same) + middle + a[(a.count - suffix)...].map(Operation.same)
    }
}
