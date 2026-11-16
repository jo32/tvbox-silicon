import Foundation
import Testing
@testable import TVCore

/// Baidu Netdisk in Cloud Files (#1139). The stub answers in the shape of the web API (`pan.baidu.com/api/list`,
/// `/search`, `/filemetas`, `/streaming`) as AList/OpenList and BaiduPCS-Go read it; no real account was available.
@Suite(.serialized) struct BaiduFilesTests {
    static let signedIn = "BDUSS=ok; STOKEN=s"

    func drive(_ cookie: String = signedIn, waited: WaitLog = WaitLog()) -> BaiduFiles {
        BaiduFiles(session: BaiduStub.session, account: { cookie }, wait: { await waited.add($0) })
    }

    @Test func listingRowsBecomeFoldersAndFiles() throws {
        let folder = try #require(BaiduFiles.file(["fs_id": 1, "path": "/电视剧/庆余年", "server_filename": "庆余年", "isdir": 1, "size": 0, "server_mtime": 1_714_565_700]))
        #expect(folder.isFolder && folder.id == "/电视剧/庆余年" && folder.modified == Date(timeIntervalSince1970: 1_714_565_700))
        let file = try #require(BaiduFiles.file(["fs_id": "2", "path": "/电视剧/第1集 a+b.mkv", "server_filename": "第1集 a+b.mkv", "isdir": "0", "size": "1234567"]))
        #expect(!file.isFolder && file.id == "/电视剧/第1集 a+b.mkv" && file.size == 1_234_567)
        // No name: the path's last part.
        #expect(BaiduFiles.file(["path": "/a/b.mp4", "isdir": 0])?.name == "b.mp4")
        #expect(BaiduFiles.file(["server_filename": "x"]) == nil)
    }

    @Test func theDriveListsAFolderByItsPath() async throws {
        BaiduStub.reset()
        let files = try await drive().list("/电视剧")
        #expect(files.map(\.name) == ["庆余年", "第1集 a+b.mkv"])
        let call = try #require(BaiduStub.calls.first)
        #expect(call.hasPrefix("https://pan.baidu.com/api/list?"))
        #expect(call.contains("dir=/%E7%94%B5%E8%A7%86%E5%89%A7") && call.contains("app_id=250528") && call.contains("web=1"))
        #expect(BaiduStub.cookies.first == Self.signedIn)
    }

    @Test func aStaleOrMissingSignInAsksToSignIn() async {
        let name = L10n.text("Baidu Netdisk")
        await #expect(throws: CloudFilesError.signInRequired(name)) { try await drive("BDUSS=old").list("/") }
        await #expect(throws: CloudFilesError.signInRequired(name)) { try await drive("").list("/") }
        // A cookie without BDUSS can't sign in at all.
        await #expect(throws: CloudFilesError.signInRequired(name)) { try await drive("STOKEN=s").list("/") }
    }

    @Test func searchSaysWhetherMoreFollow() async throws {
        BaiduStub.reset()
        let found = try await drive().search("庆余 年", page: 1, size: 2)
        #expect(found.files.map(\.name) == ["庆余年", "第1集 a+b.mkv"] && found.total == 3)
        #expect(BaiduStub.calls.first?.contains("key=%E5%BA%86%E4%BD%99%20%E5%B9%B4") == true)
        #expect(BaiduStub.calls.first?.contains("recursion=1") == true)
    }

    @Test func aVideoPlaysAsTheBestCopyTheAccountMayHave() async throws {
        BaiduStub.reset()
        let waited = WaitLog()
        let url = try await drive(waited: waited).playlist("/电视剧/第1集 a+b.mkv")
        // 1080p is refused, 720p asks to wait first, then plays with the token it gave.
        #expect(url.absoluteString.contains("type=M3U8_AUTO_720") && url.absoluteString.contains("adToken=wait-token"))
        #expect(url.absoluteString.contains("path=/%E7%94%B5%E8%A7%86%E5%89%A7/%E7%AC%AC1%E9%9B%86%20a%2Bb.mkv"))
        #expect(await waited.seconds == [5])
        #expect(BaiduStub.calls.filter { $0.contains("/api/streaming") }.count == 3)
    }

    @Test func aLongWaitIsCapped() async throws {
        BaiduStub.reset()
        let waited = WaitLog()
        _ = try await drive("BDUSS=ok; long=1", waited: waited).playlist("/a.mp4")
        #expect(await waited.seconds == [BaiduFiles.longestWait])
    }

    @Test func theOriginalComesWithItsDownloadLink() async throws {
        BaiduStub.reset()
        let source = try await drive().original("/音乐/歌.flac", name: "歌.flac")
        #expect(source.url.host() == "d.pcs.baidu.com" && source.length == 7_654_321)
        #expect(source.headers["User-Agent"] == BaiduFiles.downloadAgent && source.headers["Cookie"]?.contains("BDUSS=ok") == true)
        let call = try #require(BaiduStub.calls.first)
        #expect(call.contains("/api/filemetas?") && call.contains("dlink=1") && call.contains("web=5"))
        #expect(call.contains("target=%5B%22/%E9%9F%B3%E4%B9%90/%E6%AD%8C.flac%22%5D"))
    }

    @Test func cloudFilesKnowsBaidu() throws {
        #expect(CloudFilesDrive.baidu.key == "baidu" && CloudFilesDrive.baidu.root == "/")
        #expect(CloudFiles.drive(key: "baidu") == .baidu)
        // Any video, as Baidu makes an HLS copy of it; songs that play as they are.
        #expect(CloudFilesDrive.baidu.plays(CloudFile(id: "/a.rmvb", name: "a.rmvb", isFolder: false)))
        #expect(CloudFilesDrive.baidu.plays(CloudFile(id: "/a.flac", name: "a.flac", isFolder: false)))
        #expect(!CloudFilesDrive.baidu.plays(CloudFile(id: "/a.ape", name: "a.ape", isFolder: false)))
        #expect(!CloudFilesDrive.baidu.plays(CloudFile(id: "/a.srt", name: "a.srt", isFolder: false)))
        #expect(CloudFilesSource.site(.baidu).key == "builtin.files.baidu" && CloudFilesDrive.baidu.searches)
    }

    @Test func errorsSayWhatBaiduMeant() {
        #expect(BaiduFiles.signedOut(-6) && BaiduFiles.signedOut(9019) && !BaiduFiles.signedOut(0))
        #expect(BaiduFiles.isPlaylist(Data("\n#EXTM3U\n#EXT-X-VERSION:3".utf8)) && !BaiduFiles.isPlaylist(Data(#"{"errno":133}"#.utf8)))
    }
}

actor WaitLog {
    private(set) var seconds: [Int] = []
    func add(_ value: Int) { seconds.append(value) }
}

/// pan.baidu.com's web API for the account "BDUSS=ok", and the not-signed-in answer (errno -6) for any other.
final class BaiduStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [(url: String, cookie: String)] = []
    static var calls: [String] { lock.withLock { log.map(\.url) } }
    static var cookies: [String] { lock.withLock { log.map(\.cookie) } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BaiduStub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "pan.baidu.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated(unsafe) static let rows: [[String: Any]] = [
        ["category": 6, "fs_id": 3_120_412_211_431_101, "isdir": 1, "local_ctime": 1_714_565_700, "local_mtime": 1_714_565_700, "md5": "",
         "path": "/电视剧/庆余年", "server_ctime": 1_714_565_700, "server_filename": "庆余年", "server_mtime": 1_714_565_700, "size": 0, "share": 0, "unlist": 0],
        ["category": 1, "fs_id": 3_120_412_211_431_102, "isdir": 0, "local_ctime": 1_714_565_700, "local_mtime": 1_714_565_700, "md5": "9b0e2f2b9c0f2f6a",
         "path": "/电视剧/第1集 a+b.mkv", "server_ctime": 1_714_565_700, "server_filename": "第1集 a+b.mkv", "server_mtime": 1_714_565_700, "size": 1_234_567, "share": 0, "unlist": 0],
    ]

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        Self.lock.withLock { Self.log.append((url.absoluteString, cookie)) }
        let query = url.query(percentEncoded: true) ?? ""
        var body: Data
        if !cookie.hasPrefix("BDUSS=ok") {
            body = Self.json(["errno": -6, "request_id": 1])
        } else {
            switch url.path() {
            case "/api/list": body = Self.json(["errno": 0, "guid_info": "", "list": Self.rows, "request_id": 1, "guid": 0])
            case "/api/search": body = Self.json(["errno": 0, "request_id": 1, "list": Self.rows, "has_more": 1])
            case "/api/filemetas":
                body = Self.json(["errno": 0, "request_id": 1, "info": [["category": 2, "fs_id": 9, "isdir": 0, "path": "/音乐/歌.flac",
                                                                       "server_filename": "歌.flac", "size": 7_654_321,
                                                                       "dlink": "https://d.pcs.baidu.com/file/9b0e2f2b?fid=1-250528-9&rt=pr&sign=x&expires=8h"]]])
            case "/api/streaming":
                if query.contains("M3U8_AUTO_1080") { body = Self.json(["errno": 31346, "request_id": 1]) }
                else if !query.contains("adToken=") {
                    body = Self.json(["errno": 133, "adTime": cookie.contains("long=1") ? 600 : 5, "adToken": "wait-token", "ltime": 0, "request_id": 1])
                } else {
                    body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10,\nhttps://nv0.baidupcs.com/video/netdisk-videotran-x/seg-0.ts\n#EXT-X-ENDLIST\n".utf8)
                }
            default: body = Self.json(["errno": 2])
            }
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}
