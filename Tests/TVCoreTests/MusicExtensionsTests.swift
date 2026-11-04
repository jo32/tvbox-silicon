import Foundation
import Testing
@testable import TVCore

/// A Listenify-style extension: what allfm.js and its kind define, in miniature.
private let fakeExtension = #"""
/*!
 * @name Fake FM
 * @description For tests
 * @version v1.2.0
 * @author tests
 */
const $config = argsify($config_str)
const appConfig = {
  ver: 1, name: 'fakefm',
  tabLibrary: { name: '探索', groups: [
    { name: '排行榜', type: 'playlist', ui: 1, ext: { gid: 'charts' } },
    { name: '热门歌手', type: 'artist', ui: 0, ext: { gid: 'artists' } },
    { name: '每日推荐', type: 'song', ext: { gid: 'daily' } },
    { name: '空的', type: 'album', ext: { gid: 'nothing' } },
  ] },
}
function song(id, page) {
  return { id: `s${id}`, name: `Song ${id}`, cover: 'https://img.example/s.jpg', duration: 200,
           artist: { id: 'a', name: 'Singer A/Singer B' }, ext: { source: 'tx', songmid: `m${id}`, page } }
}
async function getConfig() { return jsonify(appConfig) }
async function getPlaylists(ext) {
  const { gid, from } = argsify(ext)
  if (gid !== 'charts') return jsonify({ list: [] })
  return jsonify({ list: [{ id: 'c1', name: `Chart ${from}`, cover: 'https://img.example/c1.jpg', artist: { name: 'fm' }, ext: { gid: 'chart-songs', id: 'c1' } }] })
}
async function getArtists(ext) {
  return jsonify({ list: [{ id: 'a1', name: 'Singer A', cover: 'https://img.example/a.jpg',
    groups: [{ name: '热门歌曲', type: 'song', ext: { gid: 'artist-songs', id: 'a1' } }], ext: { gid: 'artists', id: 'a1' } }] })
}
async function getAlbums(ext) { return jsonify({ list: [] }) }
async function getSongs(ext) {
  const { gid, page } = argsify(ext)
  // Two pages of two songs, then nothing: the collection reads until a page adds nothing.
  if (gid === 'artist-songs' && page <= 2) return jsonify({ list: [song(page * 10 + 1, page), song(page * 10 + 2, page)] })
  if (gid === 'daily' && page === 1) return jsonify({ list: [song(99, 1)] })
  if (gid === 'chart-songs') return jsonify({ list: [song(1, 1)] })
  return jsonify({ list: [] })
}
async function search(ext) {
  const { text, type } = argsify(ext)
  if (type === 'song') return jsonify({ list: [{ ...song(7, 1), name: `${text} hit` }] })
  return jsonify({ list: [{ id: 'p1', name: `${text} list`, ext: { gid: 'chart-songs' } }] })
}
async function getSongInfo(ext) {
  const { songmid, source } = argsify(ext)
  if (songmid === 'm7') {
    const answer = await $lx.request('musicUrl', { type: '320k', musicInfo: { songmid } }, { source })
    return jsonify({ urls: [answer] })
  }
  if (songmid === 'fetch') {
    const { data, status } = await $fetch.get('http://127.0.0.1:1/song', { headers: { Referer: 'https://x.example/' } })
    return jsonify({ urls: [], status, data })
  }
  return jsonify({ urls: [`https://audio.example/${songmid}.mp3`], headers: [{ Referer: 'https://audio.example/' }] })
}
"""#

private struct FakeLX: MusicExtensionLXBridge {
    func request(event: String, data: JSONValue, options: JSONValue) async throws -> JSONValue {
        guard event == "musicUrl", options["source"]?.string == "tx" else { throw TVError.unsupported("wrong request") }
        return .string("https://lx.example/" + (data[path: "musicInfo", "songmid"]?.string ?? "") + ".flac")
    }
}

private func library() throws -> (MusicExtensionLibrary, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("music-ext-\(UUID().uuidString)")
    let defaults = try #require(UserDefaults(suiteName: "music-ext-\(UUID().uuidString)"))
    return (MusicExtensionLibrary(folder: folder, defaults: defaults), folder)
}

@Test func musicExtensionHeaderAndItemsParse() throws {
    let header = MusicExtension.header(fakeExtension)
    #expect(header["name"] == "Fake FM" && header["version"] == "v1.2.0" && header["description"] == "For tests")
    #expect(MusicExtension.header("const x = 1").isEmpty)

    let item = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"qq_001","name":"晴天","cover":"https://y.gtimg.cn/a.jpg","duration":269,"artist":{"name":"周杰伦"},"ext":{"source":"tx","songmid":"001","albumName":"叶惠美"}}"#.utf8))
    let track = try #require(MusicExtensionItems.track(item, extensionID: "E1"))
    #expect(track.id == "ext:E1:qq_001" && track.title == "晴天" && track.artists == ["周杰伦"] && track.album == "叶惠美" && track.duration == 269)
    let songID = try #require(track.ids[.ext])
    let reference = try #require(MusicExtensionReference.decode(songID))
    #expect(reference.extensionID == "E1" && MusicExtensionItems.json(reference.ext)?["songmid"]?.string == "001")
    // Milliseconds are read as such; an ID that can't name a file is hashed.
    let odd = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"a/b c","name":"x","duration":269000}"#.utf8))
    let oddTrack = try #require(MusicExtensionItems.track(odd, extensionID: "E1"))
    #expect(oddTrack.duration == 269 && !oddTrack.id.contains("/") && oddTrack.id.hasPrefix("ext:E1:"))
    #expect(MusicExtensionItems.track(.object([:]), extensionID: "E1") == nil)

    #expect(MusicExtensionItems.stream(#"{"urls":["https://a.example/x.mp3"]}"#)?.url.absoluteString == "https://a.example/x.mp3")
    #expect(MusicExtensionItems.stream(#"{"urls":[{"url":"https://a.example/y.flac","headers":{"Referer":"https://a.example/"}}]}"#)?.headers == ["Referer": "https://a.example/"])
    #expect(MusicExtensionItems.stream(#"{"urls":[]}"#) == nil && MusicExtensionItems.stream(#"{"urls":["file:///etc/passwd"]}"#) == nil)
}

/// Songs, history and favorites saved before extensions existed still load, and an extension's song round-trips.
@Test func musicExtensionTracksKeepSavedDataReadable() throws {
    // Saved as before: the catalogs' tracks encode exactly as they did.
    let saved = MusicTrack(platform: .qq, songID: "001", title: "晴天", artists: ["周杰伦"])
    let decoded = try JSONDecoder().decode(MusicTrack.self, from: JSONEncoder().encode(saved))
    #expect(decoded == saved && decoded.ids == [.qq: "001"])
    let item = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"s1","name":"x","ext":{"a":1}}"#.utf8))
    let track = try #require(MusicExtensionItems.track(item, extensionID: "E1"))
    let again = try JSONDecoder().decode(MusicTrack.self, from: JSONEncoder().encode(track))
    #expect(again == track)
    let collection = MusicCollection(kind: .playlist, platform: .ext, collectionID: MusicExtensionReference.encode(extensionID: "E1", ext: "{}"), title: "t")
    #expect(try JSONDecoder().decode(MusicCollection.self, from: JSONEncoder().encode(collection)) == collection)
}

@Test func musicExtensionSongsResolveOnlyThroughTheirChannel() throws {
    let resolver = MusicResolver(providers: [VKeysProvider()])
    var track = MusicTrack(platform: .ext, songID: "E1\n{}", title: "x", artists: [])
    #expect(resolver.candidates(for: track).isEmpty)
    track.ids[.qq] = "001"
    #expect(resolver.candidates(for: track).map(\.provider) == [.vkeys])
}

@Test func musicExtensionRunsThroughTheRuntime() async throws {
    let (library, folder) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let runtime = MusicExtensionRuntime(library: library, lx: FakeLX())
    let item = try await library.add(script: fakeExtension, origin: URL(string: "https://scripts.example/fake.js"), runtime: runtime)
    #expect(item.name == "Fake FM" && item.has("getSongInfo") && item.has("getConfig") && library.enabled.map(\.id) == [item.id])
    let catalog = MusicExtensionCatalog(library: library, runtime: runtime)

    // Library groups become shelves named with the extension; an empty group is left out.
    let shelves = try await catalog.browseSections()
    #expect(shelves.map(\.title) == ["Fake FM · 排行榜", "Fake FM · 热门歌手", "Fake FM · 每日推荐"])
    #expect(shelves[0].collections.map(\.title) == ["Chart index"] && shelves[0].collections[0].platform == .ext)
    #expect(shelves[2].collections.first?.artwork?.absoluteString == "https://img.example/s.jpg")

    // An artist opens its song group, page after page until a page adds nothing.
    let artistSongs = try await catalog.tracks(of: shelves[1].collections[0])
    #expect(artistSongs.map(\.title) == ["Song 11", "Song 12", "Song 21", "Song 22"] && artistSongs[0].artists == ["Singer A", "Singer B"])
    #expect(try await catalog.tracks(of: shelves[2].collections[0]).map(\.title) == ["Song 99"])

    let found = try await catalog.search("晴天", page: 1)
    #expect(found.map(\.title) == ["晴天 hit"])
    #expect(try await catalog.searchCollections("晴天", kind: .playlist, page: 1).map(\.title) == ["晴天 list"])

    // A song's address comes from getSongInfo, with its headers; an LX request is answered and the call repeated.
    let provider = try #require(MusicExtensionProvider(library: library, runtime: runtime))
    let plain = try await provider.resolve(try #require(artistSongs[0].ids[.ext]), platform: .ext, quality: .lossless)
    #expect(plain.url.absoluteString == "https://audio.example/m11.mp3" && plain.headers == ["Referer": "https://audio.example/"])
    let throughLX = try await provider.resolve(try #require(found[0].ids[.ext]), platform: .ext, quality: .lossless)
    #expect(throughLX.url.absoluteString == "https://lx.example/m7.flac")
    #expect(MusicResolver(providers: [provider]).candidates(for: found[0]).map(\.provider) == [.extension])

    // $fetch answers {data, status} even when the server can't be reached.
    let fetched = try await runtime.call(item, "getSongInfo", #"{"songmid":"fetch"}"#, seconds: 20)
    #expect(MusicExtensionItems.json(fetched)?["status"]?.int == 0 && MusicExtensionItems.json(fetched)?["data"]?.string == "")

    // Turned off, it lists, searches and plays nothing.
    library.setEnabled(item.id, false)
    #expect(try await catalog.browseSections().isEmpty && catalog.mayBeEmpty)
    #expect(try await catalog.search("晴天", page: 1).isEmpty)
    #expect(MusicExtensionProvider(library: library, runtime: runtime) == nil)
}

@Test func musicExtensionWithoutLXSourceFailsClearly() async throws {
    let (library, folder) = try library()
    defer { try? FileManager.default.removeItem(at: folder) }
    let runtime = MusicExtensionRuntime(library: library, lx: MusicExtensionNoLX())
    let item = try await library.add(script: fakeExtension, origin: nil, runtime: runtime)
    await #expect(throws: TVError.self) { try await runtime.call(item, "getSongInfo", #"{"songmid":"m7","source":"tx"}"#, seconds: 10) }
    // A script that is not an extension is refused and not kept.
    await #expect(throws: TVError.self) { try await library.add(script: "function getSongs() {}", origin: nil, runtime: runtime) }
    #expect(library.extensions.count == 1)
}

@Test func extensionLXRequestsNeedAnLXSource() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lx-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let lx = MusicExtensionLX(library: LXSourceLibrary(folder: folder, defaults: try #require(UserDefaults(suiteName: "lx-\(UUID().uuidString)"))))
    let data: JSONValue = .object(["type": .string("320k"), "musicInfo": .object(["songmid": .string("001")])])
    await #expect(throws: TVError.self) { try await lx.request(event: "musicUrl", data: data, options: .object(["source": .string("tx")])) }
    await #expect(throws: TVError.self) { try await lx.request(event: "lyric", data: data, options: .null) }
}

@MainActor @Test func browseModelTakesAnEmptyExtensionAnswer() async {
    struct Empty: MusicBrowseSource {
        let platform = MusicPlatform.ext
        var mayBeEmpty: Bool { true }
        func browseSections() async throws -> [MusicBrowseSection] { [] }
    }
    let model = MusicBrowseModel(sources: [Empty()])
    await model.load()
    #expect(model.incomplete == false)
    await model.reload(.ext)
    #expect(model.sections.isEmpty)
}
