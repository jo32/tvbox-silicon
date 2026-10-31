import AVFoundation
import Foundation
import Testing
@testable import TVCore

// MKV compatibility run for issue #273: opens every file of Scripts/mkv-compat/make-files.sh through Remux from disk, from a
// link that answers byte ranges (a cloud drive) and from one that sends the rest of the file (a plugin proxy), fetches
// playlists and segments, and plays the drive case muted with AVPlayer (frames before and after a seek).
// Env: COMPAT_DIR (folder of .mkv), COMPAT_LOG (results file), COMPAT_ONLY (substring filter), COMPAT_SDR=1 (refuse HDR).
@Suite(.serialized) struct ZZCompat273Tests {
    final class Log: @unchecked Sendable {
        let handle: FileHandle
        init(_ path: String) {
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            handle = FileHandle(forWritingAtPath: path)!
            handle.seekToEndOfFile()
        }
        func line(_ text: String) { handle.write(Data((text + "\n").utf8)) }
    }

    struct Timeout: Error {}
    func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw Timeout() }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    func get(_ url: URL) async -> (Int, Data) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (-1, Data()) }
        return ((response as? HTTPURLResponse)?.statusCode ?? -2, data)
    }

    /// Fetches every playlist, each init segment, and the first, middle and last media segment of each track.
    func fetchAll(_ master: URL) async -> String {
        let base = master.deletingLastPathComponent()
        let (status, data) = await get(master)
        guard status == 200 else { return "master=\(status)" }
        let text = String(decoding: data, as: UTF8.self)
        var playlists = text.split(separator: "\n").compactMap { line -> String? in
            if let m = line.firstMatch(of: /URI="([^"]+)"/) { return String(m.1) }
            return line.hasSuffix(".m3u8") && !line.hasPrefix("#") ? String(line) : nil
        }
        playlists = Array(Set(playlists)).sorted()
        var bad: [String] = []
        var count = 0
        for name in playlists {
            let (s, body) = await get(base.appending(path: name))
            guard s == 200 else { bad.append("\(name)=\(s)"); continue }
            let lines = String(decoding: body, as: UTF8.self).split(separator: "\n")
            var files: [String] = []
            if let map = lines.first(where: { $0.hasPrefix("#EXT-X-MAP") })?.firstMatch(of: /URI="([^"]+)"/) { files.append(String(map.1)) }
            let segments = lines.filter { !$0.hasPrefix("#") }.map(String.init)
            if !segments.isEmpty {
                for i in Set([0, segments.count / 2, segments.count - 1]).sorted() { files.append(segments[i]) }
            }
            for file in files {
                let (fs, fd) = await get(base.appending(path: file))
                count += 1
                if fs != 200 { bad.append("\(file)=\(fs)") }
                else if file.hasSuffix(".m4s"), fd.count < 8 || fd.subdata(in: 4..<8) != Data("moof".utf8) { bad.append("\(file)=notmoof") }
                else if file.hasSuffix(".vtt"), !String(decoding: fd, as: UTF8.self).hasPrefix("WEBVTT") { bad.append("\(file)=notvtt") }
            }
        }
        return bad.isEmpty ? "fetch=ok(\(playlists.count)pl,\(count)files)" : "fetch=BAD[\(bad.prefix(6).joined(separator: " "))]"
    }

    @MainActor func play(_ url: URL) async -> String {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        func frames(_ tenths: Int) async -> Int {
            var n = 0
            for _ in 0..<tenths {
                try? await Task.sleep(for: .milliseconds(100))
                let t = output.itemTime(forHostTime: CACurrentMediaTime())
                if output.hasNewPixelBuffer(forItemTime: t), output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil { n += 1 }
            }
            return n
        }
        for _ in 0..<(Int(ProcessInfo.processInfo.environment["COMPAT_WAIT"] ?? "150") ?? 150) where item.status == .unknown { try? await Task.sleep(for: .milliseconds(100)) }
        let first = await frames(35)
        let t1 = player.currentTime().seconds
        let duration = item.duration.seconds
        var seekInfo = ""
        if item.status == .readyToPlay, duration.isFinite, duration > 6 {
            let target = duration * (duration > 600 ? 0.93 : 0.6)
            final class Box: @unchecked Sendable { let lock = NSLock(); var value: Bool?; var get: Bool? { lock.withLock { value } } }
            let box = Box()
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in box.lock.withLock { box.value = finished } }
            for _ in 0..<150 where box.get == nil { try? await Task.sleep(for: .milliseconds(100)) }
            player.play()
            let later = await frames(30)
            let t2 = player.currentTime().seconds
            seekInfo = " seek(\(Int(target)))=\(box.get.map { "\($0)" } ?? "HUNG") frames2=\(later) t2=\(String(format: "%.1f", t2))"
        }
        let tracks = item.tracks.map { "\($0.assetTrack?.mediaType.rawValue ?? "?")\($0.isEnabled ? "" : "-off")" }.joined(separator: ",")
        let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        var errors = item.errorLog()?.events.map { "\($0.errorStatusCode):\($0.errorComment ?? "")" } ?? []
        if let e = item.error as NSError? { errors.insert("item \(e.domain) \(e.code) \((e.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code)" } ?? "")", at: 0) }
        player.pause()
        player.replaceCurrentItem(with: nil)
        let status = ["unknown", "ready", "FAILED"][item.status.rawValue]
        return "play=\(status) dur=\(String(format: "%.1f", duration)) size=\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height)) frames=\(first) t=\(String(format: "%.1f", t1))\(seekInfo) tracks=[\(tracks)] audioOpts=\(audio?.options.count ?? 0) subOpts=\(legible?.options.count ?? 0)" + (errors.isEmpty ? "" : " errors=\(errors.prefix(3))")
    }

    func summary(_ master: URL) -> String {
        guard let id = master.pathComponents.dropLast().last, let plan = RemuxStore.shared.session(id)?.plan else { return "plan=?" }
        return "plan=" + plan.tracks.map { "\($0.stream.codec)\($0.mode == .copy ? "" : ">\($0.mode)")\($0.toneMap ? "(sdr)" : "")\($0.dolbyVision == .drop ? "" : "(dv\($0.dolbyVision))")" }.joined(separator: ",") + " segs=\(plan.segments)"
    }

    @Test func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["COMPAT_DIR"], let logPath = env["COMPAT_LOG"] else { return }
        let log = Log(logPath)
        if env["COMPAT_SDR"] == "1" { Remux.refusesHDR = true }
        let modes = (env["COMPAT_MODES"] ?? "file,exact,rest").split(separator: ",").map(String.init)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".mkv") }.sorted()
            .filter { $0 >= (env["COMPAT_FROM"] ?? "") }
            .filter { name in env["COMPAT_ONLY"].map { f in f.split(separator: "|").contains { name.contains($0) } } ?? true }
        log.line("# \(Date()) files=\(files.count) modes=\(modes) sdr=\(Remux.refusesHDR)")
        for name in files {
            let path = URL(fileURLWithPath: dir).appending(path: name)
            let data = try Data(contentsOf: path)
            for mode in modes {
                let began = Date()
                var line = "\(name) \(mode)"
                do {
                    let source: RemuxSource
                    switch mode {
                    case "file": source = try Remux.fileSource(path)
                    case "exact":
                        let url = RangeServer.add("\(UUID().uuidString)-\(name)", data)
                        source = try await Remux.httpSource(url, headers: [:], chunks: RangeServer.session, configuration: RangeServer.configuration)
                    default:
                        let url = RangeServer.add("\(UUID().uuidString)-\(name)", data, restOfFile: true)
                        source = try await Remux.httpSource(url, headers: [:], chunks: RangeServer.session, configuration: RangeServer.configuration)
                    }
                    let master = try await within(90) { try await Remux.open(source) }
                    line += " open=ok(\(Int(Date().timeIntervalSince(began) * 1000))ms) \(summary(master))"
                    line += " " + (try await within(240) { await self.fetchAll(master) })
                    if mode == "exact" || mode == env["COMPAT_PLAY"] { line += " " + (try await within(400) { await self.play(master) }) }
                    Remux.stop(master)
                } catch {
                    line += " ERROR \(error is Timeout ? "timeout" : String(describing: error))"
                }
                line += " total=\(Int(Date().timeIntervalSince(began)))s"
                log.line(line)
            }
        }
        log.line("# end")
    }
}
