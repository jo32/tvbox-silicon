import Foundation
import Security
import Testing
@testable import TVCore

/// 115 (issue #332). The m115 vectors come from deadblue/elevengo's reference code (Go): the real key's raw
/// operation, and with a throwaway test key standing in for 115's, a request before RSA and an answer as 115 signs it.
@Suite(.serialized) struct Pan115Tests {
    /// A 1,024-bit RSA key made only for these tests, PKCS #1 DER.
    static let testPrivate = Data(base64Encoded: "MIICXQIBAAKBgQDGK7ITkMaWdMBeN2xakT6ClpUbSgGQ8x6wtJhUrL8AVwjZLpF33Qra0aJ0fdeepqzAU2f+UDtHd9x9Sz36xdeiYO2MjPKmud+vjlW7NZt4NQ1B72ZFJ1QLtq8Gp0ePbolmGcwJxzFIH3urXPCyp1gSROhuPq2tMIQpQkpe6T6kAQIDAQABAoGAAosDAP9FnR6obU0Wxd7BR5m5Fh2QAZUtGqVmoweId++l/Gt9kGU0w3QXOpl2z+FhrCIl3nyXFiaynKT/iZ1KVBRTt+H2ktEO33q20Oq6Lr5XWP6edW3AgRJp4EMhV3jShmsH2U3mM3L0muOG+DwJmO+wWTacHKlT21z4mlycWSUCQQDaL9mMD/Nww+vVbWgr+BzLM4N4W79woN4fU3DmwjbU0jcDUVTWNYbmqM9EAfOEGT4t71/1mzRsWUuh+dn6CH5fAkEA6IPMq4PLcf4S/eqRRi7u40c5wckP2NAmT4kKB9717NFKApyylTSSS/wAR9pspKqYCTAukIHMpZHYzuXgzEs5nwJALHcL8stdZWHIMhq13CAYXiEFbgXkoeNm4SN0ItL5sa2VoIt2qqEF+QP2GXn8UrOCRIJAICGdMWeRTlVI4vfQKQJBALy7Hsqpc93XafsJB1p8hhOdoNgXJ/HJIw+0IJw68kuDphtwrdRGk+lxZ5jrRvxyLG5o2aMaeM58EAwAs/Ofq+kCQQCXFRRCTQh53ozyir8YIoLySirQzekU75+S4oDMsp4I89mV+VUtkfOYnsTVVtTKO8TCfoaynRLCkemH09TKog35")!
    static let testPublic = Data(base64Encoded: "MIGJAoGBAMYrshOQxpZ0wF43bFqRPoKWlRtKAZDzHrC0mFSsvwBXCNkukXfdCtrRonR9156mrMBTZ/5QO0d33H1LPfrF16Jg7YyM8qa536+OVbs1m3g1DUHvZkUnVAu2rwanR49uiWYZzAnHMUgfe6tc8LKnWBJE6G4+ra0whClCSl7pPqQBAgMBAAE=")!
    static let clientKey: [UInt8] = Array(1...16)

    @Test func theRealKeyOpensABlockAs115Does() throws {
        let block = Data(base64Encoded: "AAoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4/wYNFBsiKTA3PkVMU1phaG92fYSLkpmgp661vMPK0djf5u30+wIJEBceJSwzOkFIT1ZdZGtyeYCHjpWco6qxuL/GzdTb4unw9/4FDBMaISgvNj1ES1JZYGdudXw=")!
        let expected = Data(base64Encoded: "Rax6MoUtx/0gp8sof0qfPk5V4b2xNYWaform19qQ6ieLGHgNqej8mIWzlEmejv839zCf+6f7PUcGZinPW/jFCXDhkVXIVnhQYsHuyq6dOmpLQaVViiDovyrh2c6JXmx8Li750twt2CAmw3FxFxNV8q1vJsitvXb9Qag+yZ/AkM0=")!
        #expect(try M115.rsa(M115.publicKey, .rsaEncryptionRaw, block) == expected)
    }

    @Test func anAnswerSignedBy115Opens() throws {
        let key = try #require(M115.publicKey(der: Self.testPublic))
        let answer = "YJ2sbYKwu99QvXS56oVDoDjLO9HydJvkqhbEQhejdSPj3JL8KR2atEKMUvVTDZefCpfDtH5hxTW8tlGaPiy79q/yy8PX6uRNA2OMivWOCIWLwIl0Hncbo/lgjbzAEKXmggf86A1/XtGQ+AkG2vuMMpAc13vPg+nfYEAOvtgYZlK+LMq8+PMzZ6NxxHUoVlHwYpBEiTa55AelWAJ4rfW3y4wPM4FTw+XtC59TG+uDpwAYKdSa6x5pvljdn3HFHVKTLm/bIyFak2tCwGknRvSWYHOn4VhBprOsq2HsO/ezcq6LIs3LQrBnixtzBlrY1yWodw3kmV0W7QfRqZMf1kuPSA=="
        let plain = try M115.decode(answer, key: Self.clientKey, publicKey: key)
        #expect(String(decoding: plain, as: UTF8.self).hasPrefix(#"{"a1b2c3":{"file_name":"第1集.mkv","file_size":"1234567""#))
        let link = try #require(Pan115Files.download(plain))
        #expect(link.size == 1_234_567 && link.url.host() == "cdnfhnfile.115cdn.net" && link.url.query()?.contains("s=2") == true)
        // Another request's key doesn't open it.
        #expect((try? M115.decode(answer, key: Array(repeating: 9, count: 16), publicKey: key)).flatMap(Pan115Files.download) == nil)
    }

    @Test func aRequestIsWrappedAs115Expects() throws {
        let publicKey = try #require(M115.publicKey(der: Self.testPublic))
        let privateKey = try #require(SecKeyCreateWithData(Self.testPrivate as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, nil))
        let encoded = try M115.encode(Data(#"{"pickcode":"a1b2c3"}"#.utf8), key: Self.clientKey, publicKey: publicKey)
        let blocks = [UInt8](try #require(Data(base64Encoded: encoded)))
        #expect(blocks.count == 128)
        let opened = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, Data(blocks) as CFData, nil) as Data?)
        #expect(opened == Data(base64Encoded: "AQIDBAUGBwgJCgsMDQ4PEHT47kIP82ywS9T41lO1vkpe+C3z7w=="))
    }

    @Test func aFileThat115WontHandOverHasNoLink() {
        #expect(Pan115Files.download(Data(#"{"1":{"file_name":"a.mkv","file_size":"10","url":false}}"#.utf8)) == nil)
        #expect(Pan115Files.download(Data(#"{"1":{"file_size":10,"url":{"url":"https://cdn.115.test/a.mkv"}}}"#.utf8))?.size == 10)
    }

    @Test func listingRowsBecomeFoldersAndFiles() throws {
        let folder = try #require(Pan115Files.file(["cid": "2593093001", "pid": "0", "n": "庆余年", "pc": "fcabc", "te": "1714565700"]))
        #expect(folder.isFolder && folder.id == "2593093001" && folder.modified == Date(timeIntervalSince1970: 1_714_565_700))
        // A file is played by its pick code, not its id.
        let file = try #require(Pan115Files.file(["fid": "2593093112", "cid": 2593093001, "n": "第1集.mkv", "s": 1_234_567, "pc": "a1b2c3", "t": "2024-05-01 20:15"]))
        #expect(!file.isFolder && file.id == "a1b2c3" && file.size == 1_234_567 && file.modified == nil)
        #expect(Pan115Files.file(["fid": "1", "n": "no pick code.mp4"]) == nil)
        #expect(Pan115Files.file(["cid": "1", "n": ""]) == nil)
    }

    @Test func theDriveListsAndAsksForASignInWhenTheCookieIsStale() async throws {
        Pan115Stub.reset()
        let files = try await Pan115Files(session: Pan115Stub.session, account: { "UID=ok; CID=c; SEID=s" }).list("0")
        #expect(files.map(\.name) == ["庆余年", "第1集.mkv"] && files[1].id == "a1b2c3")
        #expect(Pan115Stub.calls.first?.contains("cid=0") == true && Pan115Stub.calls.first?.contains("show_dir=1") == true)
        await #expect(throws: CloudFilesError.signInRequired(L10n.text("115 Cloud"))) {
            try await Pan115Files(session: Pan115Stub.session, account: { "UID=old; CID=c; SEID=s" }).list("0")
        }
        await #expect(throws: CloudFilesError.signInRequired(L10n.text("115 Cloud"))) {
            try await Pan115Files(session: Pan115Stub.session, account: { "" }).list("0")
        }
    }

    @Test func cloudFilesKnows115() {
        #expect(CloudFilesDrive.pan115.key == "pan115" && CloudFilesDrive.pan115.root == "0")
        #expect(CloudFilesDrive.pan115.plays(CloudFile(id: "a", name: "第1集.mkv", isFolder: false)))
        #expect(CloudFilesDrive.pan115.plays(CloudFile(id: "a", name: "歌.flac", isFolder: false)))
        // A playlist kept on the drive names segments 115 doesn't serve by those names.
        #expect(!CloudFilesDrive.pan115.plays(CloudFile(id: "a", name: "index.m3u8", isFolder: false)))
        #expect(!CloudFilesDrive.pan115.plays(CloudFile(id: "a", name: "字幕.srt", isFolder: false)))
    }

    @Test func theSignInCodeIsReadAs115AnswersIt() {
        // Held open with nothing to say, scanned, approved, expired, and a code that is gone.
        #expect(CloudDriveQRLogin.pan115Status(Data(#"{"state":1,"code":0,"message":"","data":{}}"#.utf8)) == nil)
        #expect(CloudDriveQRLogin.pan115Status(Data(#"{"state":1,"data":{"msg":"扫码成功","status":1,"version":"v1"}}"#.utf8)) == 1)
        #expect(CloudDriveQRLogin.pan115Status(Data(#"{"state":1,"data":{"msg":"登录成功","status":2}}"#.utf8)) == 2)
        #expect(CloudDriveQRLogin.pan115Status(Data(#"{"state":1,"data":{"status":-1}}"#.utf8)) == -1)
        #expect(CloudDriveQRLogin.pan115Status(Data(#"{"state":0,"code":40199002,"message":"二维码已过期"}"#.utf8)) == -1)
        let approved = Data(#"{"state":1,"data":{"user_id":1,"cookie":{"CID":"c1","KID":"k1","SEID":"s1","UID":"1_A1_2"}}}"#.utf8)
        #expect(CloudDriveQRLogin.pan115Cookie(approved) == "UID=1_A1_2; CID=c1; SEID=s1; KID=k1")
        #expect(CloudDriveQRLogin.pan115Cookie(Data(#"{"state":0,"error":"老乡验证失败！","errno":40101017}"#.utf8)) == nil)
    }

    @Test func aSavedSignInPuts115InCloudFiles() throws {
        var accounts = CloudDriveAccounts()
        #expect(try JSONDecoder().decode(CloudDriveAccounts.self, from: Data(#"{"quarkCookie":"","ucCookie":"","ucToken":"","token":""}"#.utf8)).pan115Cookie == nil)
        accounts.pan115Cookie = "UID=1; CID=2; SEID=3"
        let saved = try JSONDecoder().decode(CloudDriveAccounts.self, from: JSONEncoder().encode(accounts))
        #expect(saved.pan115Cookie == "UID=1; CID=2; SEID=3")
        #expect(CloudFiles.drive(key: "pan115") == .pan115)
    }
}

/// 115's file listing: one folder and one file for the account "UID=ok", and the expired-login answer for any other.
final class Pan115Stub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    static var calls: [String] { lock.withLock { log } }
    static func reset() { lock.withLock { log = [] } }
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Pan115Stub.self]
        return URLSession(configuration: configuration)
    }()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == "webapi.115.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.lock.withLock { Self.log.append(url.absoluteString) }
        let answer: [String: Any]
        if request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("UID=ok") == true {
            answer = ["state": true, "count": 2, "offset": 0, "cid": "0", "data": [
                ["cid": "100", "pid": "0", "n": "庆余年", "pc": "fc100", "te": "1714565700"],
                ["fid": "200", "cid": "0", "n": "第1集.mkv", "s": "1234567", "pc": "a1b2c3", "t": "2024-05-01 20:15", "te": "1714565700"],
            ]]
        } else {
            answer = ["state": false, "error": "登录超时，请重新登录。", "errNo": 990001, "errno": 990001]
        }
        client.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: answer))
        client.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
