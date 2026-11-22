import Foundation
import Testing
@testable import TVCore

extension RemuxTests {
    /// A file whose sound starts before its picture, as many do: AVPlayer's clock starts at the picture, so the
    /// subtitles the player draws itself count from there too. Counted from the file's start (the sound), they came
    /// that much late (#1422). The fixture's picture starts 0.5 s in; its one ASS line at 1.5 s, 1 s into the picture.
    @Test func drawnSubtitlesCountFromThePicture() async throws {
        let file = try #require(Bundle.module.url(forResource: "remux-late-picture", withExtension: "mkv", subdirectory: "Fixtures"))
        let url = try await Remux.open(try Remux.fileSource(file))
        defer { Remux.stop(url) }
        let folder = url.deletingLastPathComponent()
        let master = String(decoding: try await URLSession.shared.data(from: url).0, as: UTF8.self)
        let line = try #require(master.split(separator: "\n").first { $0.contains("TYPE=SUBTITLES") })
        let name = try #require(line.split(separator: "URI=\"").last?.split(separator: "\"").first)
        let playlist = String(decoding: try await URLSession.shared.data(from: folder.appending(path: String(name))).0, as: UTF8.self)
        for segment in playlist.split(separator: "\n").filter({ $0.hasSuffix(".vtt") }) {
            _ = try await URLSession.shared.data(from: folder.appending(path: String(segment)))
        }
        let track = try #require(Remux.styledSubtitles(url).first)
        let event = try #require(track.events(from: 0).first)
        #expect(abs(event.start - 1_000_000) < 50_000, "\(event.start)")
    }
}
