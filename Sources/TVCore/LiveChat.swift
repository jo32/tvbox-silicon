import Foundation

/// Receives a live room's comments as they arrive: the text, its colour (0xRRGGBB) and where it shows.
public typealias LiveChatHandler = @Sendable (_ text: String, _ color: UInt32, _ position: Danmaku.Position) -> Void

/// A live room's chat, which the player shows as danmaku while the room plays.
public protocol LiveChat: AnyObject, Sendable {
    func start(_ handler: @escaping LiveChatHandler)
    func stop()
}

public enum LiveChats {
    /// The chat of room `id` on a platform whose rooms speak `kind` (`LivePlatform.chat`), or nil when
    /// the app doesn't know that protocol or the id isn't one it accepts.
    public static func make(_ kind: String?, room id: String) -> (any LiveChat)? {
        switch kind {
        case "bilibili": Int(id).map { BilibiliLiveChat(room: $0) }
        case "douyu": Int(id).map { DouyuLiveChat(room: $0) }
        case "huya": Int(id) != nil ? HuyaLiveChat(room: id) : nil
        default: nil
        }
    }
}

/// The WebSocket a chat listens on: once open it sends the greeting, then the heartbeat every
/// `interval`, and passes each binary message on until `close`.
final class LiveChatLink: @unchecked Sendable {
    private static let session = URLSession(configuration: .default)
    private let lock = NSLock()
    private var socket: URLSessionWebSocketTask?
    private var closed = false

    func open(_ request: URLRequest, greeting: [Data], heartbeat: Data, every interval: Duration, read: @escaping (Data) -> Void) async {
        let socket = Self.session.webSocketTask(with: request)
        guard lock.withLock({ () -> Bool in
            guard !closed else { return false }
            self.socket = socket
            return true
        }) else { return }
        socket.resume()
        for data in greeting { try? await socket.send(.data(data)) }
        let beat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                try? await socket.send(.data(heartbeat))
            }
        }
        while !lock.withLock({ closed }) {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch {
                // The chat stops here; say why unless it was closed on purpose.
                if !lock.withLock({ closed }) {
                    Diagnostics.shared.record(.warning, "live.chat", "socket ended host=\(request.url?.host() ?? "-") error=\(error.localizedDescription)")
                }
                break
            }
            if case .data(let data) = message { read(data) }
        }
        beat.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    func close() {
        let socket = lock.withLock { () -> URLSessionWebSocketTask? in
            closed = true
            defer { self.socket = nil }
            return self.socket
        }
        socket?.cancel(with: .goingAway, reason: nil)
    }
}
