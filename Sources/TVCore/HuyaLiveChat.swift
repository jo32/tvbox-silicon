import Foundation

/// A Huya room's bullet comments as they are sent, from Huya's chat WebSocket. Anyone may listen.
///
/// Messages are Tars-encoded `WebSocketCommand`s: the command type (tag 0) and its payload (tag 1).
/// The client registers (type 1) with the streamer's yyid and the room's channel ids, which the room's
/// profile gives, and sends a fixed heartbeat every 60 seconds. Pushes (type 7) carry a URI and a
/// message; URI 1400 is a comment: its sender (tag 0), text (tag 3) and format (tag 6, colour at 0).
public final class HuyaLiveChat: LiveChat, @unchecked Sendable {
    private let room: String
    private let link = LiveChatLink()
    private let lock = NSLock()
    private var handler: LiveChatHandler?

    public init(room: String) { self.room = room }

    public func start(_ handler: @escaping LiveChatHandler) {
        lock.withLock { self.handler = handler }
        Task {
            guard let ids = await Self.ids(room: room) else {
                Diagnostics.shared.record(.warning, "live.chat", "huya room=\(room) no chat ids")
                return
            }
            var request = URLRequest(url: URL(string: "wss://cdnws.api.huya.com/")!)
            request.setValue(LiveHTTP.desktopAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.huya.com", forHTTPHeaderField: "Origin")
            Diagnostics.shared.record(.info, "live.chat", "huya room=\(room) connecting")
            await link.open(request, greeting: [Self.register(yyid: ids.yyid, channel: ids.channel, subchannel: ids.subchannel)],
                            heartbeat: Self.heartbeat, every: .seconds(60)) { [weak self] in self?.read($0) }
        }
    }

    public func stop() {
        lock.withLock { handler = nil }
        link.close()
    }

    /// The streamer's yyid and the room's channel ids, from the room's profile.
    static func ids(room: String) async -> (yyid: Int64, channel: Int64, subchannel: Int64)? {
        let url = LiveHTTP.url("https://mp.huya.com/cache.php", [("m", "Live"), ("do", "profileRoom"), ("roomid", room)])
        guard let reply = try? await LiveHTTP.json(url), let data = reply["data"]?.object,
              let profile = data["profileInfo"]?.object, let yyid = profile["yyid"]?.int, yyid > 0 else { return nil }
        let stream = data["stream"]?.object?["baseSteamInfoList"]?.array?.first?.object
        // A room's channel ids are the streamer's uid when its stream doesn't list them.
        let uid = profile["uid"]?.int ?? 0
        let channel = stream?["lChannelId"]?.int ?? uid, subchannel = stream?["lSubChannelId"]?.int ?? uid
        guard channel > 0 else { return nil }
        return (Int64(yyid), Int64(channel), Int64(subchannel))
    }

    /// The registration: a `WSUserInfo` (yyid, anonymous, no token, the channel ids) as command type 1.
    static func register(yyid: Int64, channel: Int64, subchannel: Int64) -> Data {
        var user = TarsWriter()
        user.int(yyid, tag: 0); user.int(1, tag: 1); user.string("", tag: 2); user.string("", tag: 3)
        user.int(channel, tag: 4); user.int(subchannel, tag: 5); user.int(0, tag: 6); user.int(0, tag: 7)
        var command = TarsWriter()
        command.int(1, tag: 0); command.bytes(user.data, tag: 1)
        return command.data
    }

    static let heartbeat = Data(base64Encoded: "ABQdAAwsNgBM")!

    /// A message's comment, if it is one: its text and colour.
    static func comment(_ data: Data) -> (text: String, color: UInt32)? {
        var reader = TarsReader(data)
        guard let command = reader.fields(), command[0]?.int == 7, let pushed = command[1]?.data else { return nil }
        var pushReader = TarsReader(pushed)
        guard let push = pushReader.fields(), push[1]?.int == 1400, let body = push[2]?.data else { return nil }
        var noticeReader = TarsReader(body)
        guard let notice = noticeReader.fields(), let text = notice[3]?.string, !text.isEmpty else { return nil }
        let color = notice[6]?.fields?[0]?.int ?? -1
        return (text, color > 0 ? UInt32(truncatingIfNeeded: color) & 0xFFFFFF : 0xFFFFFF)
    }

    private func read(_ data: Data) {
        guard let (text, color) = Self.comment(data) else { return }
        lock.withLock { handler }?(text, color, .scroll)
    }
}

/// Writes Tars (Tencent's binary encoding) fields: each a head byte (tag in the high four bits, type in
/// the low four; tags from 15 take a second byte) and the value, numbers big-endian in their smallest size.
struct TarsWriter {
    private(set) var data = Data()

    private mutating func head(_ tag: Int, _ type: UInt8) {
        if tag < 15 { data.append(UInt8(tag) << 4 | type) } else { data.append(0xF0 | type); data.append(UInt8(tag)) }
    }
    private mutating func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }

    mutating func int(_ value: Int64, tag: Int) {
        if value == 0 { head(tag, 12) }
        else if let small = Int8(exactly: value) { head(tag, 0); append(small) }
        else if let small = Int16(exactly: value) { head(tag, 1); append(small) }
        else if let small = Int32(exactly: value) { head(tag, 2); append(small) }
        else { head(tag, 3); append(value) }
    }

    mutating func string(_ value: String, tag: Int) {
        let bytes = Data(value.utf8)
        if bytes.count < 256 { head(tag, 6); data.append(UInt8(bytes.count)) } else { head(tag, 7); append(UInt32(bytes.count)) }
        data.append(bytes)
    }

    /// A byte array: Tars's "simple list".
    mutating func bytes(_ value: Data, tag: Int) {
        head(tag, 13); head(0, 0); int(Int64(value.count), tag: 0)
        data.append(value)
    }
}

/// A Tars value as read: strings and byte arrays both stay bytes until asked for.
indirect enum TarsValue {
    case int(Int64), double(Double), bytes(Data), fields([Int: TarsValue]), list([TarsValue]), map([(TarsValue, TarsValue)])

    var int: Int64? { if case .int(let value) = self { value } else { nil } }
    var data: Data? { if case .bytes(let value) = self { value } else { nil } }
    var string: String? { data.map { String(decoding: $0, as: UTF8.self) } }
    var fields: [Int: TarsValue]? { if case .fields(let value) = self { value } else { nil } }
}

/// Reads Tars fields by tag, whatever their structure, so unknown fields are skipped rather than misread.
struct TarsReader {
    private let bytes: [UInt8]
    private var cursor = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    /// The fields up to the end of the struct (or of the data); nil when the data is cut short or malformed.
    mutating func fields() -> [Int: TarsValue]? {
        var result: [Int: TarsValue] = [:]
        while cursor < bytes.count {
            guard let (tag, type) = head() else { return nil }
            if type == 11 { break }
            guard let value = value(type) else { return nil }
            result[tag] = value
        }
        return result
    }

    private mutating func head() -> (tag: Int, type: UInt8)? {
        guard cursor < bytes.count else { return nil }
        let byte = bytes[cursor]
        cursor += 1
        var tag = Int(byte >> 4)
        if tag == 15 {
            guard cursor < bytes.count else { return nil }
            tag = Int(bytes[cursor]); cursor += 1
        }
        return (tag, byte & 0x0F)
    }

    private mutating func unsigned(_ size: Int) -> UInt64? {
        guard size <= 8, cursor + size <= bytes.count else { return nil }
        defer { cursor += size }
        return bytes[cursor..<(cursor + size)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func signed(_ size: Int) -> Int64? {
        unsigned(size).map { value in
            let shift = UInt64(64 - size * 8)
            return Int64(bitPattern: value << shift) >> Int64(shift)
        }
    }

    private mutating func take(_ count: Int) -> Data? {
        guard count >= 0, cursor + count <= bytes.count else { return nil }
        defer { cursor += count }
        return Data(bytes[cursor..<(cursor + count)])
    }

    /// A length or count: an integer field of its own.
    private mutating func count() -> Int? {
        guard let (_, type) = head(), let count = value(type)?.int, count >= 0, count <= bytes.count else { return nil }
        return Int(count)
    }

    private mutating func value(_ type: UInt8) -> TarsValue? {
        switch type {
        case 0: return signed(1).map(TarsValue.int)
        case 1: return signed(2).map(TarsValue.int)
        case 2: return signed(4).map(TarsValue.int)
        case 3: return signed(8).map(TarsValue.int)
        case 4: return unsigned(4).map { .double(Double(Float(bitPattern: UInt32($0)))) }
        case 5: return unsigned(8).map { .double(Double(bitPattern: $0)) }
        case 6: return unsigned(1).flatMap { take(Int($0)) }.map(TarsValue.bytes)
        case 7: return unsigned(4).flatMap { take(Int($0)) }.map(TarsValue.bytes)
        case 8:
            guard let count = count() else { return nil }
            var pairs: [(TarsValue, TarsValue)] = []
            for _ in 0..<count {
                guard let (_, keyType) = head(), let key = value(keyType), let (_, valueType) = head(), let item = value(valueType) else { return nil }
                pairs.append((key, item))
            }
            return .map(pairs)
        case 9:
            guard let count = count() else { return nil }
            var items: [TarsValue] = []
            for _ in 0..<count {
                guard let (_, itemType) = head(), let item = value(itemType) else { return nil }
                items.append(item)
            }
            return .list(items)
        case 10: return fields().map(TarsValue.fields)
        case 12: return .int(0)
        case 13:
            guard head() != nil, let count = count() else { return nil }
            return take(count).map(TarsValue.bytes)
        default: return nil
        }
    }
}
