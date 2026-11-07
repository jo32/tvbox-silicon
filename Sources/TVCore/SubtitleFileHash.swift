import Foundation

/// OpenSubtitles' "moviehash" of the playing file (#576 M2): its size plus every 64-bit little-endian word of its first
/// and last 64 KiB, added with wrap-around, as 16 hex digits. A source that knows the hash finds subtitles made for that
/// exact release (`SubtitleCandidate.fileMatch`). Only 128 KiB are read: by range requests for a file on a server or
/// drive, from disk for a download. A stream (HLS, DASH) has no file to hash.
public struct SubtitleFileHash: Sendable, Equatable {
    public let hash: String
    public let size: Int64
    public init(hash: String, size: Int64) { self.hash = hash; self.size = size }

    static let chunk = 64 << 10

    /// The hash of a file of `size` bytes whose first and last 64 KiB (or the whole file, when smaller) are `head`
    /// and `tail`.
    public static func hash(size: Int64, head: Data, tail: Data) -> String {
        var sum = UInt64(bitPattern: size)
        for part in [head, tail] {
            var words = part.prefix(chunk)
            // A part that doesn't end on a word is padded with zeros, as the reference reads it.
            if words.count % 8 != 0 { words.append(contentsOf: [UInt8](repeating: 0, count: 8 - words.count % 8)) }
            words.withUnsafeBytes { raw in
                for index in stride(from: 0, to: raw.count, by: 8) {
                    sum &+= UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", sum)
    }

    /// The playing file's hash, from what the player plays: a downloaded file, the file behind a repackaged stream, a
    /// cloud drive's stream, or a plain HTTP file whose server takes range requests. Nil for streams and when the
    /// bytes can't be had in a few seconds.
    public static func compute(_ url: URL, headers: [String: String] = [:], session: URLSession = .shared) async -> SubtitleFileHash? {
        let began = Date()
        let result: SubtitleFileHash?
        if url.isFileURL {
            result = local(url)
        } else if let source = Remux.session(url)?.source {
            result = await read(source)
        } else if url.scheme == CloudStreams.scheme {
            guard let source = await CloudStreams.source(for: url) else { return nil }
            result = await remote(source.url, headers: source.headers, session: session)
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), !["m3u8", "mpd"].contains(url.pathExtension.lowercased()),
                  !Remux.isRemuxed(url) {
            let loopback = ["127.0.0.1", "localhost"].contains(url.host() ?? "")
            result = await remote(url, headers: loopback ? [:] : headers, session: session)
        } else {
            return nil
        }
        Diagnostics.shared.record(.info, "subtitles", "file hash \(result == nil ? "none" : "ok") ms=\(Int(Date().timeIntervalSince(began) * 1000))")
        return result
    }

    static func local(_ url: URL) -> SubtitleFileHash? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        try? handle.seek(toOffset: size - UInt64(min(Int(size), chunk)))
        guard let tail = try? handle.read(upToCount: chunk) else { return nil }
        return SubtitleFileHash(hash: hash(size: Int64(size), head: head, tail: tail), size: Int64(size))
    }

    static func read(_ source: RemuxSource) async -> SubtitleFileHash? {
        let size = source.length
        guard size > 0 else { return nil }
        func bytes(at offset: Int64, count: Int) async -> Data? {
            var data = Data()
            while data.count < count {
                guard let more = try? await source.read(at: offset + Int64(data.count), count: count - data.count), !more.isEmpty else { break }
                data.append(more)
            }
            return data.count == count ? data : nil
        }
        let count = Int(min(size, Int64(chunk)))
        guard let head = await bytes(at: 0, count: count), let tail = await bytes(at: size - Int64(count), count: count) else { return nil }
        return SubtitleFileHash(hash: hash(size: size, head: head, tail: tail), size: size)
    }

    static func remote(_ url: URL, headers: [String: String], session: URLSession) async -> SubtitleFileHash? {
        guard let (head, size) = await range(url, headers: headers, from: 0, count: chunk, session: session), size > 0 else { return nil }
        let count = Int(min(size, Int64(chunk)))
        let tail: Data
        if size <= Int64(chunk) { tail = head }
        else {
            guard let (end, _) = await range(url, headers: headers, from: size - Int64(count), count: count, session: session) else { return nil }
            tail = end
        }
        guard head.count == count, tail.count == count else { return nil }
        return SubtitleFileHash(hash: hash(size: size, head: head, tail: tail), size: size)
    }

    /// `count` bytes at `from` and the file's whole size, from a 206 answer. A server that answers with the whole file
    /// (200) is left at once.
    static func range(_ url: URL, headers: [String: String], from: Int64, count: Int, session: URLSession) async -> (Data, Int64)? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(from)-\(from + Int64(count) - 1)", forHTTPHeaderField: "Range")
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let range = http.value(forHTTPHeaderField: "Content-Range")?.firstMatch(of: /^bytes (\d+)-(\d+)\/(\d+)$/),
              Int64(range.1) == from, let total = Int64(range.3) else {
            bytes.task.cancel()
            return nil
        }
        var data = Data()
        data.reserveCapacity(count)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= count { break }
            }
        } catch { bytes.task.cancel(); return nil }
        bytes.task.cancel()
        return (data, total)
    }
}
