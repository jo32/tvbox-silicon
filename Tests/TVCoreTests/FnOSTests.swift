import CryptoKit
import Foundation
import Testing
@testable import TVCore

/// 飞牛影视 on a fnOS NAS (#1017), against a stub that checks requests as the NAS does: every one signed (`Authx`)
/// over its path and body, with `Cookie: mode=relay`, and all but sign-in with the token.
@Suite(.serialized) struct FnOSTests {
    let server = AListServer(id: "f", name: "NAS", address: "http://fnos.test:5666", username: "me", password: "pw", kind: .fnos)

    /// The same signature fntv-jellyfin-bridge's `generateAuthx` makes for these inputs (worked out with its code in Node).
    @Test func requestsAreSignedAsFnOSsWebAppSignsThem() {
        #expect(FnOS.authx(path: "/v/api/v1/item/list", signed: Data(#"{"parent_guid":"fv_1"}"#.utf8), nonce: "123456", timestamp: 1_700_000_000_000)
                == "nonce=123456&timestamp=1700000000000&sign=869adfe7ee45a6c0cebec4701c6365a0")
        #expect(FnOS.authx(path: "/v/api/v1/media/range/m1", signed: nil, nonce: "654321", timestamp: 1_700_000_000_123)
                == "nonce=654321&timestamp=1700000000123&sign=e9ed0d5499092e76951b5f7808dec275")
        let nonce = FnOS.authx(path: "/", signed: nil).split(separator: "&")[0].dropFirst(6)
        #expect(nonce.count == 6 && Int(nonce) != nil)
    }

    @Test func aNASIsFoundByTheAddressFnOSOpensAt() async throws {
        FnOSStub.reset()
        let found = try #require(await FnOS.probe(URL(string: "http://fnos.test:5666/v/home")!, session: FnOSStub.session))
        #expect(found.isFnOS && found.address == "http://fnos.test:5666" && found.root == "/" && found.name == "fnos.test")
        #expect(FnOSStub.calls == ["GET /v/api/v1/sys/config -"])
        #expect(await FnOS.probe(URL(string: "http://other.test/")!, session: FnOSStub.session) == nil)
        #expect(try JSONDecoder().decode(AListServer.self, from: JSONEncoder().encode(found)).isFnOS)
        #expect(CloudFilesDrive.alist(found).searches)
    }

    @Test func librariesSeriesAndSeasonsListAsFolders() async throws {
        FnOSStub.reset()
        let client = FnOS(session: FnOSStub.session)
        let libraries = try await client.list(server, id: server.root)
        #expect(libraries.map(\.name) == ["电影", "电视剧"] && libraries.allSatisfy(\.isFolder) && libraries[0].id == "mdb:lib1")
        #expect(libraries[0].artwork?.absoluteString == "http://fnos.test:5666/v/api/v1/sys/img/a/b/p.webp?w=400")
        #expect(FnOSStub.calls == ["POST /v/api/v1/login -", "GET /v/api/v1/mediadb/list tok-1"])
        #expect(FnOSStub.loginBody == ["app_name": "trimemedia-web", "username": "me", "password": "pw"])

        // A library: films, series and folders; live channels aren't files.
        let films = CloudFile.arranged(try await client.list(server, id: "mdb:lib1"))
        // Finder ordering depends on the Mac's language; Chinese can sort before Latin names.
        #expect(films.count == 3 && films.prefix(2).allSatisfy(\.isFolder))
        #expect(Dictionary(uniqueKeysWithValues: films.map { ($0.id, $0.name) })
                == ["Directory:fv_1": "Home", "TV:tv1": "庆余年", "Movie:m1": "Arrival (2016).mp4"])
        #expect(films.allSatisfy { $0.isFolder || CloudFilesDrive.alist(server).plays($0) })
        let body = try #require(FnOSStub.lastBody)
        #expect(body["ancestor_guid"] as? String == "lib1" && body["parent_guid"] == nil && body["page"] as? Int == 1)
        #expect((body["tags"] as? [String: [String]])?["type"] == ["Movie", "TV", "Directory", "Video"])
        _ = try await client.list(server, id: "Directory:fv_1")
        #expect(FnOSStub.lastBody?["parent_guid"] as? String == "fv_1" && FnOSStub.lastBody?["ancestor_guid"] == nil)

        // A series with seasons lists them; a season, its episodes in order, named after the files the NAS keeps.
        let seasons = try await client.list(server, id: "TV:tv1")
        #expect(seasons.map(\.name) == ["第 1 季", "S2"] && seasons.map(\.id) == ["Season:s1", "Season:s2"])
        let episodes = CloudFile.arranged(try await client.list(server, id: "Season:s1"))
        #expect(episodes.map(\.name) == ["2. Pilot.mkv", "10. Finale.mp4"] && episodes[0].id == "Episode:e2")
        #expect(episodes.allSatisfy { CloudFilesDrive.alist(server).plays($0) })
        // A series of one season opens straight on its episodes.
        #expect(try await client.list(server, id: "TV:tv2").map(\.name) == ["1. Only.mp4"])
        #expect(FnOSStub.calls.suffix(2) == ["GET /v/api/v1/season/list/tv2 tok-1", "GET /v/api/v1/episode/list/s3 tok-1"])
    }

    @Test func anExpiredTokenOrARefusedSignatureIsTriedAgainOnce() async throws {
        FnOSStub.reset()
        let client = FnOS(session: FnOSStub.session)
        _ = try await client.list(server, id: server.root)
        FnOSStub.forgetTokens()
        _ = try await client.list(server, id: server.root)
        #expect(FnOSStub.calls.suffix(3) == ["GET /v/api/v1/mediadb/list tok-1", "POST /v/api/v1/login -", "GET /v/api/v1/mediadb/list tok-2"])
        FnOSStub.refuseNextSignature()
        #expect(try await client.list(server, id: server.root).count == 2)
        #expect(FnOSStub.calls.suffix(2) == ["GET /v/api/v1/mediadb/list tok-2", "GET /v/api/v1/mediadb/list tok-2"])
        // Without an account, or with a wrong one, the viewer is told.
        await #expect(throws: CloudFilesError.signInRequired("NAS")) {
            try await FnOS(session: FnOSStub.session).check(AListServer(name: "NAS", address: "http://fnos.test:5666", kind: .fnos))
        }
        await #expect(throws: TVError.self) {
            try await FnOS(session: FnOSStub.session).check(AListServer(name: "NAS", address: "http://fnos.test:5666", username: "me",
                                                                        password: "no", kind: .fnos))
        }
    }

    @Test func searchFindsFilmsAndSeries() async throws {
        FnOSStub.reset()
        let found = try await FnOS(session: FnOSStub.session).search(server, "Arrival", page: 1, size: 50)
        #expect(found.files.map(\.name) == ["Arrival (2016).mp4", "庆余年"] && found.total == 2)
        #expect(FnOSStub.calls.last == "GET /v/api/v1/search/list?q=Arrival tok-1")
    }

    /// The file plays as the NAS stores it, from `media/range`, each range request signed afresh.
    @Test func aFilePlaysAsTheNASStoresIt() async throws {
        FnOSStub.reset()
        let source = try await FnOS(session: FnOSStub.session).source(server, id: "Episode:e2", name: "2. Pilot.mkv")
        #expect(source.url.absoluteString == "http://fnos.test:5666/v/api/v1/media/range/media-e2")
        #expect(source.length == 1_048_576 && source.name == "S01E02.mkv")
        #expect(source.headers["Authorization"] == "tok-1" && source.headers["Cookie"] == "mode=relay")
        let fresh = try #require(source.freshHeaders?(source.url)["Authx"])
        #expect(FnOSStub.verifies(fresh, path: source.url.path, signed: Data()))
        #expect(FnOSStub.calls == ["POST /v/api/v1/login -", "GET /v/api/v1/stream/list/e2 tok-1"])
        // Its history entry goes back to the NAS.
        let channel = CloudFiles.channel(CloudFile(id: "Episode:e2", name: "2. Pilot.mkv", isFolder: false), in: .alist(server),
                                         folder: "Season:s1", folderName: "第 1 季")
        #expect(channel.historyContext?.episodeFlag == "alist.f" && channel.historyContext?.videoID == "Season:s1")
    }
}

final class FnOSStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var issued = 0, valid = 0, refuse = false
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []
    nonisolated(unsafe) private static var login: [String: String]?
    static var calls: [String] { lock.withLock { log } }
    static var lastBody: [String: Any]? { lock.withLock { bodies.last } }
    static var loginBody: [String: String]? { lock.withLock { login } }
    static func reset() { lock.withLock { log = []; issued = 0; valid = 0; refuse = false; bodies = []; login = nil } }
    static func forgetTokens() { lock.withLock { valid = issued } }
    static func refuseNextSignature() { lock.withLock { refuse = true } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FnOSStub.self]
        return URLSession(configuration: configuration)
    }()

    /// Checks `Authx` as the NAS does.
    static func verifies(_ authx: String, path: String, signed: Data) -> Bool {
        var fields: [String: String] = [:]
        for pair in authx.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        guard let nonce = fields["nonce"], let timestamp = fields["timestamp"], let sign = fields["sign"] else { return false }
        func md5(_ data: Data) -> String { Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let source = [FnOS.apiKey, path, nonce, timestamp, md5(signed), FnOS.apiSecret].joined(separator: "_")
        return md5(Data(source.utf8)) == sign
    }

    override class func canInit(with request: URLRequest) -> Bool { ["fnos.test", "other.test"].contains(request.url?.host() ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let token = request.value(forHTTPHeaderField: "Authorization")
        var raw = Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; raw.append(buffer, count: count) }
        }
        let body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        let items = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).sorted { $0.name < $1.name }
        let signed = request.httpMethod == "POST" ? raw : Data(items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&").utf8)
        let (status, answer): (Int, Any) = Self.lock.withLock {
            Self.log.append("\(request.httpMethod ?? "-") \(url.path)\(url.query.map { "?" + $0 } ?? "") \(token ?? "-")")
            if url.host() == "other.test" { return (200, "<html></html>") }
            guard request.value(forHTTPHeaderField: "Cookie") == "mode=relay",
                  Self.verifies(request.value(forHTTPHeaderField: "Authx") ?? "", path: url.path, signed: signed), !Self.refuse else {
                Self.refuse = false
                return (200, ["code": 5000, "msg": "invalid sign"])
            }
            if request.httpMethod == "POST" { Self.bodies.append(body) }
            let signedIn = token.flatMap { Int($0.dropFirst(4)) }.map { $0 > Self.valid && $0 <= Self.issued } ?? false
            func ok(_ data: Any) -> (Int, Any) { (200, ["code": 0, "msg": "", "data": data]) }
            func item(_ guid: String, _ title: String, _ type: String, _ extra: [String: Any] = [:]) -> [String: Any] {
                ["guid": guid, "title": title, "type": type].merging(extra) { $1 }
            }
            switch url.path {
            case "/v/api/v1/sys/config": return ok(["nas_oauth": ["app_id": "x", "url": ""]])
            case "/v/api/v1/login":
                Self.login = body as? [String: String]
                guard body["username"] as? String == "me", body["password"] as? String == "pw" else { return (200, ["code": -1, "msg": "用户名或密码错误"]) }
                Self.issued += 1
                return ok(["token": "tok-\(Self.issued)"])
            case _ where !signedIn: return (200, ["code": 401, "msg": "登录已过期"])
            case "/v/api/v1/mediadb/list":
                return ok([["guid": "lib1", "title": "电影", "posters": ["/a/b/p.webp"], "category": "Movie"],
                           ["guid": "lib2", "title": "电视剧", "posters": [], "category": "TV"]])
            case "/v/api/v1/item/list":
                if body["parent_guid"] as? String == "fv_1" { return ok(["list": [], "total": 0]) }
                return ok(["list": [item("m1", "Arrival", "Movie", ["poster": "/p/m1.webp", "release_date": "2016-09-01"]),
                                    item("tv1", "庆余年", "TV"), item("fv_1", "Home", "Directory"), item("lc", "CCTV-1", "LiveChannel")],
                           "total": 4, "mdb_name": "电影"])
            case "/v/api/v1/season/list/tv1":
                return ok([item("s1", "第 1 季", "Season", ["season_number": 1]), item("s2", "", "Season", ["season_number": 2])])
            case "/v/api/v1/season/list/tv2": return ok([item("s3", "第 1 季", "Season", ["season_number": 1])])
            case "/v/api/v1/episode/list/s1":
                return ok([item("e10", "Finale", "Episode", ["episode_number": 10, "file_name": "S01E10.mp4"]),
                           item("e2", "Pilot", "Episode", ["episode_number": 2, "file_name": "S01E02.mkv"])])
            case "/v/api/v1/episode/list/s3": return ok([item("e1", "Only", "Episode", ["episode_number": 1])])
            case "/v/api/v1/search/list":
                return ok([item("m1", "Arrival", "Movie", ["release_date": "2016-09-01"]), item("tv1", "庆余年", "TV")])
            case "/v/api/v1/stream/list/e2":
                return ok(["files": [["guid": "media-e2", "path": "/vol1/剧/S01E02.mkv", "file_name": "S01E02.mkv", "size": 1_048_576, "can_play": 1]],
                           "video_streams": [], "audio_streams": [], "subtitle_streams": []])
            default: return (404, ["code": 404, "msg": "not found"])
            }
        }
        let data = (answer as? String).map { Data($0.utf8) } ?? (try? JSONSerialization.data(withJSONObject: answer)) ?? Data()
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!,
                           cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }
}
