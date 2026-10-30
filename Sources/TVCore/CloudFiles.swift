import Foundation

/// A file or folder in Cloud Files: on a signed-in Quark or UC drive, an AList server, a WebDAV share
/// or an Emby or Jellyfin server.
public struct CloudFile: Identifiable, Hashable, Codable, Sendable {
    /// Quark, UC, Emby and Jellyfin: the drive's file id. AList and WebDAV: the file's full path.
    public let id: String
    public let name: String
    public let isFolder: Bool
    public let size: Int64
    public let modified: Date?
    /// The poster or still a media server keeps for the item.
    public let artwork: URL?
    public init(id: String, name: String, isFolder: Bool, size: Int64 = 0, modified: Date? = nil, artwork: URL? = nil) {
        self.id = id; self.name = name; self.isFolder = isFolder; self.size = size; self.modified = modified; self.artwork = artwork
    }

    public enum Kind: Sendable { case folder, video, audio, image, subtitle, other }
    public var kind: Kind { isFolder ? .folder : Self.kind(of: name) }
    public var isPlayable: Bool { kind == .video || kind == .audio }

    public static func kind(of name: String) -> Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "mkv", "ts", "m2ts", "mts", "avi", "flv", "f4v", "wmv", "webm", "rmvb", "rm",
             "mpg", "mpeg", "3gp", "vob", "m3u8": .video
        case "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "ape", "ogg", "opus", "wma": .audio
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp": .image
        case "srt", "ass", "ssa", "vtt", "sub": .subtitle
        default: .other
        }
    }
    /// Containers that play as the drive stores them: those AVPlayer opens, and those `Remux` repackages for it.
    static func playsOriginal(_ name: String) -> Bool { playsNatively(name) || Remux.handles(name: name) }

    /// Containers Apple devices open as they are.
    static func playsNatively(_ name: String) -> Bool {
        ["mp4", "m4v", "mov", "ts", "m2ts", "mts", "m3u8", "mp3", "m4a", "aac", "flac", "wav", "aif", "aiff"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    /// Folders first, then names in Finder order, so "第2集" comes before "第10集".
    public static func arranged(_ files: [CloudFile]) -> [CloudFile] {
        files.sorted { $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Where Cloud Files browses: a drive signed in under Cloud Drive Accounts, or a saved AList server, WebDAV
/// share or Emby or Jellyfin server.
public enum CloudFilesDrive: Hashable, Identifiable, Sendable {
    case quark, uc, alist(AListServer)
    public var id: String { key }
    /// Names the drive in a file's address and in playback history.
    public var key: String {
        switch self {
        case .quark: "quark"
        case .uc: "uc"
        case .alist(let server): "alist." + server.id
        }
    }
    public var name: String {
        switch self {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .alist(let server): server.name
        }
    }
    /// Whether `file` plays from this drive: Quark and UC also transcode videos in containers that don't play
    /// as they are; an AList server, WebDAV share or media server hands over the file as it is.
    public func plays(_ file: CloudFile) -> Bool {
        switch self {
        case .quark, .uc: file.kind == .video || (file.kind == .audio && CloudFile.playsNatively(file.name))
        case .alist: file.isPlayable && (CloudFile.playsNatively(file.name) || (file.kind == .video && CloudFile.playsOriginal(file.name)))
        }
    }

    /// The folder browsing starts in.
    public var root: String {
        if case .alist(let server) = self { return server.root }
        return "0"
    }
}

public enum CloudFilesError: LocalizedError, Equatable, Sendable {
    /// The drive's sign-in is missing or has expired, or the AList server wants an account.
    case signInRequired(String)
    /// The AList folder is protected by a password, or the one given was wrong.
    case passwordRequired
    case unsupportedFormat(String)
    public var errorDescription: String? {
        switch self {
        case .signInRequired(let drive): L10n.text("Sign in to %@ to browse its files.", drive)
        case .passwordRequired: L10n.text("This folder is protected by a password.")
        case .unsupportedFormat(let type): L10n.text("Apple devices can't play %@ files.", type.uppercased())
        }
    }
}

/// Browsing cloud drives and AList servers, and playing their files. A file plays through a
/// `tvbox-files:` address that the player prepares like a plugin's cloud-drive stream: straight from
/// the drive's CDN through `CloudStreams`.
public enum CloudFiles {
    public static let scheme = "tvbox-files"
    /// The source key playback history keeps for files played from Cloud Files.
    public static let sourceKey = "builtin.files"

    /// Signed-in Quark and UC, then the saved AList servers.
    public static func drives() -> [CloudFilesDrive] {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        var drives: [CloudFilesDrive] = []
        if !accounts.quarkCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { drives.append(.quark) }
        if !accounts.ucCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { drives.append(.uc) }
        return drives + AListServers.load().map(CloudFilesDrive.alist)
    }

    public static func drive(key: String) -> CloudFilesDrive? {
        switch key {
        case "quark": return .quark
        case "uc": return .uc
        default:
            guard key.hasPrefix("alist.") else { return nil }
            let id = String(key.dropFirst(6))
            return AListServers.load().first { $0.id == id }.map(CloudFilesDrive.alist)
        }
    }

    /// A folder's files and folders, folders first. `password` opens a protected AList folder.
    public static func list(_ drive: CloudFilesDrive, folder: String, password: String? = nil) async throws -> [CloudFile] {
        let files: [CloudFile]
        switch drive {
        case .quark: files = try await QuarkFiles.quark.list(folder)
        case .uc: files = try await QuarkFiles.uc.list(folder)
        case .alist(let server) where server.isWebDAV: files = try await WebDAV.shared.list(server, path: folder)
        case .alist(let server) where server.isEmby: files = try await Emby.shared.list(server, id: folder)
        case .alist(let server): files = try await AList.shared.list(server, path: folder, password: password)
        }
        return CloudFile.arranged(files)
    }

    /// The channel that plays `file`. Its history entry is the folder's, as a series is one entry
    /// with an episode, so Continue Watching picks the folder up at the file last played.
    public static func channel(_ file: CloudFile, in drive: CloudFilesDrive, folder: String, folderName: String,
                               resumePosition: Double? = nil) -> Channel {
        let context = PlaybackHistoryContext(origin: URL(string: "\(scheme)://\(drive.key)")!, sourceKey: sourceKey, sourceName: drive.name,
                                             videoID: folder, videoName: folderName, episodeID: file.id, episodeName: file.name,
                                             episodeFlag: drive.key)
        return channel(context, resumePosition: resumePosition)
    }

    /// The channel a history entry of a Cloud Files folder resumes.
    public static func channel(_ context: PlaybackHistoryContext, resumePosition: Double? = nil) -> Channel {
        var address = URLComponents()
        address.scheme = scheme; address.host = "file"
        address.queryItems = [URLQueryItem(name: "drive", value: context.episodeFlag), URLQueryItem(name: "id", value: context.episodeID),
                              URLQueryItem(name: "name", value: context.episodeName)]
        return Channel(name: context.episodeName, group: context.sourceName, url: address.url!, skipScope: context.id,
                       historyContext: context, resumePosition: resumePosition)
    }

    public static func isFile(_ url: URL) -> Bool { url.scheme == scheme }

    /// The address AVPlayer opens for a `tvbox-files:` address: the file streamed from its drive.
    public static func prepare(_ url: URL) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let key = value("drive"), let id = value("id"), let name = value("name") else { throw TVError.invalidURL }
        guard let drive = drive(key: key) else {
            throw TVError.unsupported(L10n.text("This file's drive is no longer in Cloud Files."))
        }
        switch drive {
        case .quark: return try await QuarkFiles.quark.stream(id, name: name)
        case .uc: return try await QuarkFiles.uc.stream(id, name: name)
        case .alist(let server) where server.isWebDAV: return try await WebDAV.shared.stream(server, path: id, name: name)
        case .alist(let server) where server.isEmby: return try await Emby.shared.stream(server, id: id, name: name)
        case .alist(let server): return try await AList.shared.stream(server, path: id, name: name)
        }
    }
}
