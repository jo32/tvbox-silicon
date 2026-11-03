import Foundation
import Network
import Observation

/// Sends what plays in Yingxia to Yingxia on another device on the same network, as AirPlay does:
/// from an iPhone, iPad or Mac to an Apple TV or a Mac.
///
/// While the app is open, an Apple TV or Mac advertises a Bonjour service. The sender lists the ones
/// it finds and sends one request over TCP, a line of JSON: the episode (its source, video and episode,
/// so the receiver resolves the stream through its own copy of that source, with the episode list for
/// Next), the stream as the sender plays it (for media the receiver can open as it is) and the position.
/// The receiver answers with one line saying whether it took the request, and plays it.
///
/// A receiver only ever resolves a source its own subscriptions already have: a request can't make it
/// load a plugin from elsewhere.
public enum PlayOn {
    /// Also listed under NSBonjourServices in the app's Info.plist, which iOS requires for browsing.
    public static let serviceType = "_yingxia._tcp"
    /// A request carries a whole episode list; past this it is not one.
    static let maximumLength = 8 << 20
    /// This installation, in the service's TXT record, so a Mac doesn't list itself.
    public static let installID: String = {
        let key = "playOnInstallID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let made = UUID().uuidString
        UserDefaults.standard.set(made, forKey: key)
        return made
    }()

    /// What a receiver is, for its icon in the sender's list.
    public enum Kind: String, Sendable {
        case tv, mac
    }

    public struct Request: Codable, Sendable {
        /// The device that sent it, as it calls itself.
        public var sender: String
        /// What the sender plays: the stream and, for a catalog episode, its history context.
        public var channel: Channel
        /// Where to start; nil for a live stream.
        public var position: Double?
        /// The catalog video with every episode, when the channel is one of them.
        public var video: Video?
        public init(sender: String, channel: Channel, position: Double?, video: Video?) {
            self.sender = sender; self.channel = channel; self.position = position; self.video = video
        }
    }

    public struct Reply: Codable, Sendable {
        public var accepted: Bool
        /// Why it was refused, for the sender to show.
        public var message: String?
        public init(accepted: Bool, message: String? = nil) { self.accepted = accepted; self.message = message }
    }

    public enum Failure: LocalizedError, Sendable {
        case noAnswer(String)
        case localNetworkDenied
        public var errorDescription: String? {
            switch self {
            case .noAnswer(let name):
                L10n.text("%@ didn't answer. Make sure Yingxia is open on it and both devices are on the same network.", name)
            case .localNetworkDenied:
                L10n.text("Turn on Local Network for Yingxia in the Settings app, then try again.")
            }
        }
    }

    /// A stream address another device can open as it is: on the network rather than inside this app
    /// (a plugin's proxy, a download or a drive file all live on 127.0.0.1 or behind an app scheme).
    public static func isPortable(_ url: URL) -> Bool {
        if LiveCatalog.isRoomAddress(url) { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        return !["127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0"].contains(host)
    }

    /// Reads up to the first newline; nil when the connection ends first or sends too much.
    static func readLine(_ connection: NWConnection, buffer: Data = Data(), completion: @escaping @Sendable (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { chunk, _, complete, error in
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let end = buffer.firstIndex(of: 10) { return completion(Data(buffer[buffer.startIndex..<end])) }
            if complete || error != nil || buffer.count > maximumLength { return completion(nil) }
            readLine(connection, buffer: buffer, completion: completion)
        }
    }

    static func line<T: Encodable>(_ value: T) throws -> Data {
        // JSON escapes newlines inside strings, so one value is one line.
        try JSONEncoder().encode(value) + Data([10])
    }
}

/// The receiving side (Apple TV and Mac): advertises the service and hands each request to `onRequest`.
public final class PlayOnReceiver: @unchecked Sendable {
    public static let shared = PlayOnReceiver()
    /// Decides on a request and answers it; called off the main thread.
    public var onRequest: (@Sendable (PlayOn.Request) async -> PlayOn.Reply)?
    public var kind = PlayOn.Kind.tv
    /// The name senders list this device under, as Bonjour registered it (numbered when another device has it).
    public var name: String { queue.sync { registered } }
    private let queue = DispatchQueue(label: "tvbox.play-on.receiver")
    private var listener: NWListener?
    private var running = false
    private var registered = "Yingxia"

    public func start() { queue.async { self.running = true; self.listen() } }
    public func stop() {
        queue.async {
            self.running = false
            self.listener?.cancel(); self.listener = nil
        }
    }

    private func listen() {
        guard running, listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp)
            var record = NWTXTRecord()
            record["id"] = PlayOn.installID
            record["kind"] = kind.rawValue
            // No name: Bonjour uses the device's own ("Living Room"), which tvOS apps can't read themselves.
            listener.service = NWListener.Service(type: PlayOn.serviceType, txtRecord: record)
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                if case .add(.service(let name, _, _, _)) = change { self?.registered = name }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Diagnostics.shared.record(.info, "play-on", "advertising port=\(listener?.port?.rawValue ?? 0)")
                case .failed(let error):
                    // The network changed under it, say: listen again shortly.
                    Diagnostics.shared.record(.warning, "play-on", "listener failed: \(error)")
                    listener?.cancel()
                    if self.listener === listener { self.listener = nil }
                    self.queue.asyncAfter(deadline: .now() + 5) { self.listen() }
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Diagnostics.shared.record(.warning, "play-on", "listener unavailable: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A connection that never sends a whole request is dropped.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        PlayOn.readLine(connection) { [weak self] data in
            guard let data, let request = try? JSONDecoder().decode(PlayOn.Request.self, from: data) else {
                Diagnostics.shared.record(.warning, "play-on", "unreadable request bytes=\(data?.count ?? -1)")
                connection.cancel(); return
            }
            let handle = self?.onRequest
            Task {
                let reply = await handle?(request) ?? PlayOn.Reply(accepted: false)
                let body = (try? PlayOn.line(reply)) ?? Data()
                connection.send(content: body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

/// The sending side: the devices with Yingxia open on this network, and sending to one.
@MainActor @Observable public final class PlayOnBrowser {
    public struct Receiver: Identifiable, Hashable, Sendable {
        public let name: String
        public let kind: PlayOn.Kind
        let endpoint: NWEndpoint
        public var id: String { name }
    }

    public private(set) var receivers: [Receiver] = []
    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    /// Looks for devices until `stop()`. The first time, iOS and macOS ask to allow Local Network.
    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PlayOn.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            // A device on Wi-Fi and Ethernet at once shows up once per interface.
            let found = results.compactMap { result -> Receiver? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var kind = PlayOn.Kind.tv
                if case .bonjour(let record) = result.metadata {
                    // A Mac doesn't send to itself.
                    if record["id"] == PlayOn.installID { return nil }
                    kind = record["kind"].flatMap(PlayOn.Kind.init) ?? .tv
                }
                guard seen.insert(name).inserted else { return nil }
                return Receiver(name: name, kind: kind, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            MainActor.assumeIsolated { self?.receivers = found }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state { Diagnostics.shared.record(.warning, "play-on", "browse failed: \(error)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel(); browser = nil
        receivers = []
    }

    /// Sends the request and returns the receiver's answer.
    public nonisolated static func send(_ request: PlayOn.Request, to receiver: Receiver) async throws -> PlayOn.Reply {
        let body = try PlayOn.line(request)
        let connection = NWConnection(to: receiver.endpoint, using: .tcp)
        let queue = DispatchQueue(label: "tvbox.play-on.send")
        let answer = Answer()
        defer { connection.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PlayOn.Reply, Error>) in
                answer.continuation = continuation
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: body, completion: .contentProcessed { error in
                            if let error { return answer.finish(.failure(error)) }
                            PlayOn.readLine(connection) { data in
                                guard let data, let reply = try? JSONDecoder().decode(PlayOn.Reply.self, from: data) else {
                                    return answer.finish(.failure(PlayOn.Failure.noAnswer(receiver.name)))
                                }
                                answer.finish(.success(reply))
                            }
                        })
                    case .waiting(let error):
                        // Waiting doesn't end by itself when Local Network is off or the device is gone.
                        if case .dns(let code) = error, code == -65570 { return answer.finish(.failure(PlayOn.Failure.localNetworkDenied)) }
                        Diagnostics.shared.record(.warning, "play-on", "send waiting: \(error)")
                        answer.finish(.failure(PlayOn.Failure.noAnswer(receiver.name)))
                    case .failed(let error):
                        Diagnostics.shared.record(.warning, "play-on", "send failed: \(error)")
                        answer.finish(.failure(PlayOn.Failure.noAnswer(receiver.name)))
                    case .cancelled:
                        answer.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 15) { answer.finish(.failure(PlayOn.Failure.noAnswer(receiver.name))) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Resumes the send's continuation once, whichever of the answer, a failure or the timeout comes first.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        var continuation: CheckedContinuation<PlayOn.Reply, Error>?
        func finish(_ result: Result<PlayOn.Reply, Error>) {
            lock.lock()
            let continuation = resumed ? nil : self.continuation
            resumed = true
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
