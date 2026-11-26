import AVFoundation
import TVCore
import XCTest
#if os(macOS)
import SwiftUI
#endif
@testable import PlaybackHistoryQA

@MainActor final class SubtitlePlaybackTests: XCTestCase {
    private func wait(_ description: String, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail(description); throw NSError(domain: "SubtitlePlaybackTests", code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func play(_ file: String, series: String, in session: PlaybackSession) async throws -> MediaTracks.Group {
        let asset = try XCTUnwrap(Bundle(for: Self.self).url(forResource: file, withExtension: "mkv"))
        session.player.isMuted = true
        session.start(Channel(name: file, url: asset, skipScope: series))
        try await wait("loading subtitle tracks for " + file) { session.mediaTracks.legible != nil }
        session.player.pause()
        return try XCTUnwrap(session.mediaTracks.legible)
    }

    func testTrackMenuAndPerSeriesChoicesWithRealMatroska() async throws {
        var session = PlaybackSession()
        defer { session.stop() }
        let series = UUID().uuidString, other = UUID().uuidString
        let initial = try await play("subtitles", series: series, in: session)
        XCTAssertEqual(initial.descriptions.compactMap(\.format), ["PGS", "ASS", "SRT"])
        XCTAssertEqual(Set(initial.descriptions.compactMap(\.language)).count, 1)
        let srt = try XCTUnwrap(initial.options.last)
        #if os(macOS)
        let menu = NSHostingMenu(rootView: EmbeddedSubtitlePicker(session: session))
        menu.update()
        let titles = menu.items.map(\.title)
        for option in initial.options { XCTAssertTrue(titles.contains(initial.name(option)), "\(titles)") }
        let index = try XCTUnwrap(titles.firstIndex(of: initial.name(srt)))
        menu.performActionForItem(at: index)
        #else
        session.chooseSubtitle(srt, in: initial.group)
        #endif
        try await wait("selecting SRT") { session.mediaTracks.selected(in: initial) == srt }
        session.stop()
        session = PlaybackSession()
        let reordered = try await play("reordered", series: series, in: session)
        try await wait("restoring SRT at its new position") { session.mediaTracks.selected(in: reordered) == reordered.options[0] }

        let fallback = try await play("missing", series: series, in: session)
        try await wait("temporary same-language fallback") { session.mediaTracks.selected(in: fallback) == fallback.options[0] }
        let movie = CGRect(x: 0, y: 0, width: 320, height: 132)
        session.subtitles.styled.resize(canvas: movie.size, video: movie.size)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        await session.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        try await wait("rendering the PGS cue over the cropped video") { session.subtitles.styled.frame?.image != nil }
        let frame = try XCTUnwrap(session.subtitles.styled.frame)
        let canvas = frame.canvasRect(in: movie, visible: movie)
        XCTAssertEqual(canvas.width / frame.size.width, canvas.height / frame.size.height, accuracy: 0.0001)
        XCTAssertTrue(movie.contains(canvas))
        XCTAssertEqual(canvas.height, movie.height, accuracy: 0.01)

        let secondShow = try await play("subtitles", series: other, in: session)
        session.chooseSubtitle(nil, in: secondShow.group)
        let back = try await play("subtitles", series: series, in: session)
        try await wait("returning to the original SRT preference") { session.mediaTracks.selected(in: back) == back.options[2] }
        let off = try await play("reordered", series: other, in: session)
        XCTAssertNil(session.mediaTracks.selected(in: off))
    }
}
