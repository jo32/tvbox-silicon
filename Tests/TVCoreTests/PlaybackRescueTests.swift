import Foundation
import Testing
@testable import TVCore

struct PlaybackRescueTests {
    // MARK: Which failures are rescued

    @Test func classifiesIgnoredRangesAndRefusedCertificates() {
        let range = NSError(domain: "AVFoundationErrorDomain", code: -11850, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12939,
                                          userInfo: [NSLocalizedDescriptionKey: "byte range and no content length - error code is 200"]),
        ])
        #expect(PlaybackRescue.trouble(range) == .ignoredRange)
        #expect(PlaybackRescue.trouble(NSError(domain: NSOSStatusErrorDomain, code: -12939)) == .ignoredRange)
        for code in [-1200, -1201, -1202, -1203, -1204] {
            #expect(PlaybackRescue.trouble(NSError(domain: NSURLErrorDomain, code: code)) == .insecure)
        }
        let nested = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: -1202),
        ])
        #expect(PlaybackRescue.trouble(nested) == .insecure)
        // HTTP 403, a client certificate, a dropped connection and no error at all are left to the other ways.
        #expect(PlaybackRescue.trouble(NSError(domain: "CoreMediaErrorDomain", code: -12660)) == nil)
        #expect(PlaybackRescue.trouble(NSError(domain: NSURLErrorDomain, code: -1206)) == nil)
        #expect(PlaybackRescue.trouble(NSError(domain: NSURLErrorDomain, code: -1005)) == nil)
        #expect(PlaybackRescue.trouble(nil) == nil)
        // The HLS proxy's 495 for a refused certificate; any other HTTP status through it is not a TLS trouble.
        let proxied = { (status: Int) in NSError(domain: "CoreMediaErrorDomain", code: -16845, userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (CoreMediaErrorDomain error -16845 - HTTP \(status): SSL Certificate Error)"]) }
        #expect(PlaybackRescue.trouble(proxied(495)) == .insecure)
        #expect(PlaybackRescue.trouble(proxied(400)) == nil)
    }

    // MARK: What a link sends

    @Test func sniffsWhatTheLinkSends() {
        #expect(PlaybackRescue.sniff(Data("#EXTM3U\n#EXT-X-VERSION:3\n".utf8)) == .playlist)
        #expect(PlaybackRescue.sniff(Data([0xEF, 0xBB, 0xBF]) + Data("\r\n  #EXTM3U\n".utf8)) == .playlist)
        #expect(PlaybackRescue.sniff(Data(TS.packets(count: 4))) == .transportStream)
        // A stream joined mid-packet still has its sync bytes 188 apart.
        #expect(PlaybackRescue.sniff(Data(Array(TS.packets(count: 4).dropFirst(100)))) == .transportStream)
        #expect(PlaybackRescue.sniff(Data([0x46, 0x4C, 0x56, 0x01, 0x05, 0, 0, 0, 9])) == .flv)
        #expect(PlaybackRescue.sniff(Data([0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81])) == .container)
        // M2TS: each packet behind a 4-byte time, so its sync bytes are 192 apart.
        let m2ts = (0..<4).flatMap { _ in [UInt8]([0x00, 0x12, 0x34, 0x56]) + TS.packet(pid: 0x100, start: false, payload: [1, 2, 3]) }
        #expect(PlaybackRescue.sniff(Data(m2ts)) == .container)
        #expect(PlaybackRescue.sniff(Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8) + Data(count: 32)) == .file)
        #expect(PlaybackRescue.sniff(Data("<!DOCTYPE html><html><body>404</body></html>".utf8)) == .page)
        #expect(PlaybackRescue.sniff(Data("\n<html>".utf8)) == .page)
        #expect(PlaybackRescue.sniff(Data("{\"code\":403}".utf8)) == .page)
        // One sync byte is no stream: an MPEG-TS-looking first byte of something else.
        #expect(PlaybackRescue.sniff(Data([0x47] + [UInt8](repeating: 0x11, count: 600))) == .file)
    }

    @Test func namesTheFileForAVPlayer() {
        #expect(PlaybackRescue.fileExtension(Data([0, 0, 0, 0x20]) + Data("ftypisom".utf8), original: "php") == "mp4")
        #expect(PlaybackRescue.fileExtension(Data([0, 0, 0, 0x14]) + Data("ftypqt  ".utf8), original: "") == "mov")
        #expect(PlaybackRescue.fileExtension(Data("ID3\u{04}".utf8), original: "php") == "mp3")
        #expect(PlaybackRescue.fileExtension(Data([0xFF, 0xF1, 0x50, 0x80]), original: "") == "aac")
        #expect(PlaybackRescue.fileExtension(Data([1, 2, 3, 4]), original: "M4A") == "m4a")
        #expect(PlaybackRescue.fileExtension(Data([1, 2, 3, 4]), original: "php") == "mp4")
    }

    // MARK: Playlists through the relay

    @Test func sendsEveryAddressOfAMasterBackThroughTheRelay() {
        var registered: [(URL, RelaySession.Kind, String)] = []
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main",URI="audio/index.php?x=1"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="a"
        mid/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000
        https://cdn.example.com/hi/index.php?token=t
        """
        let text = RelaySession.rewrite(master, origin: URL(string: "http://relay.example.com/live/channel.php?id=7")!) { url, kind, ext in
            registered.append((url, kind, ext))
            return "\(registered.count - 1).\(ext)"
        }
        #expect(registered.map(\.0.absoluteString) == ["http://relay.example.com/live/audio/index.php?x=1",
                                                       "http://relay.example.com/live/mid/index.m3u8",
                                                       "https://cdn.example.com/hi/index.php?token=t"])
        #expect(registered.allSatisfy { $0.1 == .playlist && $0.2 == "m3u8" })
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"Main\",URI=\"0.m3u8\""))
        #expect(lines.contains("1.m3u8") && lines.contains("2.m3u8"))
    }

    @Test func sendsSegmentsKeysAndMapsBackThroughTheRelay() {
        var registered: [String: (RelaySession.Kind, String)] = [:]
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="/keys/get.php?id=9",IV=0x0102
        #EXTINF:4.0,
        seg0.ts?sign=a
        #EXTINF:4.0,
        https://cdn.example.com/v/seg1.php?n=1
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://drm.example.com/1"
        #EXTINF:4.0,
        seg2.m4s
        #EXT-X-ENDLIST
        """
        let text = RelaySession.rewrite(media, origin: URL(string: "https://origin.example.com/vod/a/index.m3u8")!) { url, kind, ext in
            registered[url.absoluteString] = (kind, ext)
            return "r-\(url.lastPathComponent).\(ext)"
        }
        #expect(registered["https://origin.example.com/vod/a/init.mp4"]! == (.media, "mp4"))
        #expect(registered["https://origin.example.com/keys/get.php?id=9"]! == (.media, "key"))
        #expect(registered["https://origin.example.com/vod/a/seg0.ts?sign=a"]! == (.media, "ts"))
        // A segment behind a script gets a media name, not the script's.
        #expect(registered["https://cdn.example.com/v/seg1.php?n=1"]! == (.media, "ts"))
        #expect(registered["https://origin.example.com/vod/a/seg2.m4s"]! == (.media, "m4s"))
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("#EXT-X-KEY:METHOD=AES-128,URI=\"r-get.php.key\",IV=0x0102"))
        // A FairPlay key isn't an address the relay can fetch.
        #expect(lines.contains("#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://drm.example.com/1\""))
        #expect(lines.contains("#EXT-X-ENDLIST"))
        #expect(registered.count == 5)
    }

    @Test func aLivePlaylistNamesItsSegmentsTheSameWayEachReload() {
        let session = RelaySession(origin: URL(string: "http://iptv.example.com/live.php")!, headers: [:], trusting: false)
        let first = session.register(URL(string: "http://iptv.example.com/s/100.ts")!, kind: .media, fileExtension: "ts")
        let other = session.register(URL(string: "http://iptv.example.com/s/101.ts")!, kind: .media, fileExtension: "ts")
        #expect(first != other)
        #expect(session.register(URL(string: "http://iptv.example.com/s/100.ts")!, kind: .media, fileExtension: "ts") == first)
    }

    @Test func acceptsTheCertificateOnlyOfTheLinksOwnHostWhenTrusting() {
        let trusting = RelaySession(origin: URL(string: "https://media.example.com/a.m3u8")!, headers: [:], trusting: true)
        #expect(trusting.trusts("media.example.com") && trusting.trusts("MEDIA.example.com"))
        #expect(!trusting.trusts("cdn.example.net"))
        // A host its playlist names (a tampered one could name any) is checked as usual.
        _ = trusting.register(URL(string: "https://cdn.example.net/s0.ts")!, kind: .media, fileExtension: "ts")
        #expect(!trusting.trusts("cdn.example.net"))
        let strict = RelaySession(origin: URL(string: "https://media.example.com/a.m3u8")!, headers: [:], trusting: false)
        #expect(!strict.trusts("media.example.com"))
    }

    @Test func readsByteRanges() {
        #expect(RelaySession.span(nil, length: 100) == 0...99)
        #expect(RelaySession.span("bytes=0-1", length: 100) == 0...1)
        #expect(RelaySession.span("bytes=10-", length: 100) == 10...99)
        #expect(RelaySession.span("bytes=90-200", length: 100) == 90...99)
        #expect(RelaySession.span("bytes=-10", length: 100) == 90...99)
        #expect(RelaySession.span("bytes=100-", length: 100) == nil)
        #expect(RelaySession.span("bytes=", length: 100) == 0...99)
        #expect(RelaySession.span("bytes=5-1", length: 100) == nil)
    }

    // MARK: A continuous MPEG-TS stream cut into runs

    @Test func cutsTransportStreamsAtKeyframesWithTheirTables() throws {
        var cutter = TSCutter()
        let stream = TS.program() + TS.pictures(count: 250, keyEvery: 50, from: 900_000)
        var runs: [FLVSegmenter.Run] = []
        // Fed in odd pieces, as a network delivers it.
        var offset = 0
        while offset < stream.count {
            let end = min(stream.count, offset + 1000)
            runs += try cutter.feed(Data(stream[offset..<end]))
            offset = end
        }
        #expect(runs.count == 4)
        for run in runs {
            #expect(abs(run.duration - 2.0) < 0.001)
            #expect(!run.discontinuity)
            // Each run is a file of its own: the tables first, then a keyframe.
            #expect([UInt8](run.file.prefix(376)) == TS.program())
            let picture = run.file.startIndex + 376
            #expect(TSCutter.keyframe(Data(run.file[(picture + 5 + Int(run.file[picture + 4]))..<(picture + 188)]), hevc: false))
            #expect(run.file.count % 188 == 0)
        }
    }

    @Test func aJumpInTimeBeginsADiscontinuity() throws {
        var cutter = TSCutter()
        var runs = try cutter.feed(Data(TS.program() + TS.pictures(count: 150, keyEvery: 50, from: 0)))
        // The relay reconnected to its source: the times start over.
        runs += try cutter.feed(Data(TS.pictures(count: 150, keyEvery: 50, from: 0)))
        // The run the jump ends, then the first of the new times.
        #expect(runs.map(\.discontinuity) == [false, false, false, true, false])
    }

    @Test func usesTheRandomAccessFlagAndSkipsWhatComesBeforeTheFirstKeyframe() throws {
        var cutter = TSCutter()
        // Junk, then pictures before the tables are known, then the stream proper.
        let stream = [UInt8](repeating: 0x00, count: 77) + TS.pictures(count: 10, keyEvery: 5, from: 0)
            + TS.program() + TS.pictures(count: 150, keyEvery: 50, from: 90_000, flagged: true)
        let runs = try cutter.feed(Data(stream))
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { abs($0.duration - 2.0) < 0.001 })
    }

    @Test func refusesWhatIsNotATransportStream() {
        var cutter = TSCutter()
        #expect(throws: TSLive.NotTS.self) { _ = try cutter.feed(Data(repeating: 0x3C, count: TSCutter.searchLimit + 1000)) }
    }

    // MARK: Headers behind the ad-cutting loader

    @Test func aPlainHTTPPlaylistStaysPlainThroughTheLoader() {
        let url = URL(string: "http://plain-\(UUID().uuidString.prefix(8)).example.com/v/index.m3u8?t=1")!
        let address = LiveRepair.address(url, headers: ["Referer": "http://site.example.com/"], skipsAds: true)
        #expect(LiveRepair.skipsAds(address) && !LiveRepair.repairs(address))
        #expect(LiveRepair.upstream(address) == url)
        #expect(LiveRepair.headers(for: address) == ["Referer": "http://site.example.com/"])
        // The same host's HTTPS playlists stay HTTPS: the address carries the scheme, not the host.
        let secure = URL(string: "https://\(url.host()!)/v/other.m3u8")!
        #expect(LiveRepair.upstream(LiveRepair.address(secure, skipsAds: true)) == secure)
        let live = URL(string: "http://\(url.host()!)/live/a.m3u8")!
        let repaired = LiveRepair.address(live)
        #expect(LiveRepair.repairs(repaired) && LiveRepair.upstream(repaired) == live)
        #expect(LiveRepair.asset(for: repaired) != nil)
    }
}

/// A tiny MPEG-TS program: H.264 on PID 0x100, AAC on 0x101.
private enum TS {
    static let pmtPID = 0x1000

    static func packet(pid: Int, start: Bool, randomAccess: Bool = false, payload: [UInt8]) -> [UInt8] {
        precondition(payload.count <= 182)
        var bytes: [UInt8] = [0x47, UInt8((start ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xFF)]
        let stuffing = 184 - payload.count - 1
        bytes.append(0x30)
        bytes.append(UInt8(stuffing))
        if stuffing > 0 { bytes.append(randomAccess ? 0x40 : 0x00); bytes += [UInt8](repeating: 0xFF, count: stuffing - 1) }
        return bytes + payload
    }

    static func program() -> [UInt8] {
        let pat: [UInt8] = [0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01,
                            UInt8(0xE0 | pmtPID >> 8), UInt8(pmtPID & 0xFF), 0, 0, 0, 0]
        let pmt: [UInt8] = [0x00, 0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x00, 0xF0, 0x00,
                            0x1B, 0xE1, 0x00, 0xF0, 0x00, 0x0F, 0xE1, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
        return packet(pid: 0, start: true, payload: pat) + packet(pid: pmtPID, start: true, payload: pmt)
    }

    static func pts(_ value: Int64) -> [UInt8] {
        [UInt8(0x21 | ((value >> 29) & 0x0E)), UInt8((value >> 22) & 0xFF), UInt8(((value >> 14) & 0xFE) | 1),
         UInt8((value >> 7) & 0xFF), UInt8(((value << 1) & 0xFE) | 1)]
    }

    /// Pictures at 25 per second, each a PES on PID 0x100 and a little sound on 0x101. Every `keyEvery`th carries
    /// its parameter sets (or, `flagged`, only the random access indicator).
    static func pictures(count: Int, keyEvery: Int, from start: Int64, flagged: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = []
        for index in 0..<count {
            let time = start + Int64(index) * 3600
            let key = index % keyEvery == 0
            let nal: [UInt8] = key && !flagged ? [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x67, 0x42] : [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x41, 0x9A]
            bytes += packet(pid: 0x100, start: true, randomAccess: key && flagged, payload: [0, 0, 1, 0xE0, 0, 0, 0x80, 0x80, 5] + pts(time) + nal)
            bytes += packet(pid: 0x100, start: false, payload: [UInt8](repeating: 0xAB, count: 100))
            bytes += packet(pid: 0x101, start: true, payload: [0, 0, 1, 0xC0, 0, 0, 0x80, 0x80, 5] + pts(time) + [0xFF, 0xF1])
        }
        return bytes
    }

    static func packets(count: Int) -> [UInt8] { (0..<count).flatMap { _ in packet(pid: 0x100, start: false, payload: [1, 2, 3]) } }
}
