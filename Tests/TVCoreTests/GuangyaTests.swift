import Foundation
import Testing
@testable import TVCore

/// Guangya Cloud in Cloud Files (#1075), with a stand-in for its API and account service.
@Suite(.serialized) struct GuangyaTests {
    @Test func listingRowsBecomeFoldersAndFiles() throws {
        let folder = try #require(GuangyaFiles.file(["fileId": "f1", "parentId": "", "fileName": "庆余年", "resType": 2, "utime": 1_714_565_700]))
        #expect(folder.isFolder && folder.id == "f1" && folder.modified == Date(timeIntervalSince1970: 1_714_565_700))
        let file = try #require(GuangyaFiles.file(["fileId": "v1", "fileName": "第1集.mkv", "fileSize": "1234567", "resType": 1, "ctime": 0]))
        #expect(!file.isFolder && file.size == 1_234_567 && file.modified == nil)
        #expect(GuangyaFiles.file(["fileId": "v2", "fileName": ""]) == nil)
        #expect(GuangyaFiles.file(["fileName": "no id.mp4"]) == nil)
        // Cloud Files' top folder is "0"; the drive's has no id.
        #expect(GuangyaFiles.parent("0") == "" && GuangyaFiles.parent("f1") == "f1")
    }

    @Test func answersAreReadAsTheDriveSendsThem() {
        #expect(GuangyaFiles.succeeded(["code": 0, "msg": "success", "data": [:]]))
        #expect(GuangyaFiles.succeeded(["code": 0, "data": [:]]))
        #expect(!GuangyaFiles.succeeded(["code": 42, "msg": "mock failure"]))
        #expect(GuangyaFiles.rejected(["code": 117, "msg": "无效token"], status: 401))
        #expect(GuangyaFiles.rejected(["code": 117, "msg": "无效token"], status: 200))
        #expect(!GuangyaFiles.rejected(["code": 42], status: 200))
        #expect(GuangyaFiles.total("bytes 0-0/1234567") == 1_234_567 && GuangyaFiles.total(nil) == nil)
        // A device code waits while it isn't approved; anything else ends it.
        #expect(CloudDriveQRLogin.guangyaWaits("authorization_pending") && CloudDriveQRLogin.guangyaWaits("slow_down"))
        #expect(!CloudDriveQRLogin.guangyaWaits("expired_token") && !CloudDriveQRLogin.guangyaWaits(""))
    }

    @Test func theDriveListsRefreshingAnExpiredToken() async throws {
        GuangyaStub.reset()
        let saved = GuangyaSaved(GuangyaAccount(accessToken: "old", refreshToken: "r1"))
        let drive = GuangyaFiles(session: GuangyaStub.session, load: { saved.account }, store: { saved.replace($0, with: $1) })
        let files = try await drive.list("0")
        #expect(files.map(\.name) == ["庆余年", "第1集.mkv"])
        // The stale token was turned down, refreshed once, and the new tokens saved for the next request.
        #expect(GuangyaStub.calls == ["list Bearer old", "token refresh_token r1", "list Bearer new"])
        #expect(saved.account == GuangyaAccount(accessToken: "new", refreshToken: "r2"))
        let link = try await drive.link("v1", name: "第1集.mkv")
        #expect(link.url.host() == "cdn.guangya.test" && link.length == 1_234_567)
        // Its reads go out as the web page's, which the CDN wants before it serves a range.
        #expect(link.headers["Referer"] == GuangyaFiles.referer && link.headers["User-Agent"] == GuangyaFiles.userAgent)
    }

    @Test func aSignInThatCantBeRefreshedAsksForANewOne() async throws {
        GuangyaStub.reset()
        let gone = GuangyaSaved(GuangyaAccount(accessToken: "old", refreshToken: "revoked"))
        await #expect(throws: CloudFilesError.signInRequired(L10n.text("Guangya Cloud"))) {
            try await GuangyaFiles(session: GuangyaStub.session, load: { gone.account }, store: { gone.replace($0, with: $1) }).list("0")
        }
        await #expect(throws: CloudFilesError.signInRequired(L10n.text("Guangya Cloud"))) {
            try await GuangyaFiles(session: GuangyaStub.session, load: { nil }, store: { _, _ in }).list("0")
        }
    }

    @Test func aSavedSignInPutsGuangyaInCloudFiles() throws {
        #expect(try JSONDecoder().decode(CloudDriveAccounts.self, from: Data(#"{"quarkCookie":"","ucCookie":"","ucToken":"","token":""}"#.utf8)).guangya == nil)
        var accounts = CloudDriveAccounts()
        accounts.guangya = GuangyaAccount(accessToken: "a", refreshToken: "r")
        let saved = try JSONDecoder().decode(CloudDriveAccounts.self, from: JSONEncoder().encode(accounts))
        #expect(saved.guangya == GuangyaAccount(accessToken: "a", refreshToken: "r"))
        #expect(CloudFiles.drive(key: "guangya") == .guangya && CloudFilesDrive.guangya.root == "0")
        #expect(CloudFilesDrive.guangya.plays(CloudFile(id: "a", name: "第1集.mkv", isFolder: false)))
        #expect(!CloudFilesDrive.guangya.plays(CloudFile(id: "a", name: "字幕.srt", isFolder: false)))
    }
}

/// The saved sign-in a test's drive reads and refreshes.
final class GuangyaSaved: @unchecked Sendable {
    private let lock = NSLock()
    private var saved: GuangyaAccount?
    init(_ account: GuangyaAccount) { saved = account }
    var account: GuangyaAccount? { lock.withLock { saved } }
    func replace(_ refreshToken: String, with account: GuangyaAccount) {
        lock.withLock { if saved?.refreshToken == refreshToken { saved = account } }
    }
}

/// Guangya's API and account service: the listing takes only the access token "new", which the refresh token "r1"
/// gets; the download link answers its first byte, but only to the web page (Referer), as Guangya's CDN does.
final class GuangyaStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuangyaStub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool {
        ["api.guangyapan.com", "account.guangyapan.com", "cdn.guangya.test"].contains(request.url?.host() ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        let body = request.httpBodyStream.map { stream -> [String: Any] in
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        } ?? [:]
        let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
        var status = 200, headers = ["Content-Type": "application/json"]
        var answer: [String: Any] = [:]
        switch url.path {
        case "/nd.bizuserres.s/v1/file/get_file_list":
            Self.lock.withLock { Self.log.append("list \(bearer)") }
            if bearer == "Bearer new" {
                answer = ["code": 0, "msg": "success", "data": ["total": 2, "list": [
                    ["fileId": "f1", "fileName": "庆余年", "resType": 2],
                    ["fileId": "v1", "fileName": "第1集.mkv", "fileSize": 1_234_567, "resType": 1],
                ]]]
            } else { status = 401; answer = ["code": 117, "msg": "无效token"] }
        case "/nd.bizuserres.s/v1/get_res_download_url":
            answer = bearer == "Bearer new" ? ["code": 0, "msg": "success", "data": ["signedURL": "https://cdn.guangya.test/v1?sign=1"]] : ["code": 117]
        case "/v1/auth/token":
            Self.lock.withLock { Self.log.append("token \(body["grant_type"] ?? "") \(body["refresh_token"] ?? "")") }
            if body["refresh_token"] as? String == "r1", body["client_id"] as? String == GuangyaFiles.clientID {
                answer = ["access_token": "new", "refresh_token": "r2", "token_type": "Bearer", "expires_in": 7200]
            } else { status = 400; answer = ["error": "invalid_grant", "error_description": "Refresh token is invalid"] }
        default:
            guard request.value(forHTTPHeaderField: "Referer") == GuangyaFiles.referer else { headers = ["Content-Type": "text/plain"]; break }
            status = request.value(forHTTPHeaderField: "Range") == "bytes=0-0" ? 206 : 200
            headers = ["Content-Range": "bytes 0-0/1234567", "Content-Type": "video/x-matroska"]
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: answer.isEmpty ? Data([0]) : try! JSONSerialization.data(withJSONObject: answer))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
