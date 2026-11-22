import Foundation
import Testing
@testable import TVCore

/// Legado audio sources (听书, #1130): read as sources, kept apart from the text of the same title, queued for the music
/// player, and their chapters' sounds found by the engine. No network: pages are `data:` addresses.
@Test func legadoAudioSourcesAreRead() throws {
    #expect(try #require(NovelSource(object: ["bookSourceUrl": "https://a.example", "bookSourceType": 1])).isAudio)
    #expect(try #require(NovelSource(object: ["bookSourceUrl": "https://b.example", "bookSourceType": "1"])).isAudio)
    #expect(try !#require(NovelSource(object: ["bookSourceUrl": "https://t.example", "bookSourceType": 0])).isAudio)
    #expect(try !#require(NovelSource(object: ["bookSourceUrl": "https://u.example"])).isAudio)
    // Image and file sources still aren't.
    #expect(NovelSource(object: ["bookSourceUrl": "https://i.example", "bookSourceType": 2]) == nil)
    #expect(NovelSource(object: ["bookSourceUrl": "https://f.example", "bookSourceType": "3"]) == nil)
}

@Test func audiobooksStayApartFromTheirText() throws {
    let text = NovelBook(sourceKey: "https://t.example", url: "/1", name: "盗墓笔记", author: "南派三叔")
    var audio = text
    audio.sourceKey = "https://a.example"; audio.isAudio = true
    #expect(text.match != audio.match)
    #expect(NovelLibrary.ShelfBook(book: audio).id != NovelLibrary.ShelfBook(book: text).id)
    // A shelf saved before audio sources reads as text books.
    #expect(try !JSONDecoder().decode(NovelBook.self, from: Data(#"{"sourceKey":"t","url":"/1","name":"x"}"#.utf8)).isAudio)
    #expect(try JSONDecoder().decode(NovelBook.self, from: JSONEncoder().encode(audio)).isAudio)
}

@Test func audiobookQueueCarriesItsChapters() throws {
    let book = NovelBook(sourceKey: "https://a.example", url: "https://a.example/book/1", name: "Book", isAudio: true)
    let chapters = [NovelChapter(index: 0, title: "第一卷", url: "第一卷", isVolume: true)]
        + (1...5).map { NovelChapter(index: $0, title: "第\($0)集", url: "https://a.example/c/\($0)") }
    let queue = NovelListening.queue(book: book, chapters: chapters, from: 3)
    #expect(queue.tracks.count == 5)
    #expect(queue.tracks.map(\.title) == (1...5).map { "第\($0)集" })
    let current = try #require(queue.current?.source)
    let item = try #require(NovelListening.item(current))
    #expect(item.chapter.index == 3 && item.book == book && item.count == 6)
    #expect(NovelListening.isAudiobook(current.context))
    // The track survives being saved, as a restored queue is.
    let saved = try JSONDecoder().decode(MusicQueue.self, from: JSONEncoder().encode(queue))
    #expect(try NovelListening.item(#require(saved.current?.source)) == item)
    // A TVBox listening source's track isn't an audiobook's.
    let other = MusicSourceEpisode(context: PlaybackHistoryContext(origin: URL(string: "https://sub.example/")!, sourceKey: "s", sourceName: "S",
                                                                   videoID: "v", videoName: "V", episodeID: "e", episodeName: "E", episodeFlag: "f"), address: "x")
    #expect(NovelListening.item(other) == nil)
}

@Test func audioChapterGivesItsSoundAndHeaders() async throws {
    prepareNovelListeningTests()
    func page(_ json: String) -> String { "data:application/json;base64," + Data(json.utf8).base64EncodedString() }
    func header(_ headers: [String: String], _ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    let key = "https://audio-\(UUID().uuidString.prefix(8).lowercased()).example"
    let book = NovelBook(sourceKey: key, url: key + "/book/1", name: "Book", tocURL: key + "/book/1", isAudio: true)
    let runtime = NovelRuntime.shared

    // The content rule reads the chapter's page; the sound's address carries Legado's `url,{options}`.
    let ruled = try #require(NovelSource(object: [
        "bookSourceUrl": key, "bookSourceName": "Audio", "bookSourceType": 1, "header": #"{"User-Agent":"test-agent"}"#,
        "ruleContent": ["content": #"$.info.sound.url@js:result + ',{"headers":{"Referer":"https://www.example/"}}'"#],
    ]))
    let chapter = NovelChapter(index: 0, title: "第1集", url: page(#"{"info":{"sound":{"id":7,"url":"https://cdn.example/7.m4a?a=1&b=2"}}}"#))
    let sound = try await runtime.audio(ruled, book: book, chapter: chapter)
    #expect(sound.url == "https://cdn.example/7.m4a?a=1&b=2")
    #expect(header(sound.headers, "Referer") == "https://www.example/")
    #expect(header(sound.headers, "User-Agent") == "test-agent")
    await runtime.reset(key)

    // Without a content rule the chapter's address is the sound, relative to the book.
    let plain = try #require(NovelSource(object: ["bookSourceUrl": key + "/plain", "bookSourceName": "Plain", "bookSourceType": 1]))
    let direct = try await runtime.audio(plain, book: book, chapter: NovelChapter(index: 1, title: "第2集", url: "/media/2.mp3"))
    #expect(direct.url == key + "/media/2.mp3")
    await runtime.reset(key + "/plain")

    // A page with no address isn't played.
    await #expect(throws: (any Error).self) {
        try await runtime.audio(ruled, book: book, chapter: NovelChapter(index: 2, title: "第3集", url: page(#"{"info":{}}"#)))
    }
    await runtime.reset(key)
}

/// A JSON item handed to a script reads as a Java map, as in Legado: `String(result)` is `{id=7, ...}` (Missevan's sources).
@Test func legadoScriptsSeeJsonItemsAsJavaMaps() async throws {
    prepareNovelListeningTests()
    let list = #"{"info":{"Datas":[{"id":7,"name":"北派盗墓笔记","catalog_name":"有声"},{"id":8,"name":"单曲"}]}}"#
    let key = "https://maps-\(UUID().uuidString.prefix(8).lowercased()).example"
    let source = try #require(NovelSource(object: [
        "bookSourceUrl": key, "bookSourceName": "Maps", "bookSourceType": 1,
        "searchUrl": "data:application/json;base64," + Data(list.utf8).base64EncodedString(),
        "ruleSearch": [
            "bookList": "$.info.Datas[*]", "name": "$.name",
            "bookUrl": #"<js>var id = String(result).match(/id=(\d+)/)[1]; String(result).match(/catalog_name/) ? 'https://x.example/drama?id=' + id : 'https://x.example/sound?id=' + id</js>"#,
        ],
    ]))
    let books = try await NovelRuntime.shared.search(source, keyword: "盗墓", page: 1)
    #expect(books.map(\.url) == ["https://x.example/drama?id=7", "https://x.example/sound?id=8"])
    #expect(books.allSatisfy { $0.isAudio })
}

private func prepareNovelListeningTests() {
    if NovelRuntime.profilesRoot == nil {
        NovelRuntime.profilesRoot = FileManager.default.temporaryDirectory.appendingPathComponent("novel-listening-tests-\(UUID().uuidString)")
    }
}
