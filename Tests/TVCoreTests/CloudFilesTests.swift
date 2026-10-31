import AVFoundation
import Foundation
import Testing
@testable import TVCore

@Suite(.serialized) struct CloudFilesTests {
    @Test func foldersComeFirstAndEpisodesInNumberOrder() {
        let files = [CloudFile(id: "3", name: "第10集.mp4", isFolder: false), CloudFile(id: "1", name: "第2集.mp4", isFolder: false),
                     CloudFile(id: "9", name: "Specials", isFolder: true), CloudFile(id: "2", name: "第1集.mp4", isFolder: false)]
        #expect(CloudFile.arranged(files).map(\.name) == ["Specials", "第1集.mp4", "第2集.mp4", "第10集.mp4"])
    }

    @Test func filesAreKnownByTheirExtension() {
        #expect(CloudFile(id: "a", name: "Movie.MKV", isFolder: false).kind == .video)
        #expect(CloudFile(id: "a", name: "song.flac", isFolder: false).isPlayable)
        #expect(!CloudFile(id: "a", name: "Movie.srt", isFolder: false).isPlayable)
        #expect(CloudFile(id: "a", name: "Season 1.mp4", isFolder: true).kind == .folder)
        #expect(CloudFile.playsNatively("a.mp4") && !CloudFile.playsNatively("a.mkv") && !CloudFile.playsNatively("a.rmvb"))
    }

    @Test func aFileIsPlayedAndResumedByItsDriveAndID() throws {
        let file = CloudFile(id: "/Local/剧集/S01E01 #1.mp4", name: "S01E01 #1.mp4", isFolder: false)
        let server = AListServer(id: "abc", name: "NAS", address: "http://nas:5244")
        let channel = CloudFiles.channel(file, in: .alist(server), folder: "/Local/剧集", folderName: "剧集")
        let context = try #require(channel.historyContext)
        #expect(context.sourceKey == CloudFiles.sourceKey && context.episodeFlag == "alist.abc" && context.videoID == "/Local/剧集")
        #expect(channel.skipScope == context.id && CloudFiles.isFile(channel.url))
        let items = try #require(URLComponents(url: channel.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "id" }?.value == file.id)
        #expect(items.first { $0.name == "drive" }?.value == "alist.abc")
        // Continue Watching rebuilds the same address from the history entry.
        #expect(CloudFiles.channel(context, resumePosition: 42).url == channel.url)
    }

    @Test func tvboxAListConfigurationsListServers() throws {
        let fongMi = Data("""
        [{"name":"小雅","server":"http://alist.xiaoya.pro","password":"secret","login":{"username":"guest","password":"pw"}},
         {"server":"https://pan.example.com/Movies%20HD","path":""},
         {"name":"no server"}]
        """.utf8)
        let servers = try #require(AListServer.list(from: fongMi))
        #expect(servers.count == 2)
        #expect(servers[0].name == "小雅" && servers[0].address == "http://alist.xiaoya.pro" && servers[0].root == "/")
        #expect(servers[0].folderPassword == "secret" && servers[0].username == "guest" && servers[0].password == "pw")
        #expect(servers[1].name == "pan.example.com" && servers[1].address == "https://pan.example.com" && servers[1].root == "/Movies HD")
        let wrapped = Data(#"{"drives":[{"name":"A","server":"http://a.test:5244","path":"/x/y/"}]}"#.utf8)
        #expect(AListServer.list(from: wrapped)?.first?.root == "/x/y")
        // A subscription that lists drives as well is still a subscription.
        let subscription = Data(#"{"sites":[],"drives":[{"name":"A","server":"http://a.test"}]}"#.utf8)
        #expect(AListServer.list(from: subscription) == nil)
        #expect(AListServer.list(from: Data(#"{"sites":[{"key":"a"}]}"#.utf8)) == nil)
    }

    @Test func linksNamingLocalhostGoToTheServersAddress() {
        let server = AListServer(name: "NAS", address: "http://192.168.1.10:5244/alist")
        let link = URL(string: "http://localhost:5244/alist/p/Local/a.mp4?sign=x")!
        #expect(AList.reachable(link, server: server).absoluteString == "http://192.168.1.10:5244/alist/p/Local/a.mp4?sign=x")
        let cdn = URL(string: "https://cdn.example.com/a.mp4")!
        #expect(AList.reachable(cdn, server: server) == cdn)
    }

    @Test func cookiesSetByAnAnswerJoinTheJar() throws {
        var jar = CookieJar("__pus=abc; __kp=1")
        let url = URL(string: "https://drive-pc.quark.cn/1/clouddrive/file/download")!
        jar.update(try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: ["Set-Cookie": "__puus=fresh; Domain=.quark.cn; Path=/; HttpOnly"])))
        #expect(jar.header == "__pus=abc; __kp=1; __puus=fresh")
        jar.update(try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": "__puus=newer; Path=/"])))
        #expect(jar["__puus"] == "newer")
    }

    @Test func quarkListingsBecomeFiles() throws {
        let file = try #require(QuarkFiles.file(["fid": "f1", "file_name": "夫妇.mp4", "dir": false, "size": 47675088, "updated_at": 1644424774426]))
        #expect(file.id == "f1" && file.size == 47675088 && !file.isFolder)
        #expect(file.modified == Date(timeIntervalSince1970: 1644424774.426))
        #expect(QuarkFiles.file(["fid": "d", "file_name": "来自：分享", "dir": true])?.isFolder == true)
    }

    @Test func aVideoTooLargeToDownloadPlaysTheTranscodedCopy() async throws {
        QuarkStub.reset()
        let drive = QuarkFiles(.quark, session: QuarkStub.session, account: { "__pus=abc" })
        let url = try await drive.stream("big", name: "夫妇.mp4")
        #expect(url.scheme == CloudStreams.scheme)
        #expect(QuarkStub.calls == ["/1/clouddrive/file/download", "/1/clouddrive/file/v2/play"])
        CloudStreams.stop(url)
        // A song has no transcoded copy, so the refusal is the viewer's to read.
        await #expect(throws: TVError.self) { try await drive.stream("big", name: "歌.mp3") }
    }

    /// Quark sends most transcoded copies as HLS (`format: m3u8`, `.../media.m3u8`): AVPlayer reads the playlist
    /// itself, with the account's cookies on every request. Read as the bytes of one file, the first range came
    /// back as the playlist (HTTP 200) and the video failed ("request failed offset=0 HTTP 416", -17761).
    @Test func aTranscodedCopyInHLSPlaysAsHLS() async throws {
        QuarkStub.reset()
        let drive = QuarkFiles(.quark, session: QuarkStub.session, account: { "__pus=abc" })
        let url = try await drive.stream("hls", name: "夫妇.mp4")
        #expect(url.host() == "video-play.quark.test" && url.pathExtension == "m3u8")
        #expect(CloudStreams.playlistHeaders(for: url)?["Cookie"]?.contains("__pus=abc") == true)
        #expect(CloudStreams.playlistHeaders(for: url)?["Referer"] == "https://pan.quark.cn/")
        #expect(try #require(CloudStreams.asset(for: url)).url == url)
        CloudStreams.stop(url)
        #expect(CloudStreams.playlistHeaders(for: url) == nil && CloudStreams.asset(for: url) == nil)
    }

    @Test func aGuestThatMayNotBrowseSignsInOnce() async throws {
        AListStub.reset()
        let server = AListServer(id: "s", name: "Stub", address: "https://alist.test", username: "me", password: "pw")
        let client = AList(session: AListStub.session)
        let files = CloudFile.arranged(try await client.list(server, path: "/", password: nil))
        #expect(files.map(\.name) == ["Movies", "a.mp4"] && files[1].id == "/a.mp4" && files[0].isFolder)
        #expect(AListStub.calls == ["/api/fs/list -", "/api/auth/login -", "/api/fs/list token-1"])
        // The token is kept: the next listing goes straight through.
        _ = try await client.list(server, path: "/Movies", password: nil)
        #expect(AListStub.calls.last == "/api/fs/list token-1")
        // Without an account the server's refusal is the viewer's to answer.
        await #expect(throws: CloudFilesError.signInRequired("Stub")) {
            try await AList(session: AListStub.session).list(AListServer(name: "Stub", address: "https://alist.test"), path: "/", password: nil)
        }
    }

    @Test func aProtectedFolderAsksForItsPasswordAndKeepsIt() async throws {
        AListStub.reset()
        let server = AListServer(id: "p", name: "Stub", address: "https://alist.test", username: "me", password: "pw")
        let client = AList(session: AListStub.session)
        await #expect(throws: CloudFilesError.passwordRequired) { try await client.list(server, path: "/Private", password: nil) }
        #expect(try await client.list(server, path: "/Private", password: "1234").count == 2)
        // Its subfolders open with it too.
        #expect(try await client.list(server, path: "/Private/Deeper", password: nil).count == 2)
    }

    @Test func drivesSearchAsSources() async throws {
        QuarkStub.reset()
        let quark = try await QuarkFiles(.quark, session: QuarkStub.session, account: { "__pus=abc" }).search("庆余年 1", page: 2, size: 50)
        #expect(quark.files.map(\.name) == ["庆余年", "庆余年 第1集.mp4", "庆余年 海报.pdf"] && quark.total == 120)
        AListStub.reset()
        let server = AListServer(id: "q", name: "Stub", address: "https://alist.test", username: "me", password: "pw")
        let client = AList(session: AListStub.session)
        let found = try await client.search(server, "剧", page: 1, size: 50)
        #expect(found.files.map(\.id) == ["/Local/剧集/第一季", "/a.mp4"] && found.files[0].isFolder && found.total == 2)
        // A server without a search index says how to get one.
        await #expect(throws: TVError.self) { try await client.search(server, "nothing", page: 1, size: 50) }
        EmbyStub.reset()
        let emby = AListServer(id: "e", name: "Home", address: "http://emby.test/emby", username: "me", password: "pw", kind: .emby)
        let films = try await Emby(session: EmbyStub.session).search(emby, "Pilot", page: 2, size: 50)
        #expect(films.files.count == 3 && films.total == 3)
        #expect(EmbyStub.calls.last == "GET /emby/Users/u1/Items?Fields=Path,MediaSources&IncludeItemTypes=Movie,Series,Video,MusicVideo&Limit=50&Recursive=true&SearchTerm=Pilot&StartIndex=50 tok-1")
    }

    @Test func aDriveSourceNamesFilesAndFoldersByTheirIDs() throws {
        let file = CloudFile(id: "/Local/剧集/S01E01 #1|a%b.mp4", name: "S01E01 #1|a%b.mp4", isFolder: false, size: 2048)
        let entry = CloudFilesSource.Entry(file)
        #expect(CloudFilesSource.Entry(entry.token) == entry && !entry.token.contains("#") && entry.token.split(separator: "|").count == 3)
        #expect(CloudFilesSource.Entry("x|a|b") == nil && CloudFilesSource.Entry("f||b") == nil)
        // Found by a search, a folder opens as details; browsing, as a listing.
        let folder = CloudFile(id: "d1", name: "庆余年", isFolder: true)
        #expect(CloudFilesSource.video(folder, opensAsListing: false)["vod_tag"] == nil)
        #expect(CloudFilesSource.video(folder, opensAsListing: true)["vod_tag"] == .string("folder"))
        let video = try #require(Video(json: CloudFilesSource.video(file, opensAsListing: false), origin: URL(string: "https://example.invalid")!))
        #expect(video.name == "S01E01 #1|a%b" && !video.isFolder && video.remarks == ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file))
        // An episode keeps its file through TVBox's play list, whatever its name holds.
        let fields: [String: JSONValue] = ["vod_id": .string("v"), "vod_play_from": .string(CloudFilesSource.lineName("A$B")),
                                           "vod_play_url": .string(CloudFilesSource.episode(file))]
        let episode = try #require(Video(json: fields, origin: URL(string: "https://example.invalid")!)?.episodes.first)
        #expect(CloudFilesSource.Entry(episode.address) == entry && episode.name == "S01E01 ＃1|a%b" && episode.flag == "A＄B")
    }

    @Test func aFolderPlaysItsFilesThenEachSubfoldersAsLines() {
        let drive = CloudFilesDrive.quark
        let lines = CloudFilesSource.playlist("Show", [CloudFile(id: "s1", name: "Season 1", isFolder: true), CloudFile(id: "n", name: "notes.txt", isFolder: false),
                                                       CloudFile(id: "t", name: "Trailer.mp4", isFolder: false)],
                                              subfolders: [(name: "Season 1", files: [CloudFile(id: "e1", name: "E01.mkv", isFolder: false)]),
                                                           (name: "Extras", files: [CloudFile(id: "x", name: "cover.jpg", isFolder: false)])], drive: drive)
        #expect(lines.map(\.name) == ["Show", "Season 1"] && lines.map { $0.files.map(\.id) } == [["t"], ["e1"]])
    }

    @Test func driveSourcesAreBuiltInAndRunHere() {
        let site = CloudFilesSource.site(.quark)
        #expect(site.isCloudFiles && site.isBuiltIn && site.searchable && site.canBrowse(jarURL: nil))
        #expect(site.key == "builtin.files.quark" && !Site.bilibili.isCloudFiles)
        let webdav = AListServer(name: "NAS", address: "http://nas:5005", kind: .webdav)
        #expect(!CloudFilesDrive.alist(webdav).searches && CloudFilesDrive.uc.searches)
    }

    /// A real AList or OpenList server, for example Scripts' local one: TVBOX_ALIST_URL plus
    /// TVBOX_ALIST_FOLDER (a folder holding an MP4) and optionally TVBOX_ALIST_USER/PASSWORD.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_ALIST_URL"] != nil))
    func aRealAListServerListsAndPlays() async throws {
        let environment = ProcessInfo.processInfo.environment
        var server = try #require(await AList.probe(URL(string: environment["TVBOX_ALIST_URL"]!)!))
        server.username = environment["TVBOX_ALIST_USER"] ?? ""; server.password = environment["TVBOX_ALIST_PASSWORD"] ?? ""
        try await AList.shared.check(server)
        let folder = environment["TVBOX_ALIST_FOLDER"] ?? server.root
        let files = CloudFile.arranged(try await AList.shared.list(server, path: folder, password: nil))
        let video = try #require(files.first { $0.name.hasSuffix(".mp4") })
        try await plays(AList.shared.stream(server, path: video.id, name: video.name))
        // Its address added as a subscription adds the server instead.
        guard case .alist(let added) = try await HTTPClient().subscriptionImport(URL(string: environment["TVBOX_ALIST_URL"]! + folder)!) else {
            Issue.record("not recognised as an AList server"); return
        }
        #expect(added.first?.address == server.address && added.first?.root == folder)
    }

    @Test func aNASWebDAVShareListsWithItsAccount() async throws {
        WebDAVStub.reset()
        let client = WebDAV(session: WebDAVStub.session)
        let server = try #require(try await client.probe(URL(string: "http://dav.test/NAS")!, username: "me", password: "pw"))
        #expect(server.isWebDAV && server.address == "http://dav.test" && server.root == "/NAS" && server.name == "dav.test")
        let files = CloudFile.arranged(try await client.list(server, path: server.root))
        #expect(files.map(\.name) == ["剧集", "S01E01 #1.mp4"] && files.map(\.id) == ["/NAS/剧集", "/NAS/S01E01 #1.mp4"])
        #expect(files[0].isFolder && !files[1].isFolder && files[1].size == 1_048_576)
        #expect(files[1].modified == Date(timeIntervalSince1970: 1_793_346_000))
        #expect(WebDAVStub.calls == ["PROPFIND /NAS/ 0 Basic bWU6cHc=", "PROPFIND /NAS/ 1 Basic bWU6cHc="])
        // Without an account the share's refusal is the viewer's to answer; a wrong one says so.
        await #expect(throws: CloudFilesError.signInRequired("dav.test")) { try await client.probe(URL(string: "http://dav.test/NAS")!) }
        await #expect(throws: TVError.self) { try await client.probe(URL(string: "http://dav.test/NAS")!, username: "me", password: "no") }
        // A web server that doesn't speak WebDAV isn't a share.
        #expect(try await client.probe(URL(string: "http://dav.test/site")!) == nil)
    }

    @Test func aWebDAVFilePlaysByRangedReadsWithTheAccount() async throws {
        WebDAVStub.reset()
        let server = AListServer(name: "NAS", address: "http://dav.test", root: "/NAS", username: "me", password: "pw", kind: .webdav)
        let source = try await WebDAV(session: WebDAVStub.session).source(server, path: "/NAS/S01E01 #1.mp4", name: "S01E01 #1.mp4")
        #expect(source.url.absoluteString == "http://dav.test/NAS/S01E01%20%231.mp4" && source.length == 1_048_576)
        #expect(source.headers == ["Authorization": "Basic bWU6cHc="])
        #expect(WebDAVStub.calls == ["PROPFIND /NAS/S01E01%20%231.mp4 0 Basic bWU6cHc="])
        // Its history entry goes back to the share.
        let channel = CloudFiles.channel(CloudFile(id: "/NAS/S01E01 #1.mp4", name: "S01E01 #1.mp4", isFolder: false), in: .alist(server), folder: "/NAS", folderName: "NAS")
        #expect(channel.historyContext?.episodeFlag == "alist." + server.id)
    }

    @Test func serversSavedBeforeWebDAVAreAList() throws {
        let saved = Data(#"[{"id":"a","name":"NAS","address":"http://nas:5244","root":"/","username":"","password":"","folderPassword":""}]"#.utf8)
        #expect(try JSONDecoder().decode([AListServer].self, from: saved).first?.isWebDAV == false)
        let share = AListServer(name: "NAS", address: "http://nas:5005", kind: .webdav)
        #expect(try JSONDecoder().decode(AListServer.self, from: JSONEncoder().encode(share)).isWebDAV)
    }

    /// A real WebDAV share: TVBOX_WEBDAV_URL (with the folder to start in) holding an MP4, and
    /// TVBOX_WEBDAV_USER/PASSWORD when it wants an account.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_WEBDAV_URL"] != nil))
    func aRealWebDAVShareListsAndPlays() async throws {
        let environment = ProcessInfo.processInfo.environment
        let server = try #require(try await WebDAV.shared.probe(URL(string: environment["TVBOX_WEBDAV_URL"]!)!,
                                                                 username: environment["TVBOX_WEBDAV_USER"] ?? "", password: environment["TVBOX_WEBDAV_PASSWORD"] ?? ""))
        try await WebDAV.shared.check(server)
        let files = CloudFile.arranged(try await WebDAV.shared.list(server, path: server.root))
        let video = try #require(files.first { $0.name.hasSuffix(".mp4") })
        try await plays(WebDAV.shared.stream(server, path: video.id, name: video.name))
    }

    @Test func anEmbyServerIsFoundByTheAddressItsWebAppOpensAt() async throws {
        EmbyStub.reset()
        let server = try #require(await Emby.probe(URL(string: "http://emby.test/emby/web/index.html#!/home")!, session: EmbyStub.session))
        #expect(server.isEmby && server.address == "http://emby.test/emby" && server.root == "/" && server.name == "Home")
        #expect(await Emby.probe(URL(string: "http://emby.test/site")!, session: EmbyStub.session) == nil)
        // Saved and loaded again, it is still a media server.
        #expect(try JSONDecoder().decode(AListServer.self, from: JSONEncoder().encode(server)).isEmby)
    }

    @Test func embyLibrariesListAsFoldersAndEpisodesInOrder() async throws {
        EmbyStub.reset()
        let server = AListServer(id: "e", name: "Home", address: "http://emby.test/emby", username: "me", password: "pw", kind: .emby)
        let client = Emby(session: EmbyStub.session)
        let libraries = try await client.list(server, id: server.root)
        // Live TV isn't a folder of files.
        #expect(libraries.map(\.name) == ["Shows"] && libraries[0].isFolder && libraries[0].id == "shows")
        #expect(libraries[0].artwork?.absoluteString == "http://emby.test/emby/Items/shows/Images/Primary?tag=t1&maxHeight=240")
        let episodes = CloudFile.arranged(try await client.list(server, id: "season"))
        #expect(episodes.map(\.name) == ["2. Pilot.mp4", "10. Finale.mkv", "Film (2024).mkv"])
        #expect(episodes.allSatisfy { CloudFilesDrive.alist(server).plays($0) })
        #expect(EmbyStub.calls == ["POST /emby/Users/AuthenticateByName -", "GET /emby/Users/u1/Views tok-1",
                                   "GET /emby/Users/u1/Items?Fields=Path&ParentId=season&SortBy=SortName tok-1"])
        // The server restarted and forgot the token: sign in again, once.
        EmbyStub.forgetTokens()
        _ = try await client.list(server, id: server.root)
        #expect(EmbyStub.calls.suffix(3) == ["GET /emby/Users/u1/Views tok-1", "POST /emby/Users/AuthenticateByName -", "GET /emby/Users/u1/Views tok-2"])
        // Without an account, or with a wrong one, the viewer is told.
        await #expect(throws: CloudFilesError.signInRequired("Home")) {
            try await Emby(session: EmbyStub.session).check(AListServer(name: "Home", address: "http://emby.test/emby", kind: .emby))
        }
        await #expect(throws: TVError.self) {
            try await Emby(session: EmbyStub.session).check(AListServer(name: "Home", address: "http://emby.test/emby", username: "me", password: "no", kind: .emby))
        }
    }

    @Test func anEmbyFilePlaysAsTheServerStoresIt() async throws {
        EmbyStub.reset()
        let server = AListServer(id: "e", name: "Home", address: "http://emby.test/emby", username: "me", password: "pw", kind: .emby)
        let source = try await Emby(session: EmbyStub.session).source(server, id: "e2", name: "2. Pilot.mp4")
        #expect(source.url.absoluteString == "http://emby.test/emby/Videos/e2/stream?static=true&MediaSourceId=ms2" && source.length == 1_048_576)
        #expect(source.headers["X-Emby-Token"] == "tok-1" && source.headers["Authorization"]?.contains(#"Token="tok-1""#) == true)
        // Its history entry goes back to the server.
        let channel = CloudFiles.channel(CloudFile(id: "e2", name: "2. Pilot.mp4", isFolder: false), in: .alist(server), folder: "season", folderName: "Season 1")
        #expect(channel.historyContext?.episodeFlag == "alist.e" && channel.historyContext?.videoID == "season")
        #expect(Emby.type(path: nil, container: "mov,mp4,m4a,3gp,3g2,mj2") == "mp4" && Emby.type(path: "/a/b.strm", container: "matroska,webm") == "mkv")
    }

    /// A real Emby or Jellyfin server: TVBOX_EMBY_URL and the account TVBOX_EMBY_USER/PASSWORD.
    /// Plays the first video of each kind of file it finds in the libraries, or for one the player
    /// repackages, reads its first bytes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_EMBY_URL"] != nil))
    func aRealEmbyServerListsAndPlays() async throws {
        let environment = ProcessInfo.processInfo.environment
        var server = try #require(await Emby.probe(URL(string: environment["TVBOX_EMBY_URL"]!)!))
        server.username = environment["TVBOX_EMBY_USER"] ?? ""; server.password = environment["TVBOX_EMBY_PASSWORD"] ?? ""
        try await Emby.shared.check(server)
        var folders = [server.root], videos: [String: CloudFile] = [:]
        while let folder = folders.first, folders.count < 50 {
            folders.removeFirst()
            for file in try await Emby.shared.list(server, id: folder) {
                if file.isFolder { folders.append(file.id) }
                else if file.kind == .video { videos[(file.name as NSString).pathExtension.lowercased()] = videos[(file.name as NSString).pathExtension.lowercased()] ?? file }
            }
        }
        #expect(!videos.isEmpty)
        for video in videos.values {
            let url = try await Emby.shared.stream(server, id: video.id, name: video.name)
            // An MKV or AVI is the player's to repackage; its first bytes say it reads as one.
            if CloudFile.playsNatively(video.name) { try await plays(url) } else { #expect(await CloudStreams.needsRemux(url)); CloudStreams.stop(url) }
        }
    }

    /// A real Quark account: TVBOX_QUARK_ACCOUNTS names a copy of the app's accounts.json. Plays the
    /// first MP4 in TVBOX_QUARK_FOLDER (the root by default) as it is, then as Quark's transcoded copy.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_QUARK_ACCOUNTS"] != nil))
    func aRealQuarkDriveListsAndPlays() async throws {
        let environment = ProcessInfo.processInfo.environment
        let accounts = try JSONDecoder().decode(CloudDriveAccounts.self, from: Data(contentsOf: URL(fileURLWithPath: environment["TVBOX_QUARK_ACCOUNTS"]!)))
        let drive = QuarkFiles(.quark, account: { accounts.quarkCookie })
        let files = try await drive.list(environment["TVBOX_QUARK_FOLDER"] ?? "0")
        // Its search finds a file by a word of its name.
        let named = try #require(files.first { !$0.isFolder })
        let found = try await drive.search(String(named.name.prefix(2)), page: 1, size: 50)
        #expect(found.files.contains { $0.id == named.id } && found.total >= found.files.count)
        let video = try #require(files.first { !$0.isFolder && $0.name.lowercased().hasSuffix(".mp4") })
        try await plays(drive.stream(video.id, name: video.name))
        // Named as a container `Remux` repackages, the original plays through it.
        try await plays(drive.stream(video.id, name: (video.name as NSString).deletingPathExtension + ".mkv"))
        // Named as one neither opens, it plays Quark's transcoded copy, usually HLS.
        try await plays(drive.stream(video.id, name: (video.name as NSString).deletingPathExtension + ".3gp"))
    }

    private func plays(_ url: URL) async throws {
        let asset = try #require(CloudStreams.asset(for: url))
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        var waited = 0
        while player.currentTime().seconds < 3, item.status != .failed, waited < 300 { try await Task.sleep(for: .milliseconds(100)); waited += 1 }
        #expect(item.status != .failed, "\(String(describing: item.error))")
        #expect(player.currentTime().seconds >= 3, "stuck at \(player.currentTime().seconds)")
        #expect(item.presentationSize.width > 0)
        player.pause()
        CloudStreams.stop(url)
    }
}

/// A Quark drive whose account may not download its files as they are, only play the transcoded copy.
final class QuarkStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuarkStub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "drive-pc.quark.cn" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.log.append(url.path) }
        let answer: [String: Any]
        switch url.path {
        case "/1/clouddrive/file/download":
            answer = ["status": 400, "code": 23018, "message": "download file size limit[0f72b19798924b5191194e364cf4265e]"]
        case "/1/clouddrive/file/search":
            answer = ["status": 200, "code": 0, "metadata": ["_total": 120], "data": ["list": [
                ["fid": "d1", "file_name": "庆余年", "dir": true],
                ["fid": "f1", "file_name": "庆余年 第1集.mp4", "dir": false, "size": 1000],
                ["fid": "f2", "file_name": "庆余年 海报.pdf", "dir": false, "size": 10],
            ]]]
        case "/1/clouddrive/file/v2/play" where Self.body(request)["fid"] as? String == "hls":
            answer = ["status": 200, "code": 0, "data": ["video_list": [
                ["resolution": "high", "accessable": false, "supports_format": "p_qv"],
                ["resolution": "low", "accessable": true, "supports_format": "p_qv", "video_info": [
                    "url": "https://video-play.quark.test/sz3/media.m3u8?auth_key=1", "size": 5308125, "format": "m3u8",
                    "file_format": "m3u8", "duration": 95, "width": 480, "height": 270]],
            ]]]
        case "/1/clouddrive/file/v2/play":
            answer = ["status": 200, "code": 0, "data": ["video_list": [
                ["resolution": "super", "accessable": false],
                ["resolution": "normal", "accessable": true, "video_info": ["url": "https://video-play.quark.test/a.mp4", "size": 1000]],
            ]]]
        default:
            answer = ["status": 404, "code": 404, "message": "not found"]
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    /// A POST's JSON body, which URLSession hands a protocol as a stream.
    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// An AList server that wants a sign-in from guests and protects /Private with "1234".
final class AListStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AListStub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "alist.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let token = request.value(forHTTPHeaderField: "Authorization")
        Self.lock.withLock { Self.log.append("\(url.path) \(token ?? "-")") }
        var body: [String: Any] = [:]
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let answer: [String: Any]
        switch url.path {
        case "/api/auth/login":
            answer = body["password"] as? String == "pw" ? ["code": 200, "data": ["token": "token-1"]] : ["code": 400, "message": "password is incorrect"]
        case "/api/fs/search" where body["keywords"] as? String == "nothing":
            answer = ["code": 500, "message": "search not available"]
        case "/api/fs/search":
            answer = ["code": 200, "data": ["total": 2, "content": [["parent": "/Local/剧集/", "name": "第一季", "is_dir": true, "size": 0],
                                                                   ["parent": "/", "name": "a.mp4", "is_dir": false, "size": 10]]]]
        case "/api/fs/list" where token == nil:
            answer = ["code": 401, "message": "Guest user is disabled, login please"]
        case "/api/fs/list" where (body["path"] as? String ?? "").hasPrefix("/Private") && body["password"] as? String != "1234":
            answer = ["code": 403, "message": "password is incorrect or you have no permission"]
        case "/api/fs/list":
            answer = ["code": 200, "data": ["content": [["name": "a.mp4", "size": 10, "is_dir": false, "modified": "2026-10-22T03:57:19.905+08:00"],
                                                    ["name": "Movies", "size": 0, "is_dir": true, "modified": "2026-10-22T03:57:19+08:00"]]]]
        default:
            answer = ["code": 404, "message": "not found"]
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A NAS's WebDAV share at dav.test: /NAS wants the account me/pw, and /site is a web page that isn't WebDAV.
final class WebDAVStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDAVStub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "dav.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let path = url.path(percentEncoded: true), account = request.value(forHTTPHeaderField: "Authorization")
        let depth = request.value(forHTTPHeaderField: "Depth") ?? "-"
        Self.lock.withLock { Self.log.append("\(request.httpMethod ?? "-") \(path) \(depth) \(account ?? "-")") }
        let folder = #"<D:response><D:href>/NAS/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:getlastmodified>Fri, 30 Oct 2026 07:40:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"#
        let file = #"<D:response><D:href>http://dav.test/NAS/S01E01%20%231.mp4</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1048576</D:getcontentlength><D:getlastmodified>Fri, 30 Oct 2026 07:40:00 GMT</D:getlastmodified></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat><D:propstat><D:prop><D:quota/></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>"#
        let subfolder = #"<D:response><D:href>/NAS/%E5%89%A7%E9%9B%86/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"#
        let status: Int, responses: [String]
        if path.hasPrefix("/site") { (status, responses) = (405, []) }
        else if account != "Basic bWU6cHc=" { (status, responses) = (401, []) }
        else if path == "/NAS/" { (status, responses) = (207, depth == "0" ? [folder] : [folder, subfolder, file]) }
        else if path == "/NAS/S01E01%20%231.mp4" { (status, responses) = (207, [file]) }
        else { (status, responses) = (404, []) }
        let body = status == 207 ? #"<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">"# + responses.joined() + "</D:multistatus>" : ""
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/xml"])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// An Emby server at emby.test/emby with the account me/pw. Each sign-in hands out a new token,
/// and only tokens since the last `forgetTokens()` are taken.
final class EmbyStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var issued = 0, valid = 0
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = []; issued = 0; valid = 0 } }
    static func forgetTokens() { lock.withLock { valid = issued } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbyStub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "emby.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let target = url.path + (url.query.map { "?" + $0 } ?? ""), token = request.value(forHTTPHeaderField: "X-Emby-Token")
        var body: [String: Any] = [:]
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let (status, answer): (Int, Any) = Self.lock.withLock {
            Self.log.append("\(request.httpMethod ?? "-") \(target) \(token ?? "-")")
            let signedIn = token.flatMap { Int($0.dropFirst(4)) }.map { $0 > Self.valid && $0 <= Self.issued } ?? false
            switch url.path {
            case "/emby/System/Info/Public": return (200, ["Id": "abc", "Version": "4.10.2.0", "ServerName": "Home"])
            case "/emby/Users/AuthenticateByName":
                guard body["Username"] as? String == "me", body["Pw"] as? String == "pw" else { return (401, [:]) }
                Self.issued += 1
                return (200, ["AccessToken": "tok-\(Self.issued)", "User": ["Id": "u1"]])
            case _ where !signedIn: return (401, [:])
            case "/emby/Users/u1/Views":
                return (200, ["Items": [["Id": "shows", "Name": "Shows", "IsFolder": true, "CollectionType": "tvshows", "ImageTags": ["Primary": "t1"]],
                                        ["Id": "tv", "Name": "Live TV", "IsFolder": true, "CollectionType": "livetv"]]])
            case "/emby/Users/u1/Items":
                return (200, ["Items": [["Id": "e10", "Name": "Finale", "Type": "Episode", "IndexNumber": 10, "IsFolder": false, "Path": "/media/Show/S01E10.mkv"],
                                        ["Id": "e2", "Name": "Pilot", "Type": "Episode", "IndexNumber": 2, "IsFolder": false, "Container": "mov,mp4,m4a,3gp,3g2,mj2"],
                                        ["Id": "m", "Name": "Film", "Type": "Movie", "ProductionYear": 2024, "IsFolder": false, "Container": "mkv"]]])
            case "/emby/Users/u1/Items/e2":
                return (200, ["Id": "e2", "MediaType": "Video", "MediaSources": [["Id": "ms2", "Size": 1_048_576, "Container": "mp4"]]])
            default: return (404, [:])
            }
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
