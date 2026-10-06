import Foundation

/// Coalesces downloads and reuses verified disk artifacts across app launches.
/// SHA-256 is computed locally; expiration triggers HTTP revalidation.
actor PluginDownloads {
    static let shared = PluginDownloads(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.tvbox.yingxia/PluginDownloads", isDirectory: true))
    typealias Update = @Sendable (PluginPreparation.Stage, Int64, Int64?) -> Void
    private struct Cached {
        let data: Data
        let expires: Date
        var used: Date
    }
    private struct Metadata: Codable {
        let sha256: String
        let etag: String?
        let modified: String?
        var expires: Date
    }
    private struct Flight {
        let task: Task<Data, Error>
        var observers: [UUID: Update]
        var latest: (PluginPreparation.Stage, Int64, Int64?) = (.checking, 0, nil)
    }
    private var cached: [URL: Cached] = [:]
    private var pending: [String: Flight] = [:]
    private let lifetime: TimeInterval
    private let directory: URL?
    init(lifetime: TimeInterval = 300, directory: URL? = nil) { self.lifetime = lifetime; self.directory = directory }

    func data(at url: URL, http: HTTPClient, progress: Update? = nil) async throws -> Data {
        progress?(.checking, 0, nil)
        if var hit = cached[url], hit.expires > Date() {
            hit.used = Date(); cached[url] = hit
            progress?(.reusing, 0, nil)
            return hit.data
        }
        let key = url.absoluteString
        let observer = UUID()
        if var flight = pending[key] {
            if let progress {
                flight.observers[observer] = progress; pending[key] = flight
                progress(flight.latest.0, flight.latest.1, flight.latest.2)
            }
            defer { pending[key]?.observers[observer] = nil }
            return try await flight.task.value
        }
        let download = Task { try await self.fetch(url, http: http, key: key) }
        pending[key] = Flight(task: download, observers: progress.map { [observer: $0] } ?? [:])
        do {
            let data = try await download.value
            pending[key] = nil
            cached[url] = Cached(data: data, expires: Date().addingTimeInterval(lifetime), used: Date())
            while cached.count > 4 || cached.values.reduce(0, { $0 + $1.data.count }) > 40_000_000 {
                guard let oldest = cached.min(by: { $0.value.used < $1.value.used })?.key else { break }
                cached[oldest] = nil
            }
            return data
        } catch { pending[key] = nil; throw error }
    }
    private func report(_ key: String, _ stage: PluginPreparation.Stage, _ received: Int64 = 0, _ expected: Int64? = nil) {
        guard var flight = pending[key] else { return }
        flight.latest = (stage, received, expected); pending[key] = flight
        for update in flight.observers.values { update(stage, received, expected) }
    }
    private func metadataURL(_ url: URL) -> URL? {
        directory?.appendingPathComponent(PluginChecksum.sha256(Data(url.absoluteString.utf8)) + ".json")
    }
    private func artifactURL(_ digest: String) -> URL? { directory?.appendingPathComponent(digest + ".bin") }
    private func read(_ url: URL) -> (Metadata, Data)? {
        guard let file = metadataURL(url), let encoded = try? Data(contentsOf: file),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: encoded),
              metadata.sha256.count == 64, metadata.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let artifact = artifactURL(metadata.sha256),
              let size = try? artifact.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
              let data = try? Data(contentsOf: artifact),
              PluginChecksum.sha256(data) == metadata.sha256 else { return nil }
        return (metadata, data)
    }
    private func save(_ data: Data, metadata: Metadata, url: URL) {
        guard let directory, let file = metadataURL(url), let artifact = artifactURL(metadata.sha256) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Replace even an existing file: read() may have rejected a corrupt copy.
            try data.write(to: artifact, options: .atomic)
            try JSONEncoder().encode(metadata).write(to: file, options: .atomic)
            trimDisk(protecting: file)
        } catch {
            Diagnostics.shared.record(.warning, "jar.cache", "Could not persist plugin cache: \(error.localizedDescription)")
        }
    }
    private func trimDisk(protecting: URL) {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var manifests = files.filter { $0.pathExtension == "json" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        manifests.removeAll { $0 == protecting }; manifests.insert(protecting, at: 0)
        var kept = Set<String>(); var total = 0; var count = 0
        for file in manifests {
            guard let bytes = try? Data(contentsOf: file), let meta = try? JSONDecoder().decode(Metadata.self, from: bytes),
                  let artifact = artifactURL(meta.sha256), let size = try? artifact.resourceValues(forKeys: [.fileSizeKey]).fileSize else { try? FileManager.default.removeItem(at: file); continue }
            let added = kept.contains(meta.sha256) ? 0 : size
            if count >= 16 || total + added > 80_000_000 { try? FileManager.default.removeItem(at: file); continue }
            kept.insert(meta.sha256); total += added; count += 1
        }
        for file in files where file.pathExtension == "bin" && !kept.contains(file.deletingPathExtension().lastPathComponent) { try? FileManager.default.removeItem(at: file) }
    }
    private func fetch(_ url: URL, http: HTTPClient, key: String) async throws -> Data {
        let stored = read(url)
        if let (meta, data) = stored, meta.expires > Date() {
            report(key, .reusing); return data
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        if let (meta, _) = stored {
            if let etag = meta.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = meta.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }
        report(key, .downloading)
        let transfer = PluginTransfer(configuration: http.session.configuration) { received, total in
            Task { await self.report(key, .downloading, received, total) }
        }
        let (data, response) = try await transfer.load(request)
        if response.statusCode == 304, let (old, data) = stored {
            var meta = old; meta.expires = Date().addingTimeInterval(lifetime)
            save(data, metadata: meta, url: url); report(key, .reusing); return data
        }
        guard (200..<300).contains(response.statusCode) else { throw TVError.http(response.statusCode) }
        report(key, .downloading, Int64(data.count), response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        report(key, .verifying)
        let meta = Metadata(sha256: PluginChecksum.sha256(data), etag: response.value(forHTTPHeaderField: "ETag"), modified: response.value(forHTTPHeaderField: "Last-Modified"), expires: Date().addingTimeInterval(lifetime))
        save(data, metadata: meta, url: url)
        return data
    }
}

/// A session delegate receives real data events. The async download convenience
/// API does not forward byte progress through its per-task delegate on all SDKs.
private final class PluginTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let update: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var failure: Error?
    private var cancelled = false
    private var last = Date.distantPast
    init(configuration: URLSessionConfiguration, update: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.configuration = configuration; self.update = update
    }
    func load(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                task.resume()
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock(); self.cancelled = true; let task = self.task; self.lock.unlock()
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        let tooLarge = response.expectedContentLength > 20_000_000
        if tooLarge { failure = TVError.unsupported(L10n.text("The plugin exceeds 20 MB.")) }
        lock.unlock()
        completionHandler(tooLarge ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if bytes.count + data.count > 20_000_000 {
            failure = TVError.unsupported(L10n.text("The plugin exceeds 20 MB."))
            lock.unlock(); dataTask.cancel(); return
        }
        bytes.append(data)
        let received = Int64(bytes.count)
        let total = response?.expectedContentLength ?? -1
        let publish = Date().timeIntervalSince(last) >= 0.1 || received == total
        if publish { last = Date() }
        lock.unlock()
        if publish { update(received, total > 0 ? total : nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let result: Result<(Data, HTTPURLResponse), Error>
        if let error = failure ?? error { result = .failure(error) }
        else if let response { result = .success((bytes, response)) }
        else { result = .failure(TVError.invalidConfiguration) }
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
