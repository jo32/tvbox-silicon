import Foundation
import Security

/// 115 through its web API, signed in with the cookie (UID, CID, SEID, KID) saved under Cloud Drive Accounts.
/// A folder is known by its id (`cid`), a file by its pick code, which is what its download link is asked with.
/// 115 hands over each file as it is stored; it has no transcoded copy to fall back on.
actor Pan115Files {
    static let shared = Pan115Files()
    /// 115's own browser. A download link opens only with the User-Agent that asked for it.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 115Browser/27.0.5.7"
    /// Files per listing request; 115 serves at most 1,150.
    static let pageSize = 1000

    private let session: URLSession
    private let account: @Sendable () -> String
    /// The saved cookie the jar was built from; signing in again starts a new jar.
    private var signedIn = ""
    private var jar = CookieJar()

    init(session: URLSession? = nil, account: (@Sendable () -> String)? = nil) {
        self.session = session ?? {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            return URLSession(configuration: configuration)
        }()
        self.account = account ?? { ((try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()).pan115Cookie ?? "" }
    }

    private var name: String { L10n.text("115 Cloud") }

    func list(_ folder: String) async throws -> [CloudFile] {
        var files: [CloudFile] = [], offset = 0
        for _ in 0..<50 {
            let answer = try await call(URL(string: "https://webapi.115.com/files?aid=1&cid=\(folder)&o=user_ptime&asc=1&offset=\(offset)&show_dir=1&limit=\(Self.pageSize)&snap=0&natsort=0&record_open_time=1&format=json&fc_mix=0")!)
            let items = answer["data"] as? [[String: Any]] ?? []
            files += items.compactMap(Self.file)
            offset += items.count
            if items.isEmpty || offset >= Self.number(answer["count"]).map(Int.init) ?? offset { break }
        }
        return files
    }

    /// Files and folders anywhere in the drive whose names hold `keywords`.
    func search(_ keywords: String, page: Int, size: Int) async throws -> (files: [CloudFile], total: Int) {
        let words = keywords.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))) ?? keywords
        let answer = try await call(URL(string: "https://webapi.115.com/files/search?aid=1&cid=0&search_value=\(words)&offset=\((page - 1) * size)&limit=\(size)&format=json")!)
        let files = (answer["data"] as? [[String: Any]] ?? []).compactMap(Self.file)
        return (files, Self.number(answer["count"]).map(Int.init) ?? files.count)
    }

    /// A listing row. Files carry `fid` and the pick code `pc`; folders only their own `cid` (and a pick code of their own).
    static func file(_ item: [String: Any]) -> CloudFile? {
        guard let name = item["n"] as? String, !name.isEmpty else { return nil }
        // `te` is when it last changed; a file's `t` is the same as "2024-05-01 20:15" in China's time.
        let modified = (number(item["te"]) ?? number(item["t"])).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        if text(item["fid"]) != nil {
            guard let pickCode = text(item["pc"]) else { return nil }
            return CloudFile(id: pickCode, name: name, isFolder: false, size: number(item["s"]) ?? 0, modified: modified)
        }
        guard let folder = text(item["cid"]) else { return nil }
        return CloudFile(id: folder, name: name, isFolder: true, modified: modified)
    }

    func stream(_ pickCode: String, name: String) async throws -> URL {
        guard CloudFile.playsOriginal(name) else { throw CloudFilesError.unsupportedFormat((name as NSString).pathExtension) }
        let source = try await link(pickCode, name: name)
        return CloudStreams.register(source) { [self] in try? await link(pickCode, name: name) }
    }

    /// The file's download link, through the app API the 115 browser uses; its request and answer are m115-encoded.
    private func link(_ pickCode: String, name: String) async throws -> CloudStreams.Source {
        let key = M115.key()
        let request = try JSONSerialization.data(withJSONObject: ["pickcode": pickCode])
        let answer = try await call(URL(string: "https://proapi.115.com/app/chrome/downurl?t=\(Int(Date().timeIntervalSince1970))")!,
                                    form: ["data": try M115.encode(request, key: key)])
        guard let encoded = answer["data"] as? String, let decoded = try? M115.decode(encoded, key: key), let found = Self.download(decoded) else {
            throw TVError.unsupported(L10n.text("%@ didn't return a link for this file. Try again.", self.name))
        }
        return CloudStreams.Source(url: found.url, headers: cdnHeaders, length: found.size, name: name)
    }

    /// The link in a decoded answer, `{"<file id>": {"file_size": "…", "url": {"url": "…"}}}`. A file 115 won't
    /// hand over has `"url": false`.
    static func download(_ data: Data) -> (url: URL, size: Int)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object.values.first as? [String: Any],
              let address = (info["url"] as? [String: Any])?["url"] as? String,
              let url = URL(string: address) ?? address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)),
              let size = number(info["file_size"]), size > 0 else { return nil }
        return (url, Int(size))
    }

    /// The CDN wants the account's cookies, with those the link's answer set, and the User-Agent that asked.
    private var cdnHeaders: [String: String] { ["Cookie": jar.header, "User-Agent": Self.userAgent] }

    private func call(_ url: URL, form: [String: String]? = nil) async throws -> [String: Any] {
        let saved = account().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.isEmpty else { throw CloudFilesError.signInRequired(name) }
        if saved != signedIn { signedIn = saved; jar = CookieJar(saved) }
        var request = URLRequest(url: url)
        request.setValue(jar.header, forHTTPHeaderField: "Cookie")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&").utf8)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse { jar.update(http) }
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if answer["state"] as? Bool == true, (200..<300).contains(status) { return answer }
        let message = (answer["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? answer["msg"] as? String ?? ""
        let code = Self.number(answer["errno"]) ?? Self.number(answer["errNo"]) ?? -1
        Diagnostics.shared.record(.warning, "files", "pan115 \(url.host ?? "")\(url.path) status=\(status) errno=\(code) \(message)")
        // 99 "请重新登录" and 990001 "登录超时，请重新登录。": the sign-in is missing or has expired.
        if status == 401 || code == 99 || code == 990001 || message.contains("登录") { throw CloudFilesError.signInRequired(name) }
        if !message.isEmpty { throw TVError.unsupported(L10n.text("%@ says: %@", name, message)) }
        throw TVError.http(status)
    }

    /// 115 sends numbers and ids as JSON numbers or as text.
    static func number(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        return (value as? String).flatMap { Int64($0) }
    }
    static func text(_ value: Any?) -> String? {
        let text = (value as? String) ?? (value as? NSNumber)?.stringValue
        return text?.isEmpty == false ? text : nil
    }
}

/// The m115 wrapping around the request and answer of 115's download API (as in deadblue/elevengo, MIT): two
/// XOR layers around a reversal, then RSA with 115's public key in PKCS #1 v1.5 blocks. The answer comes back
/// signed with the private key, so the same public key opens it.
enum M115 {
    struct Malformed: Error {}

    static func key() -> [UInt8] { (0..<16).map { _ in UInt8.random(in: .min ... .max) } }

    static func encode(_ input: Data, key: [UInt8], publicKey: SecKey = M115.publicKey) throws -> String {
        var data = [UInt8](input)
        xor(&data, derive(key, 4))
        data.reverse()
        xor(&data, clientKey)
        let buffer = key + data
        var output = Data()
        // A 1,024-bit key takes 117 bytes per block with PKCS #1 v1.5 padding.
        for start in stride(from: 0, to: buffer.count, by: 117) {
            output += try rsa(publicKey, .rsaEncryptionPKCS1, Data(buffer[start..<min(start + 117, buffer.count)]))
        }
        return output.base64EncodedString()
    }

    static func decode(_ input: String, key: [UInt8], publicKey: SecKey = M115.publicKey) throws -> Data {
        guard let raw = Data(base64Encoded: input) else { throw Malformed() }
        let bytes = [UInt8](raw)
        var plain: [UInt8] = []
        for start in stride(from: 0, to: bytes.count, by: 128) {
            let slice = bytes[start..<min(start + 128, bytes.count)]
            let block = [UInt8](try rsa(publicKey, .rsaEncryptionRaw, Data(repeating: 0, count: 128 - slice.count) + slice))
            // 00 01 FF … FF 00, then the data.
            let body = block.drop { $0 == 0 }
            if let end = body.dropFirst().firstIndex(of: 0) { plain += body[(end + 1)...] }
        }
        guard plain.count >= 16 else { throw Malformed() }
        var data = Array(plain[16...])
        xor(&data, derive(Array(plain[..<16]), 12))
        data.reverse()
        xor(&data, derive(key, 4))
        return Data(data)
    }

    /// 115's public key, PKCS #1 DER of its 1,024-bit modulus and exponent 65537.
    nonisolated(unsafe) static let publicKey: SecKey = publicKey(der: Data(base64Encoded:
        "MIGJAoGBAIaGmAwPWiTEudQwIM0sInA/8/RQdWUpBYsc+I8JuGAhNkdxmKbiaDFJZZvRIsM1kv21rUeUStHqTTbGsXKq1jOMO7asYidQLQEJk6yWfRrvAPDI4DjeLk07wuw2ivLp8QpvHtpPcmLxNkIMB8MxuHG/E5908wEOPE/lffOvtxaDAgMBAAE=")!)!

    static func publicKey(der: Data) -> SecKey? {
        SecKeyCreateWithData(der as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil)
    }

    /// The raw public-key operation on one block (m^e mod n), which opens a block 115 signed.
    static func rsa(_ key: SecKey, _ algorithm: SecKeyAlgorithm, _ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let result = SecKeyCreateEncryptedData(key, algorithm, data as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? Malformed()
        }
        return result
    }

    static func derive(_ seed: [UInt8], _ size: Int) -> [UInt8] {
        (0..<size).map { (seed[$0] &+ table[size * $0]) ^ table[size * (size - $0 - 1)] }
    }

    /// XOR with `key` repeated, restarting it after the first `count % 4` bytes.
    static func xor(_ data: inout [UInt8], _ key: [UInt8]) {
        let head = data.count % 4
        for index in data.indices { data[index] ^= key[(index < head ? index : index - head) % key.count] }
    }

    private static let table: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
    ]
    private static let clientKey: [UInt8] = [0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46]
}
