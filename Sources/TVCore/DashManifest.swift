import Foundation

/// A DASH manifest (MPD) whose representations each live in one file with a `sidx` index (`SegmentBase`), as
/// Bilibili's are and as a Bili plugin's proxy describes them (`/proxy?do=bili…`, `application/dash+xml`). AVPlayer
/// opens no MPD ("Cannot Open", -11828), so it becomes the `dash` a play result can carry and plays as local HLS
/// through `DashStreams`, the way Yingxia's own Bilibili source does. Manifests whose segments are listed or templated
/// (`SegmentList`, `SegmentTemplate`) are not read here.
public enum DashManifest {
    /// Whether `head`, a document's first bytes, is an MPD.
    public static func names(_ head: Data) -> Bool {
        let text = String(decoding: head.prefix(2048), as: UTF8.self)
        return text.range(of: "<MPD", options: .caseInsensitive) != nil
    }

    /// The `dash` play result for `DashStreams.stream`: `video` and `audio` representations with their addresses
    /// (resolved against the manifest's `BaseURL`s and `url`), byte ranges and attributes, and `duration` in seconds.
    /// Nil when the manifest has no representation with an index.
    public static func dash(_ data: Data, url: URL) -> [String: JSONValue]? {
        let reader = Reader(base: url)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        guard parser.parse() || !reader.representations.isEmpty else { return nil }
        var video: [JSONValue] = [], audio: [JSONValue] = []
        for (position, item) in reader.representations.enumerated() {
            guard let index = item.indexRange, let initialization = item.initialization, !item.urls.isEmpty, let codecs = item.codecs else { continue }
            let isAudio = item.kind == "audio" || item.kind == nil && Self.audioCodec(codecs)
            // DashStreams keys qualities by number: Bilibili's ids (80, 112...) are numbers; another manifest's
            // ids may not be, and its picture height (or its order) stands in.
            let quality = Int(item.id ?? "") ?? (isAudio ? 30_000 + position : (item.height ?? 0) > 0 ? item.height! : position + 1)
            var fields: [String: JSONValue] = [
                "id": .number(Double(quality)), "codecs": .string(codecs), "bandwidth": .number(Double(item.bandwidth ?? 0)),
                "urls": .array(item.urls.map { .string($0.absoluteString) }),
                "initialization": .string(initialization), "indexRange": .string(index),
            ]
            if let width = item.width { fields["width"] = .number(Double(width)) }
            if let height = item.height { fields["height"] = .number(Double(height)) }
            if let rate = item.frameRate { fields["frameRate"] = .string(rate) }
            if isAudio { audio.append(.object(fields)) } else { video.append(.object(fields)) }
        }
        guard !video.isEmpty else { return nil }
        var dash: [String: JSONValue] = ["video": .array(video), "audio": .array(audio)]
        if let seconds = reader.duration.flatMap(Self.seconds) { dash["duration"] = .string(String(seconds)) }
        return dash
    }

    static func audioCodec(_ codecs: String) -> Bool {
        let codec = codecs.lowercased()
        return ["mp4a", "ac-3", "ec-3", "flac", "fla", "opus", "alac", "dtsc", "mha1"].contains { codec.hasPrefix($0) }
    }

    /// Seconds in an ISO 8601 duration such as `PT1H2M3.5S`.
    static func seconds(_ text: String) -> Double? {
        guard let match = text.uppercased().firstMatch(of: /^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$/) else { return nil }
        let days = match.1.flatMap { Double($0) } ?? 0, hours = match.2.flatMap { Double($0) } ?? 0
        let minutes = match.3.flatMap { Double($0) } ?? 0, seconds = match.4.flatMap { Double($0) } ?? 0
        let total = days * 86400 + hours * 3600 + minutes * 60 + seconds
        return total > 0 ? total : nil
    }

    private struct Item {
        var id: String?, codecs: String?, kind: String?
        var width: Int?, height: Int?, bandwidth: Int?, frameRate: String?
        var urls: [URL] = []
        var indexRange: String?, initialization: String?
    }

    /// Reads the elements that matter, keeping the `BaseURL`s and attributes each level hands down.
    private final class Reader: NSObject, XMLParserDelegate {
        let base: URL
        var representations: [Item] = []
        var duration: String?
        /// The open elements, each with the attributes it hands down and its `BaseURL`s.
        private var stack: [(name: String, attributes: [String: String], bases: [String])] = []
        private var text = ""
        private var current: Item?
        init(base: URL) { self.base = base }

        private static func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            let name = Self.local(elementName)
            text = ""
            switch name {
            case "MPD": duration = attributes["mediaPresentationDuration"]
            case "Representation":
                var item = Item()
                func inherited(_ key: String) -> String? { attributes[key] ?? stack.reversed().lazy.compactMap { $0.attributes[key] }.first }
                item.id = attributes["id"]
                item.codecs = inherited("codecs")
                let mime = inherited("mimeType") ?? ""
                let type = inherited("contentType") ?? ""
                item.kind = mime.hasPrefix("audio") || type == "audio" ? "audio" : mime.hasPrefix("video") || type == "video" ? "video" : nil
                item.width = inherited("width").flatMap { Int($0) }
                item.height = inherited("height").flatMap { Int($0) }
                item.bandwidth = attributes["bandwidth"].flatMap { Int($0) }
                item.frameRate = inherited("frameRate")
                current = item
            case "ContentComponent":
                // Bili plugins name the kind here: <ContentComponent contentType="video" mimeType="video/mp4"/>.
                if let type = attributes["contentType"], let index = stack.lastIndex(where: { $0.name == "AdaptationSet" }), stack[index].attributes["contentType"] == nil {
                    stack[index].attributes["contentType"] = type
                }
            case "SegmentBase":
                current?.indexRange = attributes["indexRange"]
            case "Initialization":
                if let range = attributes["range"] { current?.initialization = range }
            default: break
            }
            stack.append((name, attributes, []))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            let name = Self.local(elementName)
            guard let closed = stack.popLast() else { return }
            if name == "BaseURL" {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !stack.isEmpty { stack[stack.count - 1].bases.append(value) }
            } else if name == "Representation", var item = current {
                item.urls = addresses(closed.bases)
                representations.append(item)
                current = nil
            }
            text = ""
        }

        /// A representation's addresses: each of its own `BaseURL`s (Bilibili lists the backups too) resolved against
        /// the nearest outer one and the manifest's address; with none of its own, the outer one.
        private func addresses(_ own: [String]) -> [URL] {
            var outer = base
            for level in stack { if let first = level.bases.first, let url = URL(string: first, relativeTo: outer)?.absoluteURL { outer = url } }
            let resolved = own.isEmpty ? [outer] : own.compactMap { URL(string: $0, relativeTo: outer)?.absoluteURL }
            return resolved.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0 != base }
        }
    }
}
