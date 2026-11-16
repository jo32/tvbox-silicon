import Foundation
import Testing
@testable import TVCore

@Suite(.serialized) struct TianyiPan123Tests {
    // MARK: Tianyi Cloud

    @Test func tianyiRequestsAreSignedAsItsTVAppSignsThem() {
        // HMAC-SHA1 in upper-case hex, as OpenList's 189_tv driver computes it.
        #expect(TianyiFiles.signature(TianyiFiles.appSecret, "AppKey=600100885&Operate=GET&RequestURI=/family/manage/getQrCodeUUID.action&Timestamp=1700000000000")
                == "1DC2123F732269E72C593C0D0EFBD68EDB4FD5E1")
        let headers = TianyiFiles.sessionHeaders(.init(key: "key", secret: "secret"), method: "GET", path: "/listFiles.action", date: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(headers["Date"] == "Tue, 14 Nov 2023 22:13:20 GMT" && headers["SessionKey"] == "key")
        #expect(headers["Signature"] == "1482EACB6AFB6900A3E95F4AA9D4ACF94CAFDF4D")
        let request = TianyiFiles.appRequest("/family/manage/getQrCodeUUID.action", [], time: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(request.value(forHTTPHeaderField: "AppSignature") == "1DC2123F732269E72C593C0D0EFBD68EDB4FD5E1")
        #expect(request.url?.query()?.contains("clientType=FAMILY_TV") == true)
    }

    @Test func tianyiListingsAndLinksAreRead() {
        let answer: [String: Any] = ["res_code": 0, "fileListAO": ["count": 2,
            "folderList": [["id": 71_234, "parentId": -11, "name": "庆余年", "lastOpTime": "2024-05-01 20:15:00"]],
            "fileList": [["id": "81234", "name": "第1集.mkv", "size": 1_234_567, "md5": "abc", "lastOpTime": "2024-05-01 20:15:00"]]]]
        let files = TianyiFiles.files(answer)
        #expect(files.map(\.id) == ["71234", "81234"] && files.map(\.isFolder) == [true, false])
        #expect(files[1].size == 1_234_567 && files[1].modified == Date(timeIntervalSince1970: 1_714_565_700))
        #expect(TianyiFiles.failure(answer) == nil)
        #expect(TianyiFiles.failure(["res_code": "InvalidSessionKey", "res_message": "session expired"]) == "session expired")
        #expect(TianyiFiles.failure(["errorCode": "InvalidArgument", "errorMsg": "bad"]) == "bad")
        #expect(TianyiFiles.downloadAddress(["fileDownloadUrl": "http://download.cloud.189.cn/file?a=1&amp;b=2"])?.absoluteString
                == "https://download.cloud.189.cn/file?a=1&b=2")
        #expect(TianyiFiles.downloadAddress(["res_code": 0]) == nil)
    }

    @Test func tianyiSignInCodeIsReadAsItAnswers() {
        // Waiting is an error answer; approval carries the access token.
        #expect(CloudDriveQRLogin.tianyiStatus(Data(#"{"res_code":"QrCodeRollLoginFail","res_message":"二维码未登录"}"#.utf8)) == .waiting)
        #expect(CloudDriveQRLogin.tianyiStatus(Data(#"{"res_code":"QrCodeExpire"}"#.utf8)) == .expired)
        #expect(CloudDriveQRLogin.tianyiStatus(Data(#"{"accessToken":"tok","expiresIn":2592000}"#.utf8))
                == .signedIn(.init(cookie: "", serviceTicket: nil, accessToken: "tok")))
    }

    @Test func tianyiListsWithASessionFromTheSavedToken() async throws {
        TianyiStub.reset()
        let files = try await TianyiFiles(session: TianyiStub.session, account: { "ok" }).list("-11")
        #expect(files.map(\.name) == ["庆余年", "第1集.mkv"])
        #expect(TianyiStub.calls.first?.contains("loginFamilyMerge.action") == true && TianyiStub.calls.first?.contains("e189AccessToken=ok") == true)
        #expect(TianyiStub.calls.last?.contains("folderId=-11") == true)
        await #expect(throws: CloudFilesError.signInRequired(L10n.text("Tianyi Cloud"))) {
            try await TianyiFiles(session: TianyiStub.session, account: { "revoked" }).list("-11")
        }
        await #expect(throws: CloudFilesError.signInRequired(L10n.text("Tianyi Cloud"))) {
            try await TianyiFiles(session: TianyiStub.session, account: { "" }).list("-11")
        }
    }

    // MARK: 123pan

    @Test func pan123RequestsCarryTheWebAppsSign() {
        // The CRC-32 sign OpenList's 123 driver computes, for 2023-11-15 06:13 in China.
        let (name, value) = Pan123Files.sign(path: "/b/api/file/list/new", time: Date(timeIntervalSince1970: 1_700_000_000), random: 1_234_567)
        #expect(name == "883022862" && value == "1700000000-1234567-226109213")
        #expect(Pan123Files.headers(token: "tok")["Authorization"] == "Bearer tok")
    }

    @Test func pan123ListingsAndLinksAreRead() throws {
        let folder = try #require(Pan123Files.file(["FileId": 10, "FileName": "庆余年", "Type": 1, "Size": 0, "UpdateAt": "2024-05-01T20:15:00+08:00"]))
        #expect(folder.id == "10" && folder.isFolder && folder.modified == Date(timeIntervalSince1970: 1_714_565_700))
        let file = try #require(Pan123Files.file(["FileId": 11, "FileName": "第1集.mkv", "Type": 0, "Size": 1_234_567, "Etag": "e1", "S3KeyFlag": "1-0"]))
        #expect(!file.isFolder && file.size == 1_234_567)
        #expect(Pan123Files.FileKey(file.id) == .init(id: 11, etag: "e1", flag: "1-0", size: 1_234_567))
        #expect(Pan123Files.FileKey("11") == nil)
        // The real address is base64 in `params`; the CDN wants the link's own site as Referer.
        let wrapped: [String: Any] = ["code": 0, "data": ["DownloadUrl": "https://web-pro2.123952.com/download-v2/?params=aHR0cHM6Ly9kb3dubG9hZC4xMjMyOTUuY29tL2EvYi5ta3Y/YXV0aD0x&is_s3=0"]]
        let link = try #require(Pan123Files.download(wrapped))
        #expect(link.0.absoluteString == "https://download.123295.com/a/b.mkv?auth=1" && link.1 == "https://web-pro2.123952.com/")
        let plain = try #require(Pan123Files.download(["data": ["DownloadUrl": "https://cdn.123pan.cn/x.mp4?s=1"]]))
        #expect(plain.0.absoluteString == "https://cdn.123pan.cn/x.mp4?s=1")
    }

    @Test func pan123SignInCodeIsReadAsItAnswers() throws {
        let code = try #require(CloudDriveQRLogin.pan123Code(Data(#"{"code":0,"message":"ok","data":{"url":"https://yun.123pan.cn/wx-app-login.html","uniID":"u1"}}"#.utf8)))
        #expect(code.id == "u1" && code.code == "https://yun.123pan.cn/wx-app-login.html?env=production&uniID=u1&source=123pan&type=login")
        #expect(CloudDriveQRLogin.pan123Code(Data(#"{"code":1,"message":"busy"}"#.utf8)) == nil)
        #expect(CloudDriveQRLogin.pan123Status(Data(#"{"code":0,"data":{"loginStatus":0,"scanPlatform":0}}"#.utf8)) == .waiting)
        #expect(CloudDriveQRLogin.pan123Status(Data(#"{"code":0,"data":{"loginStatus":1,"scanPlatform":1}}"#.utf8)) == .waiting)
        #expect(CloudDriveQRLogin.pan123Status(Data(#"{"code":0,"data":{"loginStatus":2}}"#.utf8)) == .expired)
        #expect(CloudDriveQRLogin.pan123Status(Data(#"{"code":0,"data":{"loginStatus":4}}"#.utf8)) == .expired)
        #expect(CloudDriveQRLogin.pan123Status(Data(#"{"code":200,"data":{"loginStatus":3,"token":"Bearer t1"}}"#.utf8))
                == .signedIn(.init(cookie: "", serviceTicket: nil, accessToken: "t1")))
        // Approved in WeChat: the token takes another step.
        #expect(CloudDriveQRLogin.pan123Status(Data(#"{"code":0,"data":{"loginStatus":3,"scanPlatform":4}}"#.utf8)) == nil)
    }

    @Test func pan123ListsWithTheSavedToken() async throws {
        Pan123Stub.reset()
        let files = try await Pan123Files(session: Pan123Stub.session, account: { "ok" }).list("0")
        #expect(files.map(\.name) == ["庆余年", "第1集.mkv"])
        let call = try #require(Pan123Stub.calls.first)
        #expect(call.contains("/b/api/file/list/new?") && call.contains("parentFileId=0") && call.contains("-"))
        await #expect(throws: CloudFilesError.signInRequired(L10n.text("123pan"))) {
            try await Pan123Files(session: Pan123Stub.session, account: { "old" }).list("0")
        }
    }

    /// Asks both services for a real sign-in code and checks it once: nobody has scanned it, so both say they're waiting.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TVBOX_LIVE_SIGNIN_CODES"] != nil))
    func realSignInCodesStart() async throws {
        for drive in [CloudDriveQRLogin.Drive.tianyi, .pan123] {
            let login = try await CloudDriveQRLogin.start(drive)
            #expect(login.code.hasPrefix("https://"), "\(drive): \(login.code)")
            #expect(try await login.poll() == .waiting, "\(drive)")
        }
    }

    // MARK: Cloud Files

    @Test func cloudFilesKnowsBothDrives() throws {
        #expect(CloudFilesDrive.tianyi.key == "tianyi" && CloudFilesDrive.tianyi.root == "-11")
        #expect(CloudFilesDrive.pan123.key == "pan123" && CloudFilesDrive.pan123.root == "0")
        #expect(CloudFiles.drive(key: "tianyi") == .tianyi && CloudFiles.drive(key: "pan123") == .pan123)
        #expect(CloudFilesDrive.tianyi.plays(CloudFile(id: "a", name: "第1集.mkv", isFolder: false)))
        #expect(CloudFilesDrive.pan123.searches)
        var accounts = CloudDriveAccounts()
        accounts.tianyiToken = "t"; accounts.pan123Token = "p"
        let saved = try JSONDecoder().decode(CloudDriveAccounts.self, from: JSONEncoder().encode(accounts))
        #expect(saved.tianyiToken == "t" && saved.pan123Token == "p")
        #expect(try JSONDecoder().decode(CloudDriveAccounts.self, from: Data(#"{"quarkCookie":"","ucCookie":"","ucToken":"","token":""}"#.utf8)).tianyiToken == nil)
    }
}

/// Tianyi Cloud's API: a session for the token "ok", a listing for that session, and a refusal for anything else.
final class TianyiStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TianyiStub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "api.cloud.189.cn" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.log.append(url.absoluteString) }
        let answer: [String: Any]
        if url.path() == "/family/manage/loginFamilyMerge.action" {
            answer = url.query()?.contains("e189AccessToken=ok") == true
                ? ["res_code": 0, "sessionKey": "sk", "sessionSecret": "ss", "loginName": "138****0000"]
                : ["res_code": "InvalidAccessToken", "res_message": "token invalid"]
        } else if request.value(forHTTPHeaderField: "SessionKey") == "sk", request.value(forHTTPHeaderField: "Signature")?.count == 40 {
            answer = ["res_code": 0, "fileListAO": ["count": 2, "folderList": [["id": 1, "name": "庆余年"]],
                                                    "fileList": [["id": 2, "name": "第1集.mkv", "size": 10]]]]
        } else {
            answer = ["res_code": "InvalidSessionKey", "res_message": "InvalidSessionKey"]
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// 123pan's file listing for the token "ok", and the expired-token answer for any other.
final class Pan123Stub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Pan123Stub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "yun.123pan.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.log.append(url.absoluteString) }
        let answer: [String: Any] = request.value(forHTTPHeaderField: "Authorization") == "Bearer ok"
            ? ["code": 0, "message": "ok", "data": ["Next": "-1", "Total": 2, "InfoList": [
                ["FileId": 10, "FileName": "庆余年", "Type": 1, "Size": 0],
                ["FileId": 11, "FileName": "第1集.mkv", "Type": 0, "Size": 10, "Etag": "e", "S3KeyFlag": "f"],
            ]]]
            : ["code": 401, "message": "token is expired"]
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
