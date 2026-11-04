import Foundation
import Testing
@testable import TVCore

private func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

@Test func miguSearchKeepsBothIDs() throws {
    // Trimmed from a real answer (2026-10-14).
    let answer = try json(#"{"code":"000000","songResultData":{"resultList":[[{"songId":"3790007","copyrightId":"60054701923","contentId":"600902000006889366","name":"晴天","singerList":[{"id":"112","name":"周杰伦"}],"album":"叶惠美","duration":270,"img3":"/data/oss/resource/00/4t/9y/679feb.webp"}],[{"songId":"1","name":"no ids"}]]}}"#)
    let tracks = try MiguMusicCatalog.parse(answer)
    #expect(tracks.count == 1)
    let track = try #require(tracks.first)
    #expect(track.ids[.migu] == "600902000006889366_60054701923" && track.title == "晴天" && track.artists == ["周杰伦"])
    #expect(track.duration == 270 && track.album == "叶惠美")
    #expect(track.artwork?.absoluteString == "https://d.musicapp.migu.cn/data/oss/resource/00/4t/9y/679feb.webp")
    let ids = try #require(MiguMusicCatalog.ids("600902000006889366_60054701923"))
    #expect(ids.content == "600902000006889366" && ids.copyright == "60054701923")
    #expect(MiguMusicCatalog.ids("600902000006889366") == nil)
    #expect(throws: MusicProviderError.self) { try MiguMusicCatalog.parse(json(#"{"code":"100001"}"#)) }
}

@Test func miguAnswerUnscramblesAndOtherTiersAreFound() throws {
    let plain = #"{"code":"000000","data":{"url":"https://freetyst.nf.migu.cn/public/2009/%E6%A0%87%E6%B8%85%E9%AB%98%E6%B8%85/MP3_128_16_Stero/600547.mp3?channelid=02&Key=abc+def"}}"#
    let offset = 0x80, key = MiguProvider.key
    let scrambled = [0xAB, 0xCD, 0x01, UInt8(offset)] + Array(plain.utf8).enumerated().map { index, byte in
        UInt8((Int(byte) - offset + Int(key[index % key.count]) + 512) % 256)
    }
    let base = try MiguProvider.address(MiguProvider.unscramble(Data(scrambled)))
    #expect(base.query()?.contains("Key=abc%2Bdef") == true)
    #expect(MiguProvider.retone(base, to: "SQ")?.absoluteString
            == "https://freetyst.nf.migu.cn/public/2009/%E6%AD%8C%E6%9B%B2%E4%B8%8B%E8%BD%BD/flac/600547.flac")
    #expect(MiguProvider.retone(base, to: "HQ")?.absoluteString
            == "https://freetyst.nf.migu.cn/public/2009/%E6%A0%87%E6%B8%85%E9%AB%98%E6%B8%85/MP3_320_16_Stero/600547.mp3")
    #expect(MiguProvider.retone(URL(string: "https://other.test/a.mp3")!, to: "SQ") == nil)
    #expect(throws: MusicProviderError.self) { try MiguProvider.unscramble(Data("{}".utf8)) }
    #expect(throws: MusicProviderError.noResource) { try MiguProvider.address(json(#"{"code":"200002","info":"无版权"}"#)) }
}

@Test func kuwoSearchAndResolvers() throws {
    let answer = try json(#"{"abslist":[{"MUSICRID":"MUSIC_228908","NAME":"晴天","ARTIST":"周杰伦&amp;费玉清","ALBUM":"叶惠美","DURATION":"269","web_albumpic_short":"120/s3s94/93/211513640.jpg"},{"NAME":"no id"}]}"#)
    let tracks = try KuwoMusicCatalog.parse(answer)
    #expect(tracks.map(\.id) == ["kuwo:228908"])
    #expect(tracks[0].artists == ["周杰伦", "费玉清"] && tracks[0].duration == 269)
    #expect(tracks[0].artwork?.absoluteString == "https://img4.kuwo.cn/star/albumcover/500/s3s94/93/211513640.jpg")
    #expect(throws: MusicProviderError.self) { try KuwoMusicCatalog.parse(json(#"{"TOTAL":"0"}"#)) }

    let nianxin = try NianxinProvider.parse(json(#"{"code":200,"data":{"url":"https://car-er.kuwo.cn/x/F000.flac"}}"#), level: "lossless")
    #expect(nianxin.url.host() == "car-er.kuwo.cn" && nianxin.claimedQuality == "lossless" && nianxin.upstream == "nianxin")
    #expect(throws: MusicProviderError.noResource) { try NianxinProvider.parse(json(#"{"code":200,"msg":"解析成功","url":""}"#), level: "lossless") }
    #expect(throws: MusicProviderError.self) { try NianxinProvider.parse(json(#"{"code":500}"#), level: "lossless") }

    let xinghai = try XinghaiProvider.parse(json(#"{"code":200,"url":"http://car-er.kuwo.cn/y/F000.flac?bitrate$2000","quality":"flac"}"#))
    #expect(xinghai.claimedQuality == "flac" && xinghai.upstream == "xinghai")
    #expect(throws: MusicProviderError.noResource) { try XinghaiProvider.parse(json(#"{"msg":"获取失败","code":500}"#)) }
}

@Test func miguAndKuwoLeadTheChannelOrder() {
    struct Stub: MusicStreamProvider {
        let id: MusicProviderID; let platforms: Set<MusicPlatform>
        func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream { throw MusicProviderError.noResource }
    }
    var track = MusicTrack(platform: .qq, songID: "q", title: "晴天", artists: ["周杰伦"])
    track.ids[.netease] = "n"; track.ids[.migu] = "c_r"; track.ids[.kuwo] = "k"
    let resolver = MusicResolver(providers: [
        Stub(id: .vkeys, platforms: [.qq]), Stub(id: .gdstudio, platforms: [.netease]), Stub(id: .hyw, platforms: [.qq]),
        Stub(id: .migu, platforms: [.migu]), Stub(id: .nianxin, platforms: [.kuwo, .netease]), Stub(id: .xinghai, platforms: [.kuwo, .netease]),
    ], health: MusicHealth(file: nil))
    let order = resolver.candidates(for: track).map { $0.provider.rawValue + "·" + $0.platform.rawValue }
    #expect(order == ["migu·migu", "nianxin·kuwo", "vkeys·qq", "gdstudio·netease", "xinghai·kuwo", "nianxin·netease", "hyw·qq", "xinghai·netease"])
    #expect(MusicResolver.isPrimary(MusicCandidate(platform: .kuwo, songID: "k", provider: .nianxin)))
    #expect(!MusicResolver.isPrimary(MusicCandidate(platform: .netease, songID: "n", provider: .nianxin)))
}

@Test func supplementaryCatalogsDoNotRepeatAListedSong() {
    var main = MusicTrack(platform: .qq, songID: "q", title: "晴天", artists: ["周杰伦"], duration: 269)
    main.ids[.kuwo] = "228908"
    let concert = MusicTrack(platform: .kuwo, songID: "1", title: "晴天", artists: ["周杰伦"], duration: 249)
    let upload = MusicTrack(platform: .migu, songID: "2_3", title: "晴天", artists: ["周杰伦"], duration: 284)
    let onlyKuwo = MusicTrack(platform: .kuwo, songID: "4", title: "软弱", artists: ["前倍注"], duration: 200)
    let twice = MusicTrack(platform: .migu, songID: "5_6", title: "软弱", artists: ["前倍注"], duration: 201)
    #expect(MusicSearchModel.withoutEchoes([main, concert, upload, onlyKuwo, twice]).map(\.id) == ["qq:q", "kuwo:4"])
}
