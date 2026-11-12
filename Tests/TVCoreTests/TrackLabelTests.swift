import Foundation
import Testing
@testable import TVCore

struct TrackLabelTests {
    typealias Option = TrackLabel.Option

    /// AVPlayer names an option by its language alone, "Unknown" without one (#884): the menus add what else is known.
    @Test func optionsShowTheirLanguageAndWhatElseIsKnown() {
        // A Blu-ray's tracks once the playlist names their languages: language, then format and channels.
        #expect(TrackLabel.names([Option(displayName: "Korean", language: "ko", title: "", format: "TrueHD 5.1"),
                                  Option(displayName: "Chinese", language: "zh", title: "", format: "AC-3 2.0")])
                == ["Korean · TrueHD 5.1", "Chinese · AC-3 2.0"])
        // No language: what the track is called, not "Unknown".
        #expect(TrackLabel.names([Option(displayName: "Unknown", language: nil, title: "", format: "DTS-HD MA 5.1"),
                                  Option(displayName: "Unknown", language: nil, title: "English", format: nil)])
                == ["DTS-HD MA 5.1", "English"])
        #expect(TrackLabel.names([Option(displayName: "Unknown", language: nil, title: nil)]) == ["Unknown"])
        // A title that only repeats the language adds nothing; one that says more is kept.
        #expect(TrackLabel.names([Option(displayName: "英语", language: "en", title: "English"), Option(displayName: "中文", language: "zh", title: "中文"),
                                  Option(displayName: "中文", language: "zh", title: "简体", format: "ASS")])
                == ["英语", "中文", "中文 · 简体 · ASS"])
        // Two that read alike are told apart.
        #expect(TrackLabel.names([Option(displayName: "Chinese", language: "zh", title: "", format: "PGS"),
                                  Option(displayName: "Chinese", language: "zh", title: "", format: "PGS"),
                                  Option(displayName: "English", language: "en", title: "", format: "PGS")])
                == ["Chinese · PGS", "Chinese · PGS (2)", "English · PGS"])
    }

    @Test func formatsNameDiscAudioAndSubtitles() {
        typealias Stream = RemuxPlan.Stream
        func format(_ stream: Stream) -> String? { RemuxPlan.format(.init(stream: stream)) }
        #expect(format(Stream(index: 1, kind: .audio, codec: "truehd", channels: 6)) == "TrueHD 5.1")
        #expect(format(Stream(index: 1, kind: .audio, codec: "dts", profile: 60, channels: 8)) == "DTS-HD MA 7.1")
        #expect(format(Stream(index: 1, kind: .audio, codec: "dts", profile: 20, channels: 6)) == "DTS 5.1")
        #expect(format(Stream(index: 1, kind: .audio, codec: "pcm_bluray", channels: 2)) == "LPCM 2.0")
        #expect(format(Stream(index: 4, kind: .subtitle, codec: "hdmv_pgs_subtitle")) == "PGS")
        #expect(format(Stream(index: -1, kind: .subtitle, codec: "external", isText: true)) == nil)
    }

    /// The details are found by the NAME the master playlist gives each track, the title of AVPlayer's option.
    @Test func detailsFollowTheMasterPlaylistsNames() throws {
        typealias Stream = RemuxPlan.Stream
        let streams = [Stream(index: 0, kind: .video, codec: "h264", width: 1920, height: 1080, frameRate: 24),
                       Stream(index: 1, kind: .audio, codec: "truehd", channels: 6, language: "kor"),
                       Stream(index: 2, kind: .audio, codec: "ac3", channels: 6, language: "kor"),
                       Stream(index: 3, kind: .audio, codec: "ac3", channels: 2, title: "Commentary"),
                       Stream(index: 4, kind: .subtitle, codec: "subrip", language: "eng", isText: true)]
        let plan = try #require(RemuxPlan.make(streams: streams, keyframes: [0, 5_000_000], start: 0, duration: 10_000_000, size: 1 << 20, device: .init()))
        let master = plan.masterPlaylist(codecs: [:])
        let details = plan.trackDetails()
        #expect(details.audio.count == 3 && details.subtitles.count == 1)
        for name in details.audio.keys { #expect(master.contains("TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(name)\"")) }
        for name in details.subtitles.keys { #expect(master.contains("TYPE=SUBTITLES,GROUP-ID=\"subtitles\",NAME=\"\(name)\"")) }
        #expect(Set(details.audio.values.compactMap(\.format)) == ["TrueHD 5.1", "AC-3 5.1", "AC-3 2.0"])
        #expect(details.audio["Commentary"] == TrackDetail(title: "Commentary", format: "AC-3 2.0"))
        #expect(details.subtitles.values.first == TrackDetail(title: "", format: "SRT"))
    }
}
