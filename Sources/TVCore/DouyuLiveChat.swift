import Foundation

/// A Douyu room's bullet comments as they are sent, from Douyu's chat WebSocket. Anyone may listen.
///
/// Each packet is the length (counted from the second copy), the length again, the message type
/// (689 from the client, 690 from the server), two zero bytes, then a NUL-terminated message in
/// Douyu's STT text format: `key@=value/` pairs, with `@S` standing for `/` and `@A` for `@`. All
/// numbers are 4- and 2-byte little-endian. The client logs in to the room, joins its group -9999,
/// and sends `mrkl` every 45 seconds; comments are `chatmsg` messages.
public final class DouyuLiveChat: LiveChat, @unchecked Sendable {
    private let room: Int
    private let link = LiveChatLink()
    private let lock = NSLock()
    private var handler: LiveChatHandler?
    /// When each sender's latest comments arrived, by sender and text: Douyu repeats some every few seconds.
    private var recent: [String: ContinuousClock.Instant] = [:]

    public init(room: Int) { self.room = room }

    public func start(_ handler: @escaping LiveChatHandler) {
        lock.withLock { self.handler = handler }
        Task {
            var request = URLRequest(url: URL(string: "wss://danmuproxy.douyu.com:8506/")!)
            request.setValue(LiveHTTP.desktopAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.douyu.com", forHTTPHeaderField: "Origin")
            Diagnostics.shared.record(.info, "live.chat", "douyu room=\(room) connecting")
            await link.open(request, greeting: [Self.packet("type@=loginreq/roomid@=\(room)/"), Self.packet("type@=joingroup/rid@=\(room)/gid@=-9999/")],
                            heartbeat: Self.packet("type@=mrkl/"), every: .seconds(45)) { [weak self] in self?.read($0) }
        }
    }

    public func stop() {
        lock.withLock { handler = nil }
        link.close()
    }

    static func packet(_ message: String) -> Data {
        let body = Data(message.utf8) + [0]
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(8 + body.count)); append(UInt32(8 + body.count)); append(UInt16(689)); append(UInt16(0))
        return data + body
    }

    /// The messages in a frame, each as its fields. A frame may hold several packets.
    static func messages(_ data: Data) -> [[String: String]] {
        let bytes = [UInt8](data)
        var cursor = 0, result: [[String: String]] = []
        while cursor + 12 <= bytes.count {
            let length = (0..<4).reduce(0) { $0 | Int(bytes[cursor + $1]) << (8 * $1) }
            guard length >= 8, cursor + 4 + length <= bytes.count else { break }
            var body = bytes[(cursor + 12)..<(cursor + 4 + length)]
            while body.last == 0 { body = body.dropLast() }
            result.append(fields(String(decoding: body, as: UTF8.self)))
            cursor += 4 + length
        }
        return result
    }

    /// An STT message's top-level fields.
    static func fields(_ message: String) -> [String: String] {
        func plain(_ text: Substring) -> String {
            text.replacingOccurrences(of: "@S", with: "/").replacingOccurrences(of: "@A", with: "@")
        }
        var fields: [String: String] = [:]
        for pair in message.split(separator: "/") {
            guard let separator = pair.range(of: "@=") else { continue }
            fields[plain(pair[..<separator.lowerBound])] = plain(pair[separator.upperBound...])
        }
        return fields
    }

    /// A message's comment: chat text in the colour the sender chose (`col`, 0 for white).
    static func comment(_ fields: [String: String]) -> (text: String, color: UInt32)? {
        guard fields["type"] == "chatmsg", let text = fields["txt"], !text.isEmpty else { return nil }
        let colors: [UInt32] = [0xFFFFFF, 0xFF0000, 0x1E87F0, 0x7AC84B, 0xFF7F00, 0x9B39F4, 0xFF69B4]
        let index = Int(fields["col"] ?? "") ?? 0
        return (text, colors.indices.contains(index) ? colors[index] : 0xFFFFFF)
    }

    private func read(_ data: Data) {
        for message in Self.messages(data) {
            guard let (text, color) = Self.comment(message) else { continue }
            let now = ContinuousClock.now, key = (message["uid"] ?? "") + "\u{0}" + text
            let deliver = lock.withLock { () -> LiveChatHandler? in
                if let last = recent[key], now - last < .seconds(10) { return nil }
                if recent.count > 500 { recent = recent.filter { now - $0.value < .seconds(10) } }
                recent[key] = now
                return handler
            }
            deliver?(text, color, .scroll)
        }
    }
}
