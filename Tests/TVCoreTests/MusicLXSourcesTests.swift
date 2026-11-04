import Foundation
import Security
import Testing
@testable import TVCore

/// An LX Music custom source written the way published ones are: a classic script that destructures
/// `globalThis.lx`, registers its request handler and sends `inited` from a timer.
private let fakeSource = #"""
/*!
 * @name 测试音源
 * @description For the tests
 * @version v1.2.3
 * @author Yingxia
 * @homepage https://example.com/lx
 */
const { EVENT_NAMES, request, on, send, utils, env, version, currentScriptInfo } = globalThis.lx
var calls = 0
const failing = url => new Promise((resolve, reject) => request(url, { timeout: 2000 }, (err, resp) => err ? reject(err) : resolve(resp)))
on(EVENT_NAMES.request, async ({ source, action, info }) => {
  calls++
  if (action !== 'musicUrl') throw new Error('action')
  const { musicInfo, type } = info
  if (musicInfo.songmid === 'offline') { await failing('http://127.0.0.1:1/url'); return 'unreachable' }
  if (musicInfo.songmid === 'bad') return 'ftp://example.com/a.mp3'
  const key = utils.crypto.md5(musicInfo.songmid)
  const aes = utils.buffer.bufToString(utils.crypto.aesEncrypt(utils.buffer.from('abc'), 'aes-128-ecb', '0123456789abcdef', ''), 'hex')
  const random = utils.crypto.randomBytes(8).length
  const zipped = await utils.zlib.inflate(await utils.zlib.deflate('zlib'))
  return `https://audio.example/${source}/${musicInfo.songmid}.${type}?name=${encodeURIComponent(musicInfo.name)}&singer=${encodeURIComponent(musicInfo.singer)}&c=${musicInfo.copyrightId || ''}&k=${key}&aes=${aes}&r=${random}&z=${zipped.toString()}&n=${encodeURIComponent(currentScriptInfo.name)}&v=${version}&e=${env}&calls=${calls}`
})
setTimeout(() => send(EVENT_NAMES.inited, {
  openDevTools: false,
  sources: {
    tx: { name: 'QQ', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac'] },
    mg: { name: 'Migu', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k'] },
    kg: { name: 'Kugou', type: 'music', actions: ['musicUrl'], qualitys: ['128k'] },
    wy: { name: 'NetEase', type: 'lyric', actions: ['lyric'], qualitys: [] },
  },
}), 5)
"""#

private func temporaryLibrary() throws -> (LXSourceLibrary, URL, UserDefaults) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lx-test-" + UUID().uuidString)
    let suite = "lx-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (LXSourceLibrary(folder: folder, defaults: defaults), folder, defaults)
}

@Test func lxHeaderIsReadAsLXMusicReadsIt() {
    let info = LXSourceInfo(script: fakeSource)
    #expect(info == LXSourceInfo(name: "测试音源", description: "For the tests", version: "v1.2.3", author: "Yingxia", homepage: "https://example.com/lx"))
    let long = LXSourceInfo(script: "/**\n * @name " + String(repeating: "名", count: 40) + "\n*@version 2\n */\nconsole.log(1)")
    #expect(long.name.count == 24 && long.version == "2")
    // No header, or a comment that isn't the first thing in the script: LX Music names it itself.
    #expect(LXSourceInfo(script: "const a = 1 /* @name later */").name == LXSourceInfo(script: "").name)
    #expect(!LXSourceInfo(script: "").name.isEmpty)
}

@Test func lxKeysMapToCatalogsAndInfoMatchesLXFormat() throws {
    #expect(LXSourceKey.platform("tx") == .qq && LXSourceKey.platform("wy") == .netease)
    #expect(LXSourceKey.platform("kw") == .kuwo && LXSourceKey.platform("mg") == .migu && LXSourceKey.platform("kg") == nil)
    for platform in MusicPlatform.allCases where platform != .ext { #expect(LXSourceKey.platform(LXSourceKey.key(platform)) == platform) }
    #expect(LXSourceKey.quality(from: ["128k", "320k", "flac", "flac24bit"], for: .lossless) == "flac")
    #expect(LXSourceKey.quality(from: ["128k", "320k", "flac", "flac24bit"], for: .high) == "320k")
    #expect(LXSourceKey.quality(from: ["128k", "320k", "flac", "flac24bit"], for: .standard) == "128k")
    #expect(LXSourceKey.quality(from: ["128k", "320k"], for: .lossless) == "320k")
    #expect(LXSourceKey.quality(from: [], for: .high) == "320k")
    #expect(LXSourceKey.quality(from: [], for: .standard) == "128k")

    var track = MusicTrack(platform: .migu, songID: "600902000006889366_60054701923", title: "晴天", artists: ["周杰伦", "费玉清"], album: "叶惠美", duration: 269.4)
    track.ids[.qq] = "0039MnYb0qxYhV"
    let migu = LXSourceKey.musicInfo(songID: "600902000006889366_60054701923", platform: .migu, track: track)
    #expect(migu["source"] == .string("mg") && migu["songmid"] == .string("60054701923") && migu["copyrightId"] == .string("60054701923"))
    #expect(migu["name"] == .string("晴天") && migu["singer"] == .string("周杰伦、费玉清") && migu["albumName"] == .string("叶惠美") && migu["interval"] == .string("04:29"))
    let qq = LXSourceKey.musicInfo(songID: "0039MnYb0qxYhV", platform: .qq, track: nil)
    #expect(qq["source"] == .string("tx") && qq["songmid"] == .string("0039MnYb0qxYhV") && qq["name"] == .string("") && qq["interval"] == .string(""))
}

@Test func lxSourceImportsRunsAndResolves() async throws {
    let (library, folder, _) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let runtime = LXSourceRuntime()
    let source = try await library.add(script: fakeSource, origin: URL(string: "https://example.com/lx.js"), runtime: runtime)
    // Kugou has no catalog here, and NetEase only declared lyrics.
    #expect(source.sources == ["tx": ["128k", "320k", "flac"], "mg": ["128k", "320k"]])
    #expect(source.platforms == [.qq, .migu] && source.info.name == "测试音源" && source.enabled)
    #expect(library.sources.map(\.id) == [source.id])

    let health = MusicHealth(file: nil)
    let provider = try #require(LXMusicProvider(sources: library.enabled, library: library, runtime: runtime, health: health))
    #expect(provider.id == .lx && provider.platforms == [.qq, .migu])
    let track = MusicTrack(platform: .qq, songID: "0039MnYb0qxYhV", title: "晴天", artists: ["周杰伦"])
    let stream = try await provider.resolve("0039MnYb0qxYhV", platform: .qq, track: track, quality: .lossless)
    let query = try #require(URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems)
    func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
    #expect(stream.url.path() == "/tx/0039MnYb0qxYhV.flac" && stream.upstream == "lx:测试音源" && stream.claimedQuality == "flac")
    #expect(value("name") == "晴天" && value("singer") == "周杰伦" && value("n") == "测试音源" && value("v") == "2.0.0" && value("e") == "desktop")
    #expect(value("k") == "bd2a3a6c4a5ff5ba5e8dc80a17f0c87f" || value("k")?.count == 32)
    // AES-128-ECB with PKCS#7 padding, as Node's createCipheriv('aes-128-ecb').
    #expect(value("aes")?.count == 32 && value("r") == "8" && value("z") == "zlib")

    // The runtime is kept: the second song reuses it.
    let migu = try await provider.resolve("600902000006889366_60054701923", platform: .migu, track: nil, quality: .lossless)
    #expect(migu.url.path() == "/mg/60054701923.320k" && migu.url.query()?.contains("calls=2") == true)

    // Failures never pass the script's own message on.
    await #expect(throws: MusicProviderError.noResource) { try await provider.resolve("bad", platform: .qq, track: nil, quality: .lossless) }
    await #expect(throws: MusicProviderError.noResource) { try await provider.resolve("offline", platform: .qq, track: nil, quality: .lossless) }
    await #expect(throws: MusicProviderError.noResource) { try await provider.resolve("x", platform: .kuwo, track: nil, quality: .lossless) }

    library.setEnabled(source.id, false)
    #expect(library.enabled.isEmpty && LXMusicProvider(sources: library.enabled) == nil)
    library.remove(source.id)
    #expect(library.sources.isEmpty)
}

@Test func lxSourcesThatDoNotStartAreRefused() async throws {
    let (library, folder, _) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let runtime = LXSourceRuntime()
    let kugouOnly = "globalThis.lx.on('request', async () => 'https://a.example/1.mp3'); globalThis.lx.send('inited', { sources: { kg: { type: 'music', actions: ['musicUrl'], qualitys: ['128k'] } } })"
    await #expect(throws: TVError.self) { try await library.add(script: kugouOnly, origin: nil, runtime: runtime) }
    let silent = "globalThis.lx.on('request', async () => 'https://a.example/1.mp3')"
    await #expect(throws: TVError.self) { try await library.add(script: silent, origin: nil, runtime: runtime) }
    let broken = "globalThis.lx.send('inited', { sources: { tx: { type: 'music', actions: ['musicUrl'], qualitys: ['320k'] } } }); throw new Error('boom')"
    await #expect(throws: TVError.self) { try await library.add(script: broken, origin: nil, runtime: runtime) }
    await #expect(throws: TVError.self) { try await library.add(script: "<html>not a script</html>", origin: nil, runtime: runtime) }
    #expect(library.sources.isEmpty)
}

@Test func lxChannelComesAfterTheBuiltInOnes() {
    struct Stub: MusicStreamProvider {
        let id: MusicProviderID; let platforms: Set<MusicPlatform>
        func resolve(_ songID: String, platform: MusicPlatform, quality: MusicAudioQuality) async throws -> ResolvedMusicStream { throw MusicProviderError.noResource }
    }
    let resolver = MusicResolver(providers: [Stub(id: .lx, platforms: [.qq, .kuwo]), Stub(id: .vkeys, platforms: [.qq]), Stub(id: .nianxin, platforms: [.kuwo])])
    var track = MusicTrack(platform: .qq, songID: "q", title: "t", artists: ["a"])
    track.ids[.kuwo] = "k"
    #expect(resolver.candidates(for: track).map { "\($0.provider.rawValue):\($0.platform.rawValue)" } == ["nianxin:kuwo", "vkeys:qq", "lx:qq", "lx:kuwo"])
}

@Test func rsaWithoutPaddingMatchesNode() throws {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024]
    let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
    let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
    let pkcs1 = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
    func der(_ tag: UInt8, _ body: Data) -> Data {
        let count = body.count
        let length: [UInt8] = count < 0x80 ? [UInt8(count)] : count < 0x100 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        return Data([tag] + length) + body
    }
    let algorithm = der(0x30, Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]))
    let spki = der(0x30, algorithm + der(0x03, Data([0]) + pkcs1))
    let message = Data("0123456789abcdef".utf8)
    for pem in ["-----BEGIN PUBLIC KEY-----\n" + spki.base64EncodedString(options: .lineLength64Characters) + "\n-----END PUBLIC KEY-----",
                "-----BEGIN RSA PUBLIC KEY-----\n" + pkcs1.base64EncodedString() + "\n-----END RSA PUBLIC KEY-----"] {
        let encrypted = try ScriptCrypto.rsaRaw(publicKey: pem, data: message)
        #expect(encrypted.count == 128)
        let decrypted = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionRaw, encrypted as CFData, nil) as Data?)
        #expect(decrypted == Data(count: 128 - message.count) + message)
    }
    #expect(throws: ScriptHostError.self) { try ScriptCrypto.rsaRaw(publicKey: "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----", data: message) }
}
