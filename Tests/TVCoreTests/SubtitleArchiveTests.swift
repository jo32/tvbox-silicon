import Compression
import Foundation
import Testing
@testable import TVCore

/// ZIP archives of subtitles (#576): every archive here is written by the test itself, including the hostile ones.
@Suite struct SubtitleArchiveTests {
    /// Writes ZIP archives byte by byte, as an archiver would, or as one built to do harm.
    struct Zip {
        struct File {
            var path: String
            var data: Data
            var deflate = true
            /// Bit 11: the name is UTF-8. Bit 0: encrypted.
            var flags: UInt16 = 0x800
            var rawName: [UInt8]? = nil
            /// What the directory claims, when it lies.
            var declaredSize: Int? = nil
            var crc: UInt32? = nil
        }

        static func make(_ files: [File]) -> Data {
            var out = Data(), directory = Data()
            for file in files {
                let name = file.rawName ?? Array(file.path.utf8)
                let stored = file.deflate ? deflate(file.data) : file.data
                let crc = file.crc ?? SubtitleArchive.crc32(file.data)
                let size = UInt32(file.declaredSize ?? file.data.count)
                let offset = UInt32(out.count)
                out += le32(0x0403_4B50) + le16(20) + le16(file.flags) + le16(file.deflate ? 8 : 0) + le16(0) + le16(0)
                out += le32(crc) + le32(UInt32(stored.count)) + le32(size) + le16(UInt16(name.count)) + le16(0) + Data(name) + stored
                directory += le32(0x0201_4B50) + le16(20) + le16(20) + le16(file.flags) + le16(file.deflate ? 8 : 0) + le16(0) + le16(0)
                directory += le32(crc) + le32(UInt32(stored.count)) + le32(size) + le16(UInt16(name.count)) + le16(0) + le16(0)
                directory += le16(0) + le16(0) + le32(0) + le32(offset) + Data(name)
            }
            let start = UInt32(out.count)
            out += directory
            out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(files.count)) + le16(UInt16(files.count))
            out += le32(UInt32(directory.count)) + le32(start) + le16(0)
            return out
        }

        static func deflate(_ data: Data) -> Data {
            let capacity = data.count + 4096
            var output = [UInt8](repeating: 0, count: capacity)
            let count = data.withUnsafeBytes { raw in
                compression_encode_buffer(&output, capacity, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
            return Data(output.prefix(count))
        }

        private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
        private static func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) }) }
    }

    private func srt(_ text: String) -> Data { Data("1\n00:00:01,000 --> 00:00:02,500\n\(text)\n".utf8) }

    @Test func aZippedFileShowsAsItself() throws {
        let zip = Zip.make([.init(path: "Movie.2024.chs.srt", data: srt("你好"))])
        #expect(SubtitleArchive.isArchive(zip))
        let documents = try SubtitleDocument.documents(id: "https://subs.test/a.zip", name: "a.zip", data: zip)
        #expect(documents.count == 1)
        #expect(documents[0].id == "https://subs.test/a.zip#Movie.2024.chs.srt" && documents[0].name == "Movie.2024.chs.srt")
        #expect(documents[0].language == "zh-Hans" && documents[0].texts(at: 1_500_000) == ["你好"])
        // Stored (not deflated) works too.
        let stored = Zip.make([.init(path: "a.srt", data: srt("Hi"), deflate: false)])
        #expect(try SubtitleDocument.documents(id: "s", name: "s.zip", data: stored)[0].texts(at: 2_000_000) == ["Hi"])
    }

    @Test func aSeasonPackOffersThisEpisodesFilesBestFirst() throws {
        let zip = Zip.make([
            .init(path: "Show S01/Show.S01E01.chs.srt", data: srt("one")),
            .init(path: "Show S01/Show.S01E02.chs.srt", data: srt("two")),
            .init(path: "Show S01/Show.S01E02.eng.ass", data: Data("[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,two en\n".utf8)),
            .init(path: "Show S01/readme.txt", data: Data("hello".utf8)),
            .init(path: "__MACOSX/Show S01/._Show.S01E02.chs.srt", data: Data([0, 5, 22, 7])),
        ])
        let entries = try SubtitleArchive.entries(zip)
        #expect(entries.map(\.name) == ["Show.S01E01.chs.srt", "Show.S01E02.chs.srt", "Show.S01E02.eng.ass"])
        let documents = try SubtitleDocument.documents(id: "z", name: "Show.zip", data: zip, video: "Show.S01E02.1080p.mkv")
        #expect(documents.map(\.name) == ["Show.S01E02.chs.srt", "Show.S01E02.eng.ass"])
        #expect(documents.map(\.language) == ["zh-Hans", "en"] && documents[1].format == .ass)
        // An episode the archive doesn't have.
        #expect(throws: SubtitleArchive.Failure.noneForEpisode) { try SubtitleDocument.documents(id: "z", name: "Show.zip", data: zip, video: "Show.S01E07.mkv") }
        // No episode named: all of them.
        #expect(try SubtitleDocument.documents(id: "z", name: "Show.zip", data: zip).count == 3)
    }

    @Test func namesWithoutTheUTF8FlagReadAsGB18030() throws {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let name = try #require("第02集.简体.srt".data(using: gb))
        let zip = Zip.make([.init(path: "", data: srt("x"), flags: 0, rawName: Array(name))])
        #expect(try SubtitleArchive.entries(zip).map(\.name) == ["第02集.简体.srt"])
    }

    @Test func bombsAreRefused() throws {
        // Declared past what a subtitle file may be.
        let huge = Data(repeating: 0x41, count: SubtitleFile.largest + 1)
        #expect(throws: SubtitleArchive.Failure.tooLarge) { try SubtitleArchive.entries(Zip.make([.init(path: "big.srt", data: huge)])) }
        // A ratio no text reaches: 2 MiB of one letter deflates to a few KiB.
        let dense = Data(repeating: 0x41, count: 2 << 20)
        #expect(Zip.deflate(dense).count * 100 < dense.count)
        #expect(throws: SubtitleArchive.Failure.tooLarge) { try SubtitleArchive.entries(Zip.make([.init(path: "dense.srt", data: dense)])) }
        // A directory that lies about the size: inflating stops at what it claimed.
        let liar = Zip.make([.init(path: "liar.srt", data: Data(repeating: 0x41, count: 1 << 20), declaredSize: 4096)])
        let entry = try #require(try SubtitleArchive.entries(liar).first)
        #expect(throws: SubtitleArchive.Failure.tooLarge) { try SubtitleArchive.extract(entry, from: liar) }
        // Many files that together unpack to too much.
        var limits = SubtitleArchive.Limits()
        limits.total = 100
        let many = Zip.make((0..<3).map { .init(path: "\($0).srt", data: srt(String(repeating: "line ", count: 10))) })
        #expect(throws: SubtitleArchive.Failure.tooLarge) { try SubtitleArchive.entries(many, limits: limits) }
        // Too many entries, of any kind.
        limits = SubtitleArchive.Limits()
        limits.entries = 3
        let crowded = Zip.make((0..<4).map { .init(path: "\($0).txt", data: Data("x".utf8)) })
        #expect(throws: SubtitleArchive.Failure.tooManyEntries) { try SubtitleArchive.entries(crowded, limits: limits) }
        // The archive itself too large.
        limits = SubtitleArchive.Limits()
        limits.archive = 64
        #expect(throws: SubtitleArchive.Failure.tooLarge) { try SubtitleArchive.entries(many, limits: limits) }
    }

    @Test func pathsOutsideTheArchiveRefuseIt() {
        for path in ["../evil.srt", "subs/../../evil.srt", "/etc/evil.srt", "C:/evil.srt", "C:\\evil.srt", "subs\\..\\evil.srt"] {
            let zip = Zip.make([.init(path: "fine.srt", data: srt("ok")), .init(path: path, data: srt("bad"))])
            #expect(throws: SubtitleArchive.Failure.unsafePath, "\(path)") { try SubtitleArchive.entries(zip) }
        }
        #expect(SubtitleArchive.safe("Season 1/E01..srt") && SubtitleArchive.safe("a/b.srt"))
    }

    @Test func archivesInsideArchivesAndLockedFilesAreNotOpened() throws {
        let inner = Zip.make([.init(path: "a.srt", data: srt("a"))])
        #expect(throws: SubtitleArchive.Failure.nested) { try SubtitleArchive.entries(Zip.make([.init(path: "inner.zip", data: inner), .init(path: "b.rar", data: Data("Rar!".utf8))])) }
        #expect(throws: SubtitleArchive.Failure.encrypted) { try SubtitleArchive.entries(Zip.make([.init(path: "a.srt", data: srt("a"), flags: 0x801)])) }
        #expect(throws: SubtitleArchive.Failure.noSubtitles) { try SubtitleArchive.entries(Zip.make([.init(path: "a.txt", data: Data("a".utf8))])) }
        // A nested archive beside a subtitle file is passed over.
        #expect(try SubtitleArchive.entries(Zip.make([.init(path: "inner.zip", data: inner), .init(path: "c.srt", data: srt("c"))])).map(\.name) == ["c.srt"])
    }

    @Test func damagedArchivesFail() throws {
        let zip = Zip.make([.init(path: "a.srt", data: srt("a"), crc: 1234)])
        let entry = try #require(try SubtitleArchive.entries(zip).first)
        #expect(throws: SubtitleArchive.Failure.damaged) { try SubtitleArchive.extract(entry, from: zip) }
        let good = Zip.make([.init(path: "a.srt", data: srt("a"))])
        #expect(throws: SubtitleArchive.Failure.damaged) { try SubtitleArchive.entries(good.prefix(good.count - 30)) }
        #expect(throws: SubtitleArchive.Failure.damaged) { try SubtitleArchive.entries(Data("PK\u{3}\u{4}nothing".utf8)) }
        // A deflate stream cut short.
        #expect(throws: SubtitleArchive.Failure.damaged) { try SubtitleArchive.inflate(Zip.deflate(Data(repeating: 7, count: 100_000)).prefix(40), limit: 1 << 20) }
        #expect(SubtitleArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func aSourcesZipShowsTheResultsEpisode() throws {
        let zip = Zip.make([.init(path: "Show.S02E01.srt", data: srt("first")), .init(path: "Show.S02E05.srt", data: srt("fifth"))])
        let candidate = SubtitleCandidate(provider: "assrt", key: "1", title: "Show S02", language: "en", season: 2, episode: 5)
        let document = try SubtitleSearch.document(candidate, name: "Show.S02.zip", data: zip, format: nil)
        #expect(document.name == "Show.S02E05.srt" && document.texts(at: 1_500_000) == ["fifth"])
    }
}
