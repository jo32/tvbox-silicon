import Foundation
import TVCore

@main struct NativeFLVRenewalCheck {
    static func read(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func main() async throws {
        let origin = URL(string: CommandLine.arguments[1])!
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = FLVLive.Source {
            let generation = String(decoding: try await read(origin.appending(path: "resolve")), as: UTF8.self)
            return (origin.appending(path: generation + ".flv"), ["X-Generation": generation])
        }
        let master = try await FLVLive.open(origin.appending(path: "0.flv"), headers: ["X-Generation": "0"],
                                            source: CommandLine.arguments[3] == "control" ? nil : source)
        defer { Remux.stop(master) }
        let owner = master.deletingLastPathComponent()
        let first = try await read(master)
        guard String(decoding: first, as: UTF8.self).contains("1.m3u8") else { throw URLError(.cannotDecodeContentData) }
        let deadline = ContinuousClock.now + .seconds(13)
        while !(String(decoding: try await read(owner.appending(path: "0.m3u8")), as: UTF8.self).contains("#EXT-X-ENDLIST")) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard try await read(master) == first else { throw URLError(.badServerResponse) }
        for track in [0, 1] {
            let playlist = try await read(owner.appending(path: "\(track).m3u8"))
            try playlist.write(to: directory.appending(path: "\(track).m3u8"))
            var initialization = Data()
            for line in String(decoding: playlist, as: UTF8.self).split(separator: "\n") {
                if line.hasPrefix("#EXT-X-MAP:") {
                    initialization = try await read(owner.appending(path: String(line.split(separator: "\"")[1])))
                } else if line.hasSuffix(".m4s") {
                    let media = try await read(owner.appending(path: String(line)))
                    try (initialization + media).write(to: directory.appending(path: String(line) + ".mp4"))
                }
            }
        }
    }
}
