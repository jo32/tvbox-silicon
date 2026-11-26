import Foundation
import Testing
@testable import TVCore

private func media(_ segments: [String], target: Int? = 10, seconds: Double = 9.97667, header: String = "#EXTM3U") -> String {
    var lines = header.isEmpty ? [] : [header]
    if let target { lines.append("#EXT-X-TARGETDURATION:\(target)") }
    lines += ["#EXT-X-VERSION:3", "#EXT-X-MEDIA-SEQUENCE:0"]
    for segment in segments { lines += ["#EXTINF:\(seconds),", segment] }
    return (lines + ["#EXT-X-ENDLIST"]).joined(separator: "\n") + "\n"
}

@Test func aWellFormedPlaylistComesBackAsItWas() {
    let text = media(["s0.ts", "https://cdn.example/v/s1.ts?token=a%20b&x=1"])
    let result = HLSSanitizer.sanitize(text)
    #expect(result.fixes.isEmpty)
    #expect(result.text == text)
    let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",NAME=\"English\",URI=\"en.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS=\"avc1.4d401f,mp4a.40.2\",AUDIO=\"aac\"\nv.m3u8\n"
    #expect(HLSSanitizer.sanitize(master).fixes.isEmpty)
}

@Test func textBeforeThePlaylistOrNoHeaderIsRepaired() {
    // AVPlayer answers either with -1002, "unsupported URL".
    let notice = "<br />\n<b>Notice</b>: Undefined index: id in <b>/www/index.php</b><br />\n" + media(["s0.ts"])
    let repaired = HLSSanitizer.sanitize(notice)
    #expect(repaired.fixes == ["header"])
    #expect(repaired.text.hasPrefix("#EXTM3U\n#EXT-X-TARGETDURATION:10"))
    let bare = HLSSanitizer.sanitize(media(["s0.ts"], header: ""))
    #expect(bare.fixes == ["header"])
    #expect(bare.text.hasPrefix("#EXTM3U\n"))
}

@Test func aTargetDurationThatSegmentsExceedOrNoneIsRaised() {
    // AVPlayer: -12642, playlist parse error.
    let short = HLSSanitizer.sanitize(media(["s0.ts", "s1.ts"], target: 4))
    #expect(short.fixes == ["target-duration"])
    #expect(short.text.contains("#EXT-X-TARGETDURATION:10\n"))
    let missing = HLSSanitizer.sanitize(media(["s0.ts"], target: nil, seconds: 6.006))
    #expect(missing.fixes == ["target-duration"])
    #expect(missing.text.hasPrefix("#EXTM3U\n#EXT-X-TARGETDURATION:7\n"))
    // 10.4 rounds to 10: within a target of 10.
    #expect(HLSSanitizer.sanitize(media(["s0.ts"], target: 10, seconds: 10.4)).fixes.isEmpty)
}

@Test func addressesWithSpacesOrChineseAreEncoded() {
    // AVPlayer sends them unencoded and the server answers 400.
    let result = HLSSanitizer.sanitize(media(["seg 0.ts", "片段1.ts", "a|b.ts", "ok%20already.ts", "100%.ts"]))
    #expect(result.fixes == ["uri-encoding"])
    #expect(result.text.contains("\nseg%200.ts\n"))
    #expect(result.text.contains("\n%E7%89%87%E6%AE%B51.ts\n"))
    #expect(result.text.contains("\na%7Cb.ts\n"))
    #expect(result.text.contains("\nok%20already.ts\n"))
    #expect(result.text.contains("\n100%25.ts\n"))
    let key = HLSSanitizer.sanitize("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI=\"key 1.key\",IV=0x1\n#EXTINF:10,\ns.ts\n")
    #expect(key.text.contains("URI=\"key%201.key\",IV=0x1"))
}

@Test func masterPlaylistRepairs() {
    let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="AAC",DEFAULT=YES,URI="a.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="AAC",DEFAULT=NO,URI="b.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="AAC",URI="s.m3u8"
    #EXT-X-STREAM-INF:RESOLUTION=1280x720,CODECS="avc,mp4a",AUDIO="aac"
    v.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=300000,CODECS="avc1.4d401f,mp4a.40.2"
    w.m3u8
    """
    let result = HLSSanitizer.sanitize(master)
    #expect(Set(result.fixes) == ["media-names", "bandwidth", "codecs"])
    #expect(result.text.contains("NAME=\"AAC 2\",DEFAULT=NO"))
    // Another group may use the same name.
    #expect(result.text.contains("GROUP-ID=\"subs\",NAME=\"AAC\","))
    #expect(result.text.contains("#EXT-X-STREAM-INF:BANDWIDTH=2880000,RESOLUTION=1280x720,AUDIO=\"aac\"\nv.m3u8"))
    #expect(result.text.contains("CODECS=\"avc1.4d401f,mp4a.40.2\"\nw.m3u8"))
    // A master playlist has no target duration to add.
    #expect(!result.text.contains("TARGETDURATION"))
}

@Test func onlyPlaylistBytesAreReadAsText() {
    #expect(HLSSanitizer.text(Data("\u{FEFF}#EXTM3U\n#EXTINF:1,\na.ts\n".utf8)) == "#EXTM3U\n#EXTINF:1,\na.ts\n")
    #expect(HLSSanitizer.text(Data("{\"code\":403}".utf8)) == nil)
    #expect(HLSSanitizer.text(Data("<html>502 Bad Gateway</html>".utf8)) == nil)
    var ts = Data(repeating: 0, count: 188 * 3); ts[0] = 0x47
    #expect(HLSSanitizer.text(ts) == nil)
    let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let chinese = "#EXTM3U\n#EXTINF:10,\n片段.ts\n"
    #expect(HLSSanitizer.text(chinese.data(using: gb18030)!) == chinese)
}

@Test func addressesInAPlaylistAndWhichArePlaylists() {
    let origin = URL(string: "https://cdn.example/live/master.m3u8")!
    let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"x\",URI=\"audio/a.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhi/index.m3u8\n"
    let found = HLSProxy.addresses(in: master, origin: origin)
    #expect(found.map(\.url.absoluteString) == ["https://cdn.example/live/audio/a.m3u8", "https://cdn.example/live/hi/index.m3u8"])
    let allPlaylists = found.allSatisfy { $0.playlist }
    #expect(allPlaylists)
    let segments = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"data:text/plain;base64,AAAA\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:4,\n../s0.m4s\n"
    let media = HLSProxy.addresses(in: segments, origin: origin)
    #expect(media.map(\.url.absoluteString) == ["https://cdn.example/live/init.mp4", "https://cdn.example/s0.m4s"])
    let anyPlaylist = media.contains { $0.playlist }
    #expect(!anyPlaylist)
}

@Test func failuresTheProxyGetsPast() {
    func failure(_ domain: String, _ code: Int, under: NSError? = nil) -> NSError {
        NSError(domain: domain, code: code, userInfo: under.map { [NSUnderlyingErrorKey: $0] } ?? [:])
    }
    #expect(HLSProxy.recovers(failure(NSURLErrorDomain, -1008, under: failure("CoreMediaErrorDomain", -12884))))
    #expect(HLSProxy.recovers(failure(NSURLErrorDomain, -1002, under: failure("CoreMediaErrorDomain", -1002))))
    #expect(HLSProxy.recovers(failure("CoreMediaErrorDomain", -12642)))
    #expect(HLSProxy.recovers(failure("AVFoundationErrorDomain", -11848, under: failure("CoreMediaErrorDomain", -15517))))
    // An expired link, a missing file, a refused codec: asking again through the proxy changes nothing.
    #expect(!HLSProxy.recovers(failure(NSURLErrorDomain, -1102, under: failure("CoreMediaErrorDomain", -12660))))
    #expect(!HLSProxy.recovers(failure(NSURLErrorDomain, -1100, under: failure("CoreMediaErrorDomain", -12938))))
    #expect(!HLSProxy.recovers(failure("AVFoundationErrorDomain", -11821)))
    #expect(!HLSProxy.recovers(nil))
    let badRequest = NSError(domain: "CoreMediaErrorDomain", code: -16845, userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (CoreMediaErrorDomain error -16845 - HTTP 400: (unhandled))"])
    #expect(HLSProxy.recovers(failure(NSURLErrorDomain, -1008, under: badRequest)))
    let tooMany = NSError(domain: "CoreMediaErrorDomain", code: -16845, userInfo: [NSLocalizedDescriptionKey: "(CoreMediaErrorDomain error -16845 - HTTP 429: (unhandled))"])
    #expect(!HLSProxy.recovers(failure(NSURLErrorDomain, -1008, under: tooMany)))
    #expect(HLSProxy.transient(URLError(.timedOut)))
    #expect(HLSProxy.transient(URLError(.networkConnectionLost)))
    #expect(!HLSProxy.transient(URLError(.notConnectedToInternet)))
    #expect(!HLSProxy.transient(URLError(.serverCertificateUntrusted)))
    #expect(HLSProxy.transient(status: 502) && HLSProxy.transient(status: 503) && !HLSProxy.transient(status: 404) && !HLSProxy.transient(status: 403))
    #expect(HLSProxy.gatewayStatus(for: URLError(.timedOut)) == 504)
    #expect(HLSProxy.gatewayFailure(failure(NSURLErrorDomain, -1008, under: failure("CoreMediaErrorDomain", -16848))))
    #expect(HLSProxy.gatewayFailure(failure(NSURLErrorDomain, -1008, under: failure("CoreMediaErrorDomain", -16850))))
    #expect(!HLSProxy.gatewayFailure(failure(NSURLErrorDomain, -1008, under: failure("CoreMediaErrorDomain", -16847))))
    #expect(!HLSProxy.gatewayFailure(nil))
    #expect(HLSProxy.gatewayStatus(for: URLError(.cannotFindHost)) == 502)
}
