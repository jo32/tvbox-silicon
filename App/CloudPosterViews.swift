import SwiftUI
import TVCore

/// A drive's folder or video as a poster (#880, #1465): the drive's own artwork, else the TMDB poster its name finds. One
/// that names a title opens that title's page, where its videos play with TMDB's episode names, stills and cast (#1220);
/// a folder that only sorts titles (电影, Season 1) opens as a folder, and a video nothing was found for plays.
struct CloudPosterLink<Folder: View>: View {
    let file: CloudFile
    /// The drive's source, which the title's page asks for its videos.
    let client: CatalogClient
    /// The folder holding it: a season folder's or an episode file's title is that folder's.
    var parent: String? = nil
    /// Plays a video that found no title; nil opens its page all the same.
    var play: (() -> Void)? = nil
    @ViewBuilder let folder: () -> Folder
    @State private var work: CloudPosters.Work?

    private var name: MediaName { Self.name(file, parent: parent) }
    /// A folder that names a title, or a video that found one.
    private var opensTitle: Bool {
        if file.isFolder { return work != nil && !MediaName(file.name, isFile: false).isSeasonOnly }
        return work != nil || play == nil
    }

    var body: some View {
        let label = PosterCard(name: Self.caption(file), poster: file.artwork ?? work?.poster, remarks: remarks,
                               symbol: file.isFolder ? "folder.fill" : "film")
        Group {
            if opensTitle {
                RouteLink { VideoDetailView(video: CloudFilesSource.titleVideo(file, poster: work?.poster), client: client) } label: { label }
            } else if file.isFolder {
                RouteLink { folder() } label: { label }
            } else {
                Button { play?() } label: { label }
            }
        }
        .cardButton()
        .accessibilityIdentifier("files.poster." + file.name)
        // Only cards on screen ask; one scrolled away before its turn gives the turn up.
        .task(id: file.id) { await lookUp() }
    }

    private var remarks: String {
        if !file.isFolder, file.size > 0 { return ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file) }
        return (work?.year ?? name.year).map(String.init) ?? ""
    }

    private func lookUp() async {
        let name = name
        guard name.isTitle else { return }
        // What the title's page found, or the viewer chose there, comes first: a wrong poster is fixed on that page.
        let key = TMDBMatchStore.key(source: client.site.key, video: CloudFilesSource.titleVideo(file).id)
        if let choice = await TMDBMatchStore.shared.choice(for: key), choice == TMDBMatchStore.Choice.none { return }
        if let details = await TMDBMatchStore.shared.kept(for: key)?.details {
            work = CloudPosters.Work(mediaType: details.mediaType, id: details.id, name: details.name, year: details.year, poster: details.poster)
            return
        }
        if case .some(let kept) = await CloudPosters.shared.kept(name) { work = kept; return }
        // An Emby or Jellyfin server's items come with their own artwork.
        guard file.artwork == nil else { return }
        let found = await CloudPosters.shared.work(for: name)
        if !Task.isCancelled { work = found }
    }

    /// The name looked up: a season folder's or an episode file's is the title of the folder holding it.
    static func name(_ file: CloudFile, parent: String?) -> MediaName {
        var name = MediaName(file.name, isFile: !file.isFolder)
        guard name.title.isEmpty, !name.isCategory, name.isSeries, let parent else { return name }
        let above = MediaName(parent, isFile: false)
        guard above.isTitle else { return name }
        name.title = above.title
        name.year = name.year ?? above.year
        name.season = name.season ?? above.season
        return name
    }

    /// By the title its name gives: "The Silent Storm · Season 1" for The.Silent.Storm.2026.S01.2160p, 消失的她 for
    /// [电影天堂www.dytt89.com]消失的她-2023_HD国语中字.mp4.
    static func caption(_ file: CloudFile) -> String {
        let name = MediaName(file.name, isFile: !file.isFolder)
        // A film's file by its title; an episode's by its name, which tells it from the others.
        guard file.isFolder || name.episode == nil else { return (file.name as NSString).deletingPathExtension }
        guard name.isTitle else { return file.isFolder ? file.name : (file.name as NSString).deletingPathExtension }
        return [name.title, name.season.map { L10n.text("Season %@", String($0)) }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Which Cloud Files folders show their contents as posters: the viewer's choice for each, and for a folder never chosen,
/// the one it was opened from.
enum CloudFilesLayout {
    static let key = "cloudFilesPosterFolders"
    private static let limit = 400

    static func posters(_ drive: CloudFilesDrive, folder: String, defaults: UserDefaults = .standard) -> Bool? {
        (defaults.dictionary(forKey: key) as? [String: Bool])?[drive.key + "|" + folder]
    }

    static func set(_ posters: Bool, _ drive: CloudFilesDrive, folder: String, defaults: UserDefaults = .standard) {
        var choices = defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
        choices[drive.key + "|" + folder] = posters
        if choices.count > limit { for extra in choices.keys.prefix(choices.count - limit) where extra != drive.key + "|" + folder { choices[extra] = nil } }
        defaults.set(choices, forKey: key)
    }
}
