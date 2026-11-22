import Foundation
import Testing
@testable import TVCore

private func toc(_ titles: [String], volumes: Set<Int> = []) -> [NovelChapter] {
    titles.enumerated().map { NovelChapter(index: $0, title: $1, url: "u\($0)", isVolume: volumes.contains($0)) }
}

/// Another source's table of contents (#1450): the same chapter by title, whatever its number and punctuation; the one
/// nearest the old number when titles repeat; the old number when no title matches; never a volume heading.
@Test func novelChapterMatchFindsTheSameChapterInAnotherSource() {
    let other = toc(["第一卷", "第1章 开端", "第2章 相遇", "第3章 离别", "番外", "番外"], volumes: [0])
    #expect(NovelChapterMatch.index(title: "第2章　相遇！", index: 7, in: other) == 2)
    #expect(NovelChapterMatch.index(title: "番外", index: 9, in: other) == 5)
    #expect(NovelChapterMatch.index(title: "番外", index: 3, in: other) == 4)
    #expect(NovelChapterMatch.index(title: "没有这一章", index: 3, in: other) == 3)
    #expect(NovelChapterMatch.index(title: "", index: 0, in: other) == 1)
    #expect(NovelChapterMatch.index(title: "没有这一章", index: 40, in: other) == 5)
    #expect(NovelChapterMatch.index(title: "x", index: 0, in: []) == nil)
}

/// Bookmarks stay in reading order, and older shelves without them still load (#1452).
@Test func novelBookmarksKeepReadingOrderAndOldShelvesLoad() throws {
    let book = NovelBook(sourceKey: "a", url: "https://a/1", name: "书", author: "人")
    var entry = NovelLibrary.ShelfBook(book: book, chapterIndex: 2, chapterTitle: "第2章 相遇")
    entry.mark(NovelBookmark(chapterIndex: 3, chapterTitle: "c", position: 0.5, excerpt: "three"))
    entry.mark(NovelBookmark(chapterIndex: 1, chapterTitle: "a", position: 0.9, excerpt: "one"))
    entry.mark(NovelBookmark(chapterIndex: 3, chapterTitle: "c", position: 0.1, excerpt: "early three"))
    #expect(entry.bookmarks.map(\.excerpt) == ["one", "early three", "three"])

    let saved = try JSONDecoder().decode([NovelLibrary.ShelfBook].self, from: JSONEncoder().encode([entry]))
    #expect(saved[0].bookmarks == entry.bookmarks)

    // A shelf written before bookmarks: no `bookmarks` key.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
    object["bookmarks"] = nil
    let old = try JSONDecoder().decode(NovelLibrary.ShelfBook.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.bookmarks.isEmpty && old.chapterIndex == 2 && old.book == book)
}

/// Moving to another source keeps the place and every bookmark at the same chapters there, found by title (#1450).
@Test func novelShelfFollowsAnotherSourceWithItsBookmarks() {
    let book = NovelBook(sourceKey: "a", url: "https://a/1", name: "书", author: "人")
    var entry = NovelLibrary.ShelfBook(book: book, chapterIndex: 2, chapterTitle: "第2章 相遇", chapterCount: 3, position: 0.4)
    entry.mark(NovelBookmark(chapterIndex: 1, chapterTitle: "第1章 开端", position: 0.2, excerpt: "x"))
    entry.mark(NovelBookmark(chapterIndex: 2, chapterTitle: "第3章 离别", position: 0.7, excerpt: "y"))
    let moved = NovelBook(sourceKey: "b", url: "https://b/9", name: "书", author: "人")
    let other = toc(["作品相关", "第一卷", "第1章 开端", "第2章 相遇", "第3章 离别"], volumes: [1])
    entry.follow(moved, chapters: other)
    #expect(entry.book == moved)
    #expect(entry.chapterIndex == 3 && entry.chapterTitle == "第2章 相遇" && entry.chapterCount == 5)
    #expect(entry.position == 0.4)
    #expect(entry.bookmarks.map(\.chapterIndex) == [2, 4])
}

/// The shelf entry moves to the new copy where it stood, even when reading the new copy already shelved it under another
/// key (a source that leaves the author out): one entry is left, with the bookmarks.
@Test func novelShelfSwitchReplacesTheCopyTheNewSourceShelved() {
    let old = NovelBook(sourceKey: "a", url: "https://a/1", name: "Star River", author: "")
    let moved = NovelBook(sourceKey: "b", url: "https://b/1", name: "Star River", author: "Ren")
    let other = NovelLibrary.ShelfBook(book: NovelBook(sourceKey: "c", url: "https://c/1", name: "x"))
    var marked = NovelLibrary.ShelfBook(book: old, chapterIndex: 1, chapterTitle: "t1")
    marked.mark(NovelBookmark(chapterIndex: 1, chapterTitle: "t1", position: 0.5, excerpt: "e"))
    let chapters = toc(["t0", "t1", "t2"])
    var shelf = [NovelLibrary.ShelfBook(book: moved), other, marked]
    #expect(NovelLibrary.switchSource(&shelf, from: old, to: moved, chapters: chapters))
    #expect(shelf.map(\.book.sourceKey) == ["c", "b"])
    #expect(shelf[1].bookmarks.count == 1 && shelf[1].chapterIndex == 1)

    var single = [marked]
    #expect(NovelLibrary.switchSource(&single, from: old, to: moved, chapters: chapters))
    #expect(single.count == 1 && single[0].book == moved)
    #expect(!NovelLibrary.switchSource(&single, from: old, to: moved, chapters: chapters))
}
