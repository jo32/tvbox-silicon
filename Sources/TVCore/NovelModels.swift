import Foundation

/// One Legado book source (github.com/gedoor/legado `BookSource`). The source object itself is kept as JSON
/// and handed to the rule engine (ScriptAssets/legado, NovelRuntime); the app reads only these fields.
public struct NovelSource: Codable, Hashable, Sendable, Identifiable {
    /// `bookSourceUrl`: Legado's key for a source.
    public var key: String
    public var name: String
    public var group: String
    public var comment: String
    /// The groups it is filed under (`bookSourceGroup`, comma separated).
    public var groups: [String] {
        group.split(whereSeparator: { ",，;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// Whether it has a `searchUrl`.
    public var searchable: Bool
    /// Whether it has an `exploreUrl` and doesn't switch exploring off.
    public var explorable: Bool
    /// Whether the list itself marks it as switched off (`enabled: false`).
    public var disabledByList: Bool
    /// The source object, as JSON text.
    public var json: String
    /// The JSON's checksum: a changed source restarts its runtime.
    public var revision: String
    public var id: String { key }

    public init?(object: [String: Any]) {
        guard let key = Self.string(object["bookSourceUrl"])?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        // 0 = text. Audio (1), image (2) and file (3) sources aren't read here.
        if let type = object["bookSourceType"] as? NSNumber, type.intValue != 0 { return nil }
        if let type = Self.string(object["bookSourceType"]), let value = Int(type), value != 0 { return nil }
        self.key = key
        name = Self.string(object["bookSourceName"]).flatMap { $0.isEmpty ? nil : $0 } ?? key
        group = Self.string(object["bookSourceGroup"]) ?? ""
        comment = Self.string(object["bookSourceComment"]) ?? ""
        searchable = !(Self.string(object["searchUrl"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        explorable = (object["enabledExplore"] as? Bool ?? true) && !(Self.string(object["exploreUrl"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        disabledByList = (object["enabled"] as? Bool) == false
        json = String(decoding: data, as: UTF8.self)
        revision = PluginChecksum.sha256(data)
    }

    /// The sources a Legado book source file holds: a JSON array of sources, or one source object.
    /// Nil when the data isn't one.
    public static func list(from data: Data) -> [NovelSource]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let objects: [[String: Any]]
        if let array = value as? [Any] { objects = array.compactMap { $0 as? [String: Any] } }
        else if let object = value as? [String: Any] { objects = [object] }
        else { return nil }
        let books = objects.filter { $0["bookSourceUrl"] != nil && ($0["ruleSearch"] != nil || $0["searchUrl"] != nil || $0["ruleToc"] != nil) }
        guard !books.isEmpty, books.count * 2 >= objects.count else { return nil }
        var seen = Set<String>()
        return books.compactMap(NovelSource.init(object:)).filter { seen.insert($0.key).inserted }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}

/// A book as a source describes it (Legado's `SearchBook`/`Book`).
public struct NovelBook: Codable, Hashable, Sendable, Identifiable {
    public var sourceKey: String
    /// `bookUrl`: the book's page, which identifies it within its source.
    public var url: String
    public var name: String
    public var author: String
    public var kind: String
    public var intro: String
    public var cover: String
    public var lastChapter: String
    public var wordCount: String
    /// The table of contents' address once the book's page was read; empty means `url`.
    public var tocURL: String
    /// Legado's `book.variable`: what a source keeps with the book (`book.putVariable`, `@put`).
    public var variables: [String: String]
    public var id: String { sourceKey + "@" + url }

    public init(sourceKey: String, url: String, name: String, author: String = "", kind: String = "", intro: String = "", cover: String = "",
                lastChapter: String = "", wordCount: String = "", tocURL: String = "", variables: [String: String] = [:]) {
        self.sourceKey = sourceKey; self.url = url; self.name = name; self.author = author; self.kind = kind; self.intro = intro
        self.cover = cover; self.lastChapter = lastChapter; self.wordCount = wordCount; self.tocURL = tocURL; self.variables = variables
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
        sourceKey = text(.sourceKey); url = text(.url); name = text(.name); author = text(.author); kind = text(.kind)
        intro = text(.intro); cover = text(.cover); lastChapter = text(.lastChapter); wordCount = text(.wordCount); tocURL = text(.tocURL)
        variables = ((try? c.decodeIfPresent([String: String].self, forKey: .variables)) ?? nil) ?? [:]
    }

    /// The cover's address and the headers its source asks for: Legado writes them as `url,{"headers":{…}}`.
    public var coverRequest: (url: URL, headers: [String: String])? {
        var text = cover.trimmingCharacters(in: .whitespacesAndNewlines)
        var headers: [String: String] = [:]
        if let comma = text.range(of: ",{") {
            let options = String(text[text.index(after: comma.lowerBound)...])
            if let object = (try? JSONSerialization.jsonObject(with: Data(options.utf8))) as? [String: Any] {
                if let given = object["headers"] as? [String: Any] { for (name, value) in given { headers[name] = "\(value)" } }
                else if let given = (object["headers"] as? String).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] {
                    for (name, value) in given { headers[name] = "\(value)" }
                }
                text = String(text[..<comma.lowerBound])
            }
        }
        if text.hasPrefix("//") { text = "https:" + text }
        guard text.lowercased().hasPrefix("http"), let url = URL(string: text) ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else { return nil }
        return (url, headers)
    }

    /// The same title by the same author, whichever source lists it: how search merges results.
    public var match: String { Self.normalized(name) + "|" + Self.normalized(author) }

    static func normalized(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }
}

/// One entry of a book's table of contents (Legado's `BookChapter`).
public struct NovelChapter: Codable, Hashable, Sendable, Identifiable {
    public var index: Int
    public var title: String
    public var url: String
    /// A volume heading, not a chapter to read.
    public var isVolume: Bool
    /// Marked paid/VIP by the source.
    public var isVip: Bool
    /// The source's note on it, e.g. its update time.
    public var tag: String
    /// Legado's `chapter.variable`: what the table of contents rules kept with the chapter (`@put`), for the content rules.
    public var variables: [String: String]
    public var id: String { "\(index)|" + url }

    public init(index: Int, title: String, url: String, isVolume: Bool = false, isVip: Bool = false, tag: String = "", variables: [String: String] = [:]) {
        self.index = index; self.title = title; self.url = url; self.isVolume = isVolume; self.isVip = isVip; self.tag = tag; self.variables = variables
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = ((try? c.decodeIfPresent(Int.self, forKey: .index)) ?? nil) ?? 0
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        url = ((try? c.decodeIfPresent(String.self, forKey: .url)) ?? nil) ?? ""
        isVolume = ((try? c.decodeIfPresent(Bool.self, forKey: .isVolume)) ?? nil) ?? false
        isVip = ((try? c.decodeIfPresent(Bool.self, forKey: .isVip)) ?? nil) ?? false
        tag = ((try? c.decodeIfPresent(String.self, forKey: .tag)) ?? nil) ?? ""
        variables = ((try? c.decodeIfPresent([String: String].self, forKey: .variables)) ?? nil) ?? [:]
    }
}

/// One entry of a source's explore page (`exploreUrl`): a list to open, or a heading when `url` is empty.
public struct NovelExploreKind: Codable, Hashable, Sendable, Identifiable {
    public var title: String
    public var url: String
    public var id: String { title + "|" + url }
    public init(title: String, url: String) { self.title = title; self.url = url }
}

/// A chapter's text: paragraphs, already cleaned of markup and the source's replace rules.
public struct NovelContent: Codable, Hashable, Sendable {
    public var title: String
    public var paragraphs: [String]
    public init(title: String, paragraphs: [String]) { self.title = title; self.paragraphs = paragraphs }
}
