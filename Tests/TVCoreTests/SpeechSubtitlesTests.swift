import Foundation
import Testing
import AVFoundation
@testable import TVCore

// Speech recognition is a phone-and-Mac feature: `SFSpeechRecognizer` is unavailable on tvOS, so the
// type itself only exists where the framework can back it.
#if canImport(Speech) && !os(tvOS)

/// Subtitles from a video's own audio are recognised in ~55-second slices, because one recognition
/// task only takes about a minute of audio. These pin the slicing, which is the part that decides
/// whether a 45-minute episode comes back complete or stops after the first minute.
@Suite struct SpeechSubtitlesTests {

    @Test func aClipShorterThanOneSliceIsOneSlice() {
        let slices = SpeechSubtitles.slices(duration: 30)
        #expect(slices.count == 1)
        #expect(slices[0].start.seconds == 0)
        #expect(slices[0].end.seconds == 30)
    }

    @Test func anEpisodeIsCutIntoEvenSlicesThatCoverItExactly() {
        // 130s at 55s a slice: 0–55, 55–110, 110–130. Contiguous, so no sentence is recognised
        // twice and then shown twice, and nothing between the slices is dropped.
        let slices = SpeechSubtitles.slices(duration: 130)
        #expect(slices.count == 3)
        #expect(slices[0].start.seconds == 0)
        #expect(abs(slices[0].end.seconds - 55) < 0.002)
        #expect(abs(slices[1].start.seconds - 55) < 0.002)
        #expect(abs(slices[1].end.seconds - 110) < 0.002)
        #expect(abs(slices[2].start.seconds - 110) < 0.002)
        #expect(abs(slices[2].end.seconds - 130) < 0.002)

        for (earlier, later) in zip(slices, slices.dropFirst()) {
            #expect(earlier.end == later.start)
        }
    }

    @Test func everySliceStaysWithinTheRecognitionLimit() {
        // 45 minutes, the length that used to come back empty.
        let slices = SpeechSubtitles.slices(duration: 45 * 60)
        #expect(slices.count == 50)
        for slice in slices {
            #expect(slice.duration.seconds <= 56)
            #expect(slice.duration.seconds > 0)
        }
        #expect(abs((slices.last?.end.seconds ?? 0) - 2700) < 0.002)
    }

    @Test func aTailShorterThanAQuarterSecondIsFoldedIntoTheLastSlice() {
        // Exporting a fragment shorter than the muxer's granularity fails, and a failed slice ends
        // the whole transcription, so the trailing scrap joins the piece before it instead of
        // becoming a slice that cannot be written.
        let slices = SpeechSubtitles.slices(duration: 110.1)
        #expect(slices.count == 2)
        #expect(abs((slices.last?.end.seconds ?? 0) - 110.1) < 0.002)
        #expect(slices.last!.duration.seconds <= 56)
    }

    @Test func nothingToRecogniseIsNoSlices() {
        // A stream whose duration never resolved: the caller turns this into "no audio" rather than
        // starting a recognition task over nothing.
        #expect(SpeechSubtitles.slices(duration: 0).isEmpty)
        #expect(SpeechSubtitles.slices(duration: .nan).isEmpty)
        #expect(SpeechSubtitles.slices(duration: -5).isEmpty)
    }

    @Test func theSpanOffsetIsWhereTheSliceStarted() {
        // The recogniser reports timestamps relative to the file it was given, so the caller shifts
        // them by the slice's start. This is that arithmetic, on the second slice of an episode.
        let slices = SpeechSubtitles.slices(duration: 300)
        let second = slices[1]
        #expect(second.start.seconds == 55)
        let span = SpeechSubtitles.Span(text: "hello", start: 3, duration: 1)
        #expect(span.start + second.start.seconds == 58)
    }
}

#endif
