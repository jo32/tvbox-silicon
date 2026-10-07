import Foundation

/// Native plugin calls on two lanes. Searches run up to `width` at a time. Everything else (home,
/// detail, playback) is what the viewer is waiting on: it has its own `interactiveWidth` slots
/// and never waits behind a search burst. Java serializes calls per source, so a detail request
/// only waits for a search of the same source. Identical in-flight requests share work;
/// cancelled queued requests are removed before they can enter Java. Running Java is never
/// interrupted, but when its last caller goes away the host hears `cancel`: a call still waiting
/// to open its plugin gives up instead of loading a plugin nobody wants.
final class SerializedPluginWorker: @unchecked Sendable {
    /// Mutable state is only touched under `lock`.
    private final class Work: @unchecked Sendable {
        let resources: String
        let json: String
        let search: Bool
        let id = UUID().uuidString
        let queued = ContinuousClock.now
        var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
        init(resources: String, json: String, search: Bool) {
            self.resources = resources; self.json = json; self.search = search
        }
    }
    private let lock = NSLock()
    private let execute: @Sendable (String, String) -> Result<String, Error>
    /// Tells the host a running call lost its callers (resources, request id). The id reaches the
    /// host as the request's `request` field.
    private let abandon: (@Sendable (String, String) -> Void)?
    private let timeout: TimeInterval
    private let maximumPending: Int
    private let width: Int
    private let interactiveWidth: Int
    private var pending: [Work] = []
    private var running: [Work] = []

    init(timeout: TimeInterval = 900, maximumPending: Int = 2, width: Int = 5, interactiveWidth: Int = 2,
         abandon: (@Sendable (String, String) -> Void)? = nil,
         execute: @escaping @Sendable (String, String) -> Result<String, Error>) {
        self.timeout = timeout; self.maximumPending = maximumPending
        self.width = max(1, width); self.interactiveWidth = max(1, interactiveWidth)
        self.abandon = abandon; self.execute = execute
    }

    func request(resources: String, json: String, search: Bool = false) async throws -> String {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                // Join before checking queue capacity. A duplicate consumes no slot.
                if let matching = (running + pending).first(where: { $0.resources == resources && $0.json == json }) {
                    matching.waiters[id] = continuation
                    lock.unlock(); return
                }
                // A search burst may briefly queue a full width.
                let queued = pending.count(where: { $0.search == search })
                guard queued < maximumPending + (search ? width : 0) else {
                    let state = "pending=\(pending.count) running=\(running.count)"
                    lock.unlock()
                    Diagnostics.shared.record(.warning, "jar.queue", "rejected busy search=\(search) \(state)")
                    continuation.resume(throwing: TVError.unsupported("The plugin runtime is busy. Wait for the current source.")); return
                }
                let work = Work(resources: resources, json: json, search: search)
                work.waiters[id] = continuation; pending.append(work)
                scheduleLocked()
                lock.unlock()
            }
        } onCancel: { self.cancel(id) }
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        var waiter: CheckedContinuation<String, Error>?
        var abandoned: Work?
        for work in running where waiter == nil {
            waiter = work.waiters.removeValue(forKey: id)
            if waiter != nil, work.waiters.isEmpty { abandoned = work }
        }
        if waiter == nil {
            for work in pending {
                if let removed = work.waiters.removeValue(forKey: id) { waiter = removed; break }
            }
            pending.removeAll { $0.waiters.isEmpty }
            scheduleLocked()
        }
        lock.unlock()
        waiter?.resume(throwing: CancellationError())
        if let abandoned, let abandon {
            Diagnostics.shared.record(.debug, "jar.queue", "abandoned search=\(abandoned.search)")
            DispatchQueue.global(qos: .utility).async { abandon(abandoned.resources, abandoned.id) }
        }
    }

    /// A slow call (first preparation, heavy plugin crypto on the interpreter) is not a stuck
    /// runtime: fail only its callers. It keeps its slot until Java returns, so widths stay honest.
    private func expire(_ work: Work) {
        lock.lock()
        guard running.contains(where: { $0 === work }) else { lock.unlock(); return }
        let waiters = Array(work.waiters.values); work.waiters.removeAll()
        lock.unlock()
        Diagnostics.shared.record(.warning, "jar.timing", "search=\(work.search) timed out after \(Int(timeout))s; its slot stays busy until the plugin returns")
        for waiter in waiters { waiter.resume(throwing: TVError.unsupported("The source took too long to respond.")) }
    }

    /// Starts queued work in arrival order within each lane. Call with `lock` held.
    private func scheduleLocked() {
        var searches = running.count(where: \.search)
        var interactive = running.count - searches
        var index = 0
        while index < pending.count {
            let next = pending[index]
            guard next.search ? searches < width : interactive < interactiveWidth else { index += 1; continue }
            if next.search { searches += 1 } else { interactive += 1 }
            pending.remove(at: index); running.append(next)
            // Each call gets its own large-stack thread; plugin code recurses deeply.
            let thread = Thread { [self] in perform(next) }
            thread.name = "On-device plugins"
            thread.qualityOfService = .userInitiated
            thread.stackSize = 8 * 1024 * 1024
            thread.start()
        }
    }

    private func perform(_ work: Work) {
        let began = ContinuousClock.now
        let timer = DispatchWorkItem { [self, work] in expire(work) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let result = execute(work.resources, abandon == nil ? work.json : Self.tagged(work.json, id: work.id))
        timer.cancel()
        lock.lock()
        running.removeAll { $0 === work }
        let waiters = Array(work.waiters.values); work.waiters.removeAll()
        let concurrent = running.count
        scheduleLocked()
        lock.unlock()
        Diagnostics.shared.record(.debug, "jar.timing", "queue=\(work.queued.duration(to: began)) execution=\(began.duration(to: .now)) callers=\(waiters.count) search=\(work.search) alsoRunning=\(concurrent)")
        for waiter in waiters { waiter.resume(with: result) }
    }

    /// The request with its id as a leading `request` field, so the host can match a later `cancel`.
    static func tagged(_ json: String, id: String) -> String {
        guard json.hasPrefix("{"), json.dropFirst().contains(where: { !$0.isWhitespace && $0 != "}" }) else { return json }
        return "{\"request\":\"\(id)\"," + json.dropFirst()
    }

    // Bounded scheduling metrics, also used to synchronize concurrency tests.
    var scheduling: (pending: Int, callers: Int) {
        lock.lock(); defer { lock.unlock() }
        return (pending.count, running.reduce(0) { $0 + $1.waiters.count } + pending.reduce(0) { $0 + $1.waiters.count })
    }
}
