import Foundation

/// A comic in a list (Venera's `Comic`).
public struct MangaComic: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sourceKey: String
    public var title: String
    public var subtitle: String
    public var cover: String
    public var tags: [String]
    public var description: String
    public var stars: Double?
    public var identity: String { sourceKey + "@" + id }

    public init(id: String, sourceKey: String, title: String, subtitle: String = "", cover: String = "", tags: [String] = [], description: String = "", stars: Double? = nil) {
        self.id = id; self.sourceKey = sourceKey; self.title = title; self.subtitle = subtitle; self.cover = cover
        self.tags = tags; self.description = description; self.stars = stars
    }

    init?(_ value: Any?, source: String) {
        guard let item = value as? [String: Any], let id = MangaValue.string(item["id"]), !id.isEmpty else { return nil }
        self.init(id: id, sourceKey: source, title: MangaValue.string(item["title"]) ?? "",
                  subtitle: MangaValue.string(item["subtitle"]) ?? MangaValue.string(item["subTitle"]) ?? "",
                  cover: MangaValue.string(item["cover"]) ?? "", tags: MangaValue.strings(item["tags"]),
                  description: MangaValue.string(item["description"]) ?? "", stars: MangaValue.double(item["stars"]))
    }
    static func list(_ value: Any?, source: String) -> [MangaComic] {
        var seen = Set<String>()
        return (value as? [Any] ?? []).compactMap { MangaComic($0, source: source) }.filter { seen.insert($0.id).inserted }
    }
}

public struct MangaChapter: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct MangaChapterGroup: Codable, Hashable, Sendable, Identifiable {
    public var title: String
    public var chapters: [MangaChapter]
    public var id: String { title }
}

/// A comic's page (Venera's `ComicDetails`).
public struct MangaDetails: Sendable {
    public var comic: MangaComic
    public var tags: [(name: String, values: [String])]
    /// One untitled group when the source doesn't group its chapters.
    public var groups: [MangaChapterGroup]
    public var thumbnails: [String]
    public var recommend: [MangaComic]
    public var updateTime: String
    public var uploader: String
    public var url: String
    public var maxPage: Int?
    public var subId: String?
    public var isFavorite: Bool?
    /// Every chapter in reading order.
    public var chapters: [MangaChapter] { groups.flatMap(\.chapters) }
    /// A one-shot comic: Venera reads it with `loadEp(id, null)`.
    public var isSingle: Bool { chapters.isEmpty }

    init(_ value: Any?, id: String, source: String) throws {
        guard let item = value as? [String: Any] else { throw TVError.unsupported(L10n.text("The source returned no details for this comic.")) }
        var comic = MangaComic(id: id, sourceKey: source, title: MangaValue.string(item["title"]) ?? "",
                               subtitle: MangaValue.string(item["subtitle"]) ?? MangaValue.string(item["subTitle"]) ?? "",
                               cover: MangaValue.string(item["cover"]) ?? "", description: MangaValue.string(item["description"]) ?? "",
                               stars: MangaValue.double(item["stars"]))
        tags = MangaValue.pairs(item["tags"]).map { (name: $0.0, values: MangaValue.strings($0.1)) }.filter { !$0.values.isEmpty }
        comic.tags = tags.flatMap(\.values)
        self.comic = comic
        var groups: [MangaChapterGroup] = []
        var flat: [MangaChapter] = []
        for (key, value) in MangaValue.pairs(item["chapters"]) {
            if MangaValue.isMap(value) {
                let chapters = MangaValue.pairs(value).map { MangaChapter(id: $0.0, title: MangaValue.string($0.1) ?? $0.0) }
                if !chapters.isEmpty { groups.append(MangaChapterGroup(title: key, chapters: chapters)) }
            } else {
                flat.append(MangaChapter(id: key, title: MangaValue.string(value) ?? key))
            }
        }
        self.groups = flat.isEmpty ? groups : [MangaChapterGroup(title: "", chapters: flat)]
        thumbnails = MangaValue.strings(item["thumbnails"])
        recommend = MangaComic.list(item["recommend"], source: source)
        updateTime = MangaValue.string(item["updateTime"]) ?? MangaValue.string(item["uploadTime"]) ?? ""
        uploader = MangaValue.string(item["uploader"]) ?? ""
        url = MangaValue.string(item["url"]) ?? ""
        maxPage = MangaValue.int(item["maxPage"])
        subId = MangaValue.string(item["subId"])
        isFavorite = item["isFavorite"] as? Bool
    }
}

/// A page of comics; `next` is the next page number or token, nil at the end.
public struct MangaPage: Sendable {
    public var comics: [MangaComic]
    public var next: MangaCursor?
}

public enum MangaCursor: Hashable, Sendable {
    case page(Int)
    case token(String)
}

/// One part of a multi-part explore page.
public struct MangaShelf: Identifiable, Sendable {
    public var title: String
    public var comics: [MangaComic]
    public var viewMore: MangaJump?
    public var id: String { title + "\(comics.first?.id ?? "")" }
}

/// Where a "View more" button or a tag leads (Venera's PageJumpTarget).
public enum MangaJump: Hashable, Sendable {
    case search(String)
    case category(String, param: String?)

    init?(_ value: Any?) {
        if let text = value as? String {
            let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            if parts[0] == "search" { self = .search(parts[1]); return }
            if parts[0] == "category" {
                let pieces = parts[1].split(separator: "@", maxSplits: 1).map(String.init)
                self = .category(pieces[0], param: pieces.count > 1 ? pieces[1] : nil); return
            }
            return nil
        }
        guard let item = value as? [String: Any] else { return nil }
        let page = MangaValue.string(item["page"]) ?? MangaValue.string(item["action"])
        let attributes = item["attributes"] as? [String: Any] ?? [:]
        switch page {
        case "search": self = .search(MangaValue.string(attributes["keyword"]) ?? MangaValue.string(attributes["text"]) ?? MangaValue.string(item["keyword"]) ?? "")
        case "category": self = .category(MangaValue.string(attributes["category"]) ?? MangaValue.string(item["keyword"]) ?? "",
                                          param: MangaValue.string(attributes["param"]) ?? MangaValue.string(item["param"]))
        default: return nil
        }
    }
}

/// What an installed source offers, as its script describes itself.
public struct MangaSourceInfo: Sendable {
    public struct ExplorePage: Sendable, Hashable { public var title: String; public var type: String; public var paged: Bool }
    public struct Option: Sendable, Hashable {
        public var type: String
        public var label: String
        public var choices: [(value: String, text: String)]
        public var defaultValue: String?
        public static func == (a: Option, b: Option) -> Bool { a.label == b.label && a.choices.map(\.value) == b.choices.map(\.value) }
        public func hash(into hasher: inout Hasher) { hasher.combine(label); hasher.combine(choices.map(\.value)) }
    }
    public struct CategoryPart: Sendable, Hashable {
        public var name: String
        public var itemType: String
        public var categories: [String]
        public var params: [String?]
    }
    public struct Setting: Sendable, Hashable {
        public var key: String
        public var title: String
        public var type: String
        public var options: [String]
        public var optionTexts: [String]
        public var defaultValue: String?
    }
    public var name: String
    public var key: String
    public var version: String
    public var explore: [ExplorePage]
    public var categoryTitle: String?
    public var categoryParts: [CategoryPart]
    public var categoryOptions: [Option]
    public var rankingOptions: [(value: String, text: String)]
    public var hasCategoryComics: Bool
    public var canSearch: Bool
    public var searchPaged: Bool
    public var searchOptions: [Option]
    public var settings: [Setting]
    public var canSignIn: Bool
    public var cookieFields: [String]
    public var signInPage: String?
    public var hasImageConfig: Bool
    public var hasThumbnailConfig: Bool
    public var hasThumbnails: Bool
    public var translation: [String: String]

    public func text(_ key: String) -> String { translation[key] ?? key }

    init(_ value: Any?) throws {
        guard let item = value as? [String: Any], let key = MangaValue.string(item["key"]) else { throw TVError.unsupported(L10n.text("This is not a Venera comic source.")) }
        self.key = key
        name = MangaValue.string(item["name"]) ?? key
        version = MangaValue.string(item["version"]) ?? ""
        translation = (item["translation"] as? [String: Any] ?? [:]).compactMapValues { MangaValue.string($0) }
        explore = (item["explore"] as? [[String: Any]] ?? []).map { ExplorePage(title: MangaValue.string($0["title"]) ?? "", type: MangaValue.string($0["type"]) ?? "", paged: $0["paged"] as? Bool ?? true) }
        let category = item["category"] as? [String: Any]
        categoryTitle = category.flatMap { MangaValue.string($0["title"]) }
        categoryParts = (category?["parts"] as? [[String: Any]] ?? []).map { part in
            let categories = MangaValue.strings(part["categories"])
            let params = (part["categoryParams"] as? [Any]).map { $0.map { MangaValue.string($0) } } ?? Array(repeating: nil, count: categories.count)
            return CategoryPart(name: MangaValue.string(part["name"]) ?? "", itemType: MangaValue.string(part["itemType"]) ?? "category", categories: categories, params: params)
        }
        let comics = item["categoryComics"] as? [String: Any]
        hasCategoryComics = comics != nil
        categoryOptions = Self.options(comics?["optionList"])
        rankingOptions = MangaValue.strings((comics?["ranking"] as? [String: Any])?["options"]).map(Self.choice)
        let search = item["search"] as? [String: Any]
        canSearch = search != nil
        searchPaged = search?["paged"] as? Bool ?? true
        searchOptions = Self.options(search?["optionList"])
        settings = (item["settings"] as? [[String: Any]] ?? []).compactMap { setting in
            guard let key = MangaValue.string(setting["key"]) else { return nil }
            let options = setting["options"] as? [[String: Any]] ?? []
            return Setting(key: key, title: MangaValue.string(setting["title"]) ?? key, type: MangaValue.string(setting["type"]) ?? "input",
                           options: options.compactMap { MangaValue.string($0["value"]) }, optionTexts: options.compactMap { MangaValue.string($0["text"]) ?? MangaValue.string($0["value"]) },
                           defaultValue: MangaValue.string(setting["default"]))
        }
        let account = item["account"] as? [String: Any]
        canSignIn = account?["login"] as? Bool ?? false
        cookieFields = MangaValue.strings(account?["cookieFields"])
        signInPage = account.flatMap { MangaValue.string($0["webview"]) }
        let comic = item["comic"] as? [String: Any] ?? [:]
        hasImageConfig = comic["imageConfig"] as? Bool ?? false
        hasThumbnailConfig = comic["thumbnailConfig"] as? Bool ?? false
        hasThumbnails = comic["thumbnails"] as? Bool ?? false
    }

    /// "value-Text" as Venera writes options; a bare value is its own text.
    static func choice(_ text: String) -> (value: String, text: String) {
        guard let dash = text.firstIndex(of: "-") else { return (text, text) }
        return (String(text[..<dash]), String(text[text.index(after: dash)...]))
    }
    private static func options(_ value: Any?) -> [Option] {
        (value as? [[String: Any]] ?? []).map { item in
            Option(type: MangaValue.string(item["type"]) ?? "select", label: MangaValue.string(item["label"]) ?? "",
                   choices: MangaValue.strings(item["options"]).map(choice), defaultValue: MangaValue.string(item["default"]))
        }.filter { !$0.choices.isEmpty }
    }
}

/// Loose readers for what scripts return: numbers as text, Maps as {"__map": [[k, v]]}.
enum MangaValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            return double.rounded() == double && abs(double) < 1e15 ? String(Int64(double)) : String(double)
        default: return nil
        }
    }
    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? string(value).flatMap { Int($0) } }
    static func double(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? string(value).flatMap { Double($0) } }
    static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { string($0) } }
        if let text = value as? String, !text.isEmpty { return [text] }
        return []
    }
    static func isMap(_ value: Any?) -> Bool {
        guard let item = value as? [String: Any] else { return false }
        return true && (item["__bytes"] == nil)
    }
    /// The entries of a Map or a plain object, in order.
    static func pairs(_ value: Any?) -> [(String, Any)] {
        guard let item = value as? [String: Any] else { return [] }
        if let entries = item["__map"] as? [[Any]] {
            return entries.compactMap { pair in pair.count == 2 ? string(pair[0]).map { ($0, pair[1]) } : nil }
        }
        if let keys = item["__keys"] as? [String] { return keys.compactMap { key in item[key].map { (key, $0) } } }
        return item.keys.filter { $0 != "__keys" }.sorted { a, b in
            if let x = Int(a), let y = Int(b) { return x < y }
            return a < b
        }.map { ($0, item[$0]!) }
    }
}
