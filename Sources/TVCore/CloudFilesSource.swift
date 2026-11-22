import Foundation

/// Each drive in Cloud Files as a source of its own, so Global Search asks it beside the subscription's
/// sources: Quark and UC search the account's files, an AList server its search index, an Emby or Jellyfin
/// server its libraries. Its page browses the drive as TVBox's drive spiders do, a folder opening as a
/// listing. A folder a search finds opens as a video: its episodes are the files it holds, then each
/// subfolder's as a line of its own, so a series lists its seasons. WebDAV has no search, so its shares
/// stay in Cloud Files.
public enum CloudFilesSource {
    static let keyPrefix = "builtin.files."
    static let api = "csp_YingxiaCloudFiles"
    static let pageSize = 50
    /// Subfolders a folder's details look into.
    static let subfolderLimit = 20

    /// The sources of the drives in Cloud Files now.
    public static func sites() -> [Site] { CloudFiles.drives().filter(\.searches).map(site) }

    static func site(_ drive: CloudFilesDrive) -> Site {
        let key = keyPrefix + drive.key, name = L10n.text("My %@", drive.name)
        let raw: [String: JSONValue] = ["key": .string(key), "name": .string(name), "type": .number(3), "api": .string(api),
                                        "searchable": .number(1), "quickSearch": .number(1)]
        return Site(key: key, name: name, type: 3, api: api, raw: raw)
    }

    /// Answers a spider request (`play`, `ids`, `wd`, a folder's `t`, or the home page) in TVBox's JSON.
    static func request(_ site: Site, params: [String: String]) async throws -> [String: JSONValue] {
        guard let drive = CloudFiles.drive(key: String(site.key.dropFirst(keyPrefix.count))) else {
            throw TVError.unsupported(L10n.text("This file's drive is no longer in Cloud Files."))
        }
        if let address = params["play"] {
            guard let entry = Entry(address), !entry.isFolder else { throw TVError.invalidURL }
            let url = try await CloudFiles.stream(drive, id: entry.id, name: entry.name)
            return ["parse": .number(0), "url": .string(url.absoluteString)]
        }
        if let ids = params["ids"] {
            guard let entry = Entry(ids) else { throw TVError.invalidURL }
            return ["list": .array([.object(try await details(entry, in: drive))])]
        }
        let page = max(1, Int(params["pg"] ?? "") ?? 1)
        if let query = params["wd"], !query.isEmpty {
            let found = try await search(query, in: drive, page: page)
            return ["list": .array(found.files.map { .object(video($0, opensAsListing: false)) }), "pagecount": .number(Double(found.pages))]
        }
        // An Emby or Jellyfin film or series library lists a page at a time (#1208).
        if case .alist(let server) = drive, server.isEmby {
            let folder = params["t"].flatMap(Entry.init)?.id ?? drive.root
            let found = try await Emby.shared.page(server, id: folder, page: page, size: pageSize)
            let files = CloudFile.arranged(found.files).filter { $0.isFolder || drive.plays($0) }
            return ["class": .array([]), "list": .array(files.map { .object(video($0, opensAsListing: true)) }), "pagecount": .number(Double(found.pages))]
        }
        // The home page is the drive's first folder; a folder lists in one page.
        guard page == 1 else { return ["list": .array([]), "pagecount": .number(1)] }
        let folder = params["t"].flatMap(Entry.init)?.id ?? drive.root
        let files = try await CloudFiles.list(drive, folder: folder).filter { $0.isFolder || drive.plays($0) }
        return ["class": .array([]), "list": .array(files.map { .object(video($0, opensAsListing: true)) }), "pagecount": .number(1)]
    }

    /// Folders and the files that play here, whose names hold `query`.
    static func search(_ query: String, in drive: CloudFilesDrive, page: Int) async throws -> (files: [CloudFile], pages: Int) {
        let found: (files: [CloudFile], total: Int)
        switch drive {
        case .quark: found = try await QuarkFiles.quark.search(query, page: page, size: pageSize)
        case .uc: found = try await QuarkFiles.uc.search(query, page: page, size: pageSize)
        case .pan115: found = try await Pan115Files.shared.search(query, page: page, size: pageSize)
        case .baidu: found = try await BaiduFiles.shared.search(query, page: page, size: pageSize)
        case .tianyi: found = try await TianyiFiles.shared.search(query, page: page, size: pageSize)
        case .pan123: found = try await Pan123Files.shared.search(query, page: page, size: pageSize)
        // Guangya's web page has no search to ask.
        case .guangya: return ([], 1)
        case .alist(let server) where server.isWebDAV: return ([], 1)
        case .alist(let server) where server.isEmby: found = try await Emby.shared.search(server, query, page: page, size: pageSize)
        case .alist(let server) where server.isFnOS: found = try await FnOS.shared.search(server, query, page: page, size: pageSize)
        case .alist(let server): found = try await AList.shared.search(server, query, page: page, size: pageSize)
        }
        return (found.files.filter { $0.isFolder || drive.plays($0) }, max(1, (found.total + pageSize - 1) / pageSize))
    }

    /// A list entry. A folder found by a search opens as details; one met while browsing, as a listing.
    static func video(_ file: CloudFile, opensAsListing: Bool) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["vod_id": .string(Entry(file).token), "vod_name": .string(title(file))]
        if let artwork = file.artwork { fields["vod_pic"] = .string(artwork.absoluteString) }
        if file.isFolder, opensAsListing { fields["vod_tag"] = .string("folder") }
        if !file.isFolder, file.size > 0 { fields["vod_remarks"] = .string(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)) }
        return fields
    }

    /// A file is one episode. A folder's are the files in it that play here, then each subfolder's as a line.
    static func details(_ entry: Entry, in drive: CloudFilesDrive) async throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["vod_id": .string(entry.token), "vod_name": .string(title(entry.file))]
        // The title its name gives, for the page and for its TMDB lookup (#1220, #1333): "The.Silent.Storm.2026.S01.2160p"
        // is The Silent Storm · Season 1, from 2026. The name itself stays in the remarks, where the lookup reads it too.
        let name = MediaName(entry.name, isFile: !entry.isFolder)
        if name.isTitle {
            let season = name.season.map { L10n.text("Season %@", String($0)) }
            fields["vod_name"] = .string([name.title, season].compactMap { $0 }.joined(separator: " "))
            fields["vod_remarks"] = .string(title(entry.file))
            if let year = name.year { fields["vod_year"] = .string(String(year)) }
        }
        guard entry.isFolder else {
            fields["vod_play_from"] = .string(lineName(drive.name)); fields["vod_play_url"] = .string(episode(entry.file))
            return fields
        }
        let files = try await CloudFiles.list(drive, folder: entry.id)
        let subfolders = Array(files.filter(\.isFolder).prefix(subfolderLimit))
        let inside = await withTaskGroup(of: (Int, [CloudFile]).self) { group in
            for (index, folder) in subfolders.enumerated() {
                group.addTask { (index, (try? await CloudFiles.list(drive, folder: folder.id)) ?? []) }
            }
            var lists = [[CloudFile]](repeating: [], count: subfolders.count)
            for await (index, list) in group { lists[index] = list }
            return lists
        }
        let lines = playlist(entry.name, files, subfolders: zip(subfolders, inside).map { (name: $0.name, files: $1) }, drive: drive)
        guard !lines.isEmpty else {
            // The kinds of file it held, so a report says why nothing plays.
            let types = Dictionary(grouping: (files + inside.joined()).filter { !$0.isFolder }) { ($0.name as NSString).pathExtension.lowercased() }
                .map { "\($0.key.isEmpty ? "-" : $0.key)×\($0.value.count)" }.sorted().joined(separator: " ")
            Diagnostics.shared.record(.warning, "files", "nothing plays folders=\(subfolders.count) files=\(types.isEmpty ? "none" : types)")
            throw TVError.unsupported(L10n.text("This folder has no videos Apple devices can play."))
        }
        fields["vod_play_from"] = .string(lines.map { lineName($0.name) }.joined(separator: "$$$"))
        fields["vod_play_url"] = .string(lines.map { $0.files.map(episode).joined(separator: "#") }.joined(separator: "$$$"))
        return fields
    }

    /// The folder's own files, then each subfolder's, leaving out those with nothing that plays here.
    static func playlist(_ name: String, _ files: [CloudFile], subfolders: [(name: String, files: [CloudFile])],
                         drive: CloudFilesDrive) -> [(name: String, files: [CloudFile])] {
        ([(name: name, files: files)] + subfolders).map { line in (name: line.name, files: line.files.filter { !$0.isFolder && drive.plays($0) }) }
            .filter { !$0.files.isEmpty }
    }

    /// A drive's folder or video as a title of its source: a folder's page lists its videos, then each subfolder's as a line,
    /// and finds the title on TMDB (#880).
    public static func titleVideo(_ file: CloudFile, poster: URL? = nil) -> Video {
        Video(id: Entry(file).token, name: title(file), poster: poster ?? file.artwork)
    }

    /// The folder or file a listed title of a drive's source is, with the artwork its drive keeps.
    public static func file(of video: Video) -> CloudFile? {
        Entry(video.id).map { CloudFile(id: $0.id, name: $0.name, isFolder: $0.isFolder, artwork: video.poster) }
    }

    /// The source a drive's titles open from, in Cloud Files too: WebDAV shares aren't among the subscription's sources.
    public static func client(_ drive: CloudFilesDrive, origin: URL) -> CatalogClient {
        CatalogClient(site: site(drive), origin: origin)
    }

    /// The drive a source of Cloud Files browses.
    public static func drive(of site: Site) -> CloudFilesDrive? { drive(sourceKey: site.key) }

    /// The drive behind a source key that history or favorites kept.
    public static func drive(sourceKey: String) -> CloudFilesDrive? {
        sourceKey.hasPrefix(keyPrefix) ? CloudFiles.drive(key: String(sourceKey.dropFirst(keyPrefix.count))) : nil
    }

    static func episode(_ file: CloudFile) -> String { lineName(title(file)) + "$" + Entry(file).token }
    /// A file's name without its extension.
    static func title(_ file: CloudFile) -> String { file.isFolder ? file.name : (file.name as NSString).deletingPathExtension }
    /// TVBox's play lists separate episodes with `#` and names from addresses with `$`.
    static func lineName(_ name: String) -> String {
        name.replacingOccurrences(of: "$", with: "＄").replacingOccurrences(of: "#", with: "＃")
    }

    /// A file or folder as a video or episode id: its kind, id and name, so details and playback find it
    /// without listing its folder again.
    struct Entry: Equatable {
        let id: String, name: String, isFolder: Bool
        init(_ file: CloudFile) { id = file.id; name = file.name; isFolder = file.isFolder }
        init?(_ token: String) {
            let parts = token.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "d" || parts[0] == "f", let id = parts[1].removingPercentEncoding, !id.isEmpty,
                  let name = parts[2].removingPercentEncoding else { return nil }
            self.id = id; self.name = name; isFolder = parts[0] == "d"
        }
        var token: String { [isFolder ? "d" : "f", Self.escape(id), Self.escape(name)].joined(separator: "|") }
        var file: CloudFile { CloudFile(id: id, name: name, isFolder: isFolder) }
        private static let kept = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))
        private static func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: kept) ?? text }
    }
}

extension Site {
    /// A drive in Cloud Files, searched and browsed as a source.
    public var isCloudFiles: Bool { key.hasPrefix(CloudFilesSource.keyPrefix) }
}

extension CloudFilesDrive {
    /// Whether its files can be searched: all but WebDAV shares.
    public var searches: Bool {
        if case .alist(let server) = self { return !server.isWebDAV }
        return true
    }
}
