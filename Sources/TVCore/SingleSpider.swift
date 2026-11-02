import Foundation

extension Site {
    /// A CatVod JavaScript spider that runs on its own: it hands the host a spider object
    /// (`__JS_SPIDER__`, `__jsEvalReturn` or a default export) with the usual methods. A drpy rule
    /// (`var rule = {...}`) needs a drpy engine beside it and is not one.
    static func isJavaScriptSpider(_ data: Data) -> Bool {
        guard !data.starts(with: Data("PK".utf8)) else { return false }
        let text = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
        guard let first = text.first(where: { !$0.isWhitespace && $0 != "\u{FEFF}" }), first != "<", first != "{", first != "[" else { return false }
        return text.contains(#/__JS_SPIDER__|__jsEvalReturn|export[ \t]+default/#) && text.contains(#/\b(detail|category|homeContent|detailContent)\b/#)
    }

    /// The name a Python spider gives itself in `getName`, when it returns a plain string.
    static func pythonSpiderName(_ data: Data) -> String? {
        let text = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
        guard let match = text.firstMatch(of: #/def[ \t]+getName[ \t]*\([ \t]*self[ \t]*\)[ \t]*:\s*return[ \t]+["']([^"'\n]{1,40})["']/#) else { return nil }
        let name = String(match.1).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

extension Subscription {
    /// A lone spider script, a Python `base.spider` class or a CatVod JavaScript spider, added as
    /// a subscription of its own that holds just that source, as a TVBox configuration would list
    /// it: type 3, with the script's address as its api. Nil when `data` is neither.
    static func singleSpider(_ data: Data, origin: URL) -> Subscription? {
        let runtime: SourceRuntime
        if Site.sniffedRuntime(data) == .python { runtime = .python }
        else if Site.isJavaScriptSpider(data) { runtime = .javascript }
        else { return nil }
        let file = origin.deletingPathExtension().lastPathComponent
        let key = file.isEmpty || file == "/" ? "spider" : file
        let name = (runtime == .python ? Site.pythonSpiderName(data) : nil) ?? key
        let api = origin.absoluteString
        let raw: [String: JSONValue] = ["key": .string(key), "name": .string(name), "type": .number(3), "api": .string(api),
                                        "searchable": .number(1), "quickSearch": .number(1), "filterable": .number(1)]
        var site = Site(key: key, name: name, type: 3, api: api, raw: raw)
        // An address that names no `.py` or `.js` file runs as what its content showed.
        if site.runtime != runtime { site.detectedRuntime = runtime }
        return Subscription(origin: origin, importedAt: Date(), sites: [site], lives: [], raw: ["sites": .array([.object(raw)])])
    }
}

/// Spiders and subscriptions the viewer added from a file on this device. Each is copied into the
/// app's storage and gets an address on a reserved host (`.invalid` never resolves, RFC 2606), so
/// subscriptions, sources and the script hosts read it as they read a download, and the address
/// stays the same when an update moves the app's container.
public enum ImportedFiles {
    static let host = "files.yingxia.invalid"
    static var directory: URL {
        #if os(tvOS)
        URL.cachesDirectory.appending(path: "ImportedFiles", directoryHint: .isDirectory)
        #else
        URL.applicationSupportDirectory.appending(path: "ImportedFiles", directoryHint: .isDirectory)
        #endif
    }

    /// Copies a picked file in, replacing an earlier copy of the same name, and returns its address.
    public static func add(_ file: URL) throws -> URL {
        let name = file.lastPathComponent.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !name.isEmpty else { throw TVError.invalidURL }
        let data = try Data(contentsOf: file)
        guard data.count <= 20_000_000 else { throw TVError.unsupported(L10n.text("The playlist exceeds 20 MB. Use a smaller subscription.")) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: name), options: .atomic)
        return address(name)
    }

    /// Deletes the copy behind an address on the reserved host; any other address is left alone.
    public static func remove(_ address: String) {
        guard let url = URL(string: address), let file = file(for: url) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    public static func isImported(_ address: String) -> Bool { URL(string: address)?.host()?.lowercased() == host }

    static func address(_ name: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = "/" + name
        return components.url!
    }

    /// The copy behind an address on the reserved host: one file, straight in the folder.
    private static func file(for url: URL) -> URL? {
        guard url.host()?.lowercased() == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 1, let name = parts.first, !name.hasPrefix(".") else { return directory.appending(path: ".missing") }
        return directory.appending(path: name)
    }

    /// What an address on the reserved host holds; nil for every other address, which loads as usual.
    static func data(at url: URL) throws -> Data? {
        guard let file = file(for: url) else { return nil }
        guard let data = try? Data(contentsOf: file) else { throw TVError.unsupported(L10n.text("This file is no longer on this device. Add it again.")) }
        return data
    }
}
