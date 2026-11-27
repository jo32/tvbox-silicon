import AVFoundation
import TVCore
import XCTest
import SwiftUI
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

    /// Ink bounds in top-left pixel coordinates and the number of separate horizontal bands of ink.
    private func ink(in image: CGImage) throws -> (bounds: CGRect, bands: Int) {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var bounds = CGRect.null, bands = 0, previousRow = false
        for y in 0..<image.height {
            var hasInk = false
            for x in 0..<image.width where rgba[(y * image.width + x) * 4 + 3] > 160 {
                hasInk = true
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
            if hasInk && !previousRow { bands += 1 }
            previousRow = hasInk
        }
        return (bounds, bands)
    }

    func testBilingualPGSPreviewAndLiveStyleChanges() throws {
        let cues = SubtitleCues()
        let previous = PGSSubtitleStyle.load()
        defer { previous.save() }
        let sample = PGSSubtitlePreview.sample
        let authored = try ink(in: XCTUnwrap(sample.image))
        XCTAssertGreaterThanOrEqual(authored.bands, 2)
        let picture = CGRect(origin: .zero, size: sample.size)
        for style in [PGSSubtitleStyle(scale: 1.5, position: CGPoint(x: 1, y: 0)), PGSSubtitleStyle()] {
            style.save()
            XCTAssertEqual(cues.pgsStyle, style)
            let cue = PGSSubtitleImage(frame: sample, style: cues.pgsStyle, picture: picture, visible: picture)
            let renderer = ImageRenderer(content: cue.frame(width: picture.width, height: picture.height))
            let drawn = try ink(in: XCTUnwrap(renderer.cgImage))
            let rect = style.imageRect(for: sample, in: picture, visible: picture)
            XCTAssertGreaterThanOrEqual(drawn.bands, 2)
            XCTAssertEqual(drawn.bounds.minX, rect.minX + authored.bounds.minX * style.scale, accuracy: 2)
            XCTAssertEqual(drawn.bounds.minY, rect.minY + authored.bounds.minY * style.scale, accuracy: 2)
            XCTAssertEqual(drawn.bounds.width, authored.bounds.width * style.scale, accuracy: 2)
            XCTAssertEqual(drawn.bounds.height, authored.bounds.height * style.scale, accuracy: 2)
        }
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
        let custom = PGSSubtitleStyle(scale: 1.25, position: CGPoint(x: 0, y: 1))
        let moved = custom.imageRect(for: frame, in: movie, visible: movie)
        XCTAssertTrue(movie.contains(moved))
        XCTAssertEqual(moved.maxY, movie.maxY, accuracy: 0.001)
        XCTAssertEqual(moved.width / moved.height, frame.rect.width / frame.rect.height, accuracy: 0.001)
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
