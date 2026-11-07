import Foundation

/// A live room's bullet comments as they are sent, from Bilibili's chat WebSocket.
///
/// Packets have a 16-byte header (length, header length, protocol version, operation, sequence).
/// The client authenticates (operation 7) with a token from getDanmuInfo and sends a heartbeat
/// (operation 2) every 30 seconds; messages (operation 5) arrive zlib-compressed (version 2), several
/// packets to one, and comments are their `DANMU_MSG` commands.
public final class BilibiliLiveChat: LiveChat, @unchecked Sendable {
    public typealias Handler = LiveChatHandler
    private let room: Int
    private let session = URLSession(configuration: .default)
    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var handler: Handler?
    private let lock = NSLock()

    public init(room: Int) { self.room = room }

    public func start(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
        Task { await connect() }
    }

    public func stop() {
        lock.withLock { handler = nil }
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }

    private func connect() async {
        let signer = BilibiliSigner.shared
        let account = BilibiliAccount.load()
        let cookie = await signer.cookie(account: account.cookie)
        guard let query = try? await signer.sign(["id": String(room), "type": "0", "web_location": "444.8"], cookie: cookie),
              let reply = try? await signer.json(URL(string: "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?" + query)!, cookie: cookie),
              let data = reply["data"]?.object, let token = data["token"]?.string else {
            Diagnostics.shared.record(.warning, "live.chat", "room=\(room) no chat token")
            return
        }
        let host = data["host_list"]?.array?.first?.object
        let address = "wss://\(host?["host"]?.string ?? "broadcastlv.chat.bilibili.com"):\(host?["wss_port"]?.int ?? 443)/sub"
        guard let url = URL(string: address), lock.withLock({ handler != nil }) else { return }
        var request = URLRequest(url: url)
        request.setValue(Bilibili.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://live.bilibili.com", forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        func field(_ name: String) -> String? {
            cookie.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        let auth: [String: Any] = ["uid": Int(field("DedeUserID") ?? "") ?? 0, "roomid": room, "protover": 2, "platform": "web", "type": 2,
                                   "key": token, "buvid": field("buvid3") ?? ""]
        try? await socket.send(.data(Self.packet(operation: 7, body: (try? JSONSerialization.data(withJSONObject: auth)) ?? Data())))
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await self?.socket?.send(.data(Self.packet(operation: 2, body: Data("[object Object]".utf8))))
                try? await Task.sleep(for: .seconds(30))
            }
        }
        Diagnostics.shared.record(.info, "live.chat", "room=\(room) connected uid=\(auth["uid"] ?? 0)")
        while lock.withLock({ handler != nil }) {
            guard let message = try? await socket.receive() else { break }
            if case .data(let data) = message { read(data) }
        }
    }

    static func packet(operation: UInt32, body: Data) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        append(UInt32(16 + body.count)); append(UInt16(16)); append(UInt16(1)); append(operation); append(UInt32(1))
        return data + body
    }

    /// Splits a frame into packets, inflating compressed ones, and passes on each comment.
    func read(_ data: Data) {
        let bytes = [UInt8](data)
        var cursor = 0
        func number(_ at: Int, _ count: Int) -> Int { (at..<at + count).reduce(0) { $0 << 8 | Int(bytes[$1]) } }
        while cursor + 16 <= bytes.count {
            let length = number(cursor, 4), header = number(cursor + 4, 2), version = number(cursor + 6, 2), operation = number(cursor + 8, 4)
            guard length >= header, cursor + length <= bytes.count else { return }
            let body = Data(bytes[(cursor + header)..<(cursor + length)])
            if operation == 5 {
                // Version 2 is zlib: a 2-byte header, then deflate, which Foundation's .zlib inflates.
                if version == 2, body.count > 2, let inner = try? (body.dropFirst(2) as NSData).decompressed(using: .zlib) as Data { read(inner) }
                else if version == 0 || version == 1 { comment(body) }
            }
            cursor += length
        }
    }

    private func comment(_ body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (object["cmd"] as? String)?.hasPrefix("DANMU_MSG") == true,
              let info = object["info"] as? [Any], info.count > 1, let text = info[1] as? String, !text.isEmpty else { return }
        let meta = info[0] as? [Any] ?? []
        let mode = meta.count > 1 ? (meta[1] as? NSNumber)?.intValue ?? 1 : 1
        let color = meta.count > 3 ? (meta[3] as? NSNumber)?.uint32Value ?? 0xFFFFFF : 0xFFFFFF
        let position: Danmaku.Position = mode == 4 ? .bottom : mode == 5 ? .top : .scroll
        lock.withLock { handler }?(text, color & 0xFFFFFF, position)
    }
}
