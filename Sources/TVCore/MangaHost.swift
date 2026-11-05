import Foundation
import CommonCrypto
import CoreGraphics
import ImageIO
import Security

/// Native services for Venera comic sources: `__host('manga.*', json)` in ScriptAssets/venera/prelude.js.
/// Called on the source's script thread; may block it.
final class MangaHost: ScriptHostExtension, @unchecked Sendable {
    let sourceKey: String
    private let pending = PendingRequests()
    let bitmaps = MangaBitmaps()

    init(sourceKey: String) { self.sourceKey = sourceKey }
    deinit { pending.cancelAll() }

    func answer(_ operation: String, _ argument: String) throws -> String?? {
        guard operation.hasPrefix("manga.") else { return nil }
        let request = (try? JSONSerialization.jsonObject(with: Data(argument.utf8), options: [.fragmentsAllowed])) as? [String: Any] ?? [:]
        switch operation.dropFirst("manga.".count) {
        case "httpStart":
            let id = pending.add()
            let cancel = MangaHTTP.start(request) { [pending] answer in pending.finish(id, answer) }
            pending.setCancel(id, cancel)
            return .some(String(id))
        case "httpPoll": return .some(pending.take(Int(argument) ?? -1))
        case "data": return .some(try MangaSourceData.shared.handle(request, fallbackKey: sourceKey))
        case "cookie": return .some(try MangaCookieJar.shared.handle(request))
        case "uuid": return .some(Self.json(UUID().uuidString.lowercased()))
        case "locale": return .some(Self.json(Self.locale))
        case "platform":
            #if os(macOS)
            return .some(Self.json("macos"))
            #else
            return .some(Self.json("ios"))
            #endif
        case "notice":
            let text = (request["text"] as? String) ?? (request["url"] as? String) ?? ""
            Diagnostics.shared.record(.info, "manga.notice", "source=\(sourceKey) \(text.prefix(300))")
            if !text.isEmpty {
                let key = sourceKey
                DispatchQueue.main.async { NotificationCenter.default.post(name: MangaRuntime.noticeNotification, object: nil, userInfo: ["source": key, "text": text]) }
            }
            return .some(nil)
        case "encode":
            let text = request["text"] as? String ?? ""
            let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((request["encoding"] as? String ?? "gbk") as CFString))
            return .some(Self.json((text.data(using: String.Encoding(rawValue: encoding)) ?? Data(text.utf8)).base64EncodedString()))
        case "cipher": return .some(Self.json(try Self.cipher(request).base64EncodedString()))
        case "rsaDecrypt": return .some(Self.json(try Self.rsaDecrypt(request).base64EncodedString()))
        case "image": return .some(try bitmaps.handle(request))
        default: throw ScriptHostError("unsupported host operation \(operation)")
        }
    }

    static func json(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Venera's locale format: languageCode_countryCode ("zh_CN", "zh_TW", "en_US").
    static var locale: String {
        let language = Locale.preferredLanguages.first ?? "en-US"
        if language.hasPrefix("zh") {
            return language.contains("Hant") || language.hasSuffix("TW") || language.hasSuffix("HK") ? "zh_TW" : "zh_CN"
        }
        let parts = language.split(separator: "-")
        let region = Locale.current.region?.identifier ?? "US"
        return "\(parts.first ?? "en")_\(parts.count > 1 && parts.last!.count == 2 ? String(parts.last!) : region)"
    }

    private static func bytes(_ request: [String: Any], _ name: String) -> Data {
        Data(base64Encoded: request[name] as? String ?? "", options: .ignoreUnknownCharacters) ?? Data()
    }

    /// AES in CFB or OFB, without padding, as Venera's Convert.encryptAesCfb/Ofb.
    static func cipher(_ request: [String: Any]) throws -> Data {
        let key = bytes(request, "key"), data = bytes(request, "data")
        var iv = bytes(request, "iv")
        if iv.count != kCCBlockSizeAES128 { iv = Data(count: kCCBlockSizeAES128) }
        let mode: CCMode
        switch request["mode"] as? String {
        case "ofb": mode = CCMode(kCCModeOFB)
        default: mode = (request["blockSize"] as? Int ?? 16) == 1 ? CCMode(kCCModeCFB8) : CCMode(kCCModeCFB)
        }
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation((request["encrypt"] as? Bool ?? false) ? kCCEncrypt : kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0, 0, &cryptor)
        } }
        guard created == kCCSuccess, let cryptor else { throw ScriptHostError("AES cipher could not start") }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in
            CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, capacity, &moved)
        } }
        guard status == kCCSuccess else { throw ScriptHostError("AES cipher failed") }
        output.count = moved
        return output
    }

    /// RSA PKCS#1 v1.5 decryption with a base64 PKCS#8 private key, block by block, as Venera's Convert.decryptRsa.
    static func rsaDecrypt(_ request: [String: Any]) throws -> Data {
        let der = Data(base64Encoded: (request["key"] as? String ?? "").components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined(), options: .ignoreUnknownCharacters) ?? Data()
        let pkcs1 = (try? privateKeyInfo(der)) ?? der
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, nil) else { throw ScriptHostError("invalid RSA private key") }
        let size = SecKeyGetBlockSize(key), data = bytes(request, "data")
        var output = Data(), offset = 0
        while offset < data.count {
            let block = data.subdata(in: offset..<min(data.count, offset + size))
            guard let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, block as CFData, nil) else { throw ScriptHostError("RSA decryption failed") }
            output.append(plain as Data)
            offset += size
        }
        return output
    }

    /// The PKCS#1 key inside a PKCS#8 PrivateKeyInfo: SEQUENCE { INTEGER, SEQUENCE { algorithm }, OCTET STRING { key } }.
    private static func privateKeyInfo(_ der: Data) throws -> Data {
        let bytes = [UInt8](der), invalid = ScriptHostError("invalid RSA private key")
        var index = 0
        func header(_ tag: UInt8) throws -> Int {
            guard index < bytes.count, bytes[index] == tag else { throw invalid }
            index += 1
            guard index < bytes.count else { throw invalid }
            let first = bytes[index]; index += 1
            if first < 0x80 { return Int(first) }
            let count = Int(first & 0x7F)
            guard (1...4).contains(count), index + count <= bytes.count else { throw invalid }
            var length = 0
            for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
            return length
        }
        _ = try header(0x30)
        index += try header(0x02)
        index += try header(0x30)
        let length = try header(0x04)
        guard index + length <= bytes.count else { throw invalid }
        return Data(bytes[index..<(index + length)])
    }
}

/// Venera's `Image` API (for `modifyImage` scripts that unscramble pages): RGBA bitmaps by key.
final class MangaBitmaps: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [Int: CGContext] = [:]
    private var next = 1

    func add(_ image: CGImage) -> Int? {
        guard let context = Self.context(image.width, image.height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return keep(context)
    }
    func image(_ key: Int) -> CGImage? { lock.withLock { images[key] }?.makeImage() }
    func clear() { lock.withLock { images = [:] } }

    private func keep(_ context: CGContext) -> Int {
        lock.withLock { defer { next += 1 }; images[next] = context; return next }
    }
    private static func context(_ width: Int, _ height: Int) -> CGContext? {
        guard width > 0, height > 0, width * height <= 120_000_000 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    func handle(_ request: [String: Any]) throws -> String? {
        func int(_ name: String) -> Int { (request[name] as? NSNumber)?.intValue ?? 0 }
        let source = lock.withLock { images[int("key")] }
        switch request["function"] as? String {
        case "emptyImage":
            guard let context = Self.context(int("width"), int("height")) else { return nil }
            return MangaHost.json(keep(context))
        case "getWidth": return MangaHost.json(source?.width ?? 0)
        case "getHeight": return MangaHost.json(source?.height ?? 0)
        case "copyRange":
            guard let image = source?.makeImage(), let cropped = image.cropping(to: CGRect(x: int("x"), y: int("y"), width: int("width"), height: int("height"))),
                  let context = Self.context(cropped.width, cropped.height) else { return nil }
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
            return MangaHost.json(keep(context))
        case "copyAndRotate90":
            guard let image = source?.makeImage(), let context = Self.context(image.height, image.width) else { return nil }
            // Clockwise: the image's top edge becomes the right edge.
            context.translateBy(x: CGFloat(image.height), y: 0)
            context.rotate(by: .pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return MangaHost.json(keep(context))
        case "fillImageAt", "fillImageRangeAt":
            guard let target = source, let other = lock.withLock({ images[int("image")] })?.makeImage() else { return nil }
            var piece = other
            if request["function"] as? String == "fillImageRangeAt" {
                guard let cropped = other.cropping(to: CGRect(x: int("srcX"), y: int("srcY"), width: int("width"), height: int("height"))) else { return nil }
                piece = cropped
            }
            // Bitmap rows run top-down in Venera's coordinates; CoreGraphics' origin is the bottom-left corner.
            let y = target.height - int("y") - piece.height
            target.saveGState()
            target.setBlendMode(.copy)
            target.draw(piece, in: CGRect(x: int("x"), y: y, width: piece.width, height: piece.height))
            target.restoreGState()
            return nil
        default: return nil
        }
    }
}

/// Per-source storage behind ComicSource.loadData/saveData, settings and the signed-in account
/// (Venera keeps them in one map per source: "settings", "account", and the source's own keys).
public final class MangaSourceData: @unchecked Sendable {
    public static let shared = MangaSourceData()
    private let lock = NSLock()
    private var cache: [String: [String: Any]] = [:]
    static var folder: URL { MangaLibrary.root.appendingPathComponent("SourceData", isDirectory: true) }

    private func file(_ key: String) -> URL { Self.folder.appendingPathComponent(key + ".json") }
    private func load(_ key: String) -> [String: Any] {
        if let data = cache[key] { return data }
        let data = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file(key)))) as? [String: Any] ?? [:]
        cache[key] = data
        return data
    }
    private func save(_ key: String, _ data: [String: Any]) {
        cache[key] = data
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let encoded = try? JSONSerialization.data(withJSONObject: data) { try? encoded.write(to: file(key), options: .atomic) }
    }

    public func value(_ key: String, _ name: String) -> Any? { lock.withLock { load(key)[name] } }
    public func set(_ key: String, _ name: String, _ value: Any?) {
        lock.withLock {
            var data = load(key)
            if let value, !(value is NSNull) { data[name] = value } else { data.removeValue(forKey: name) }
            save(key, data)
        }
    }
    public func setting(_ key: String, _ name: String) -> Any? { (value(key, "settings") as? [String: Any])?[name] }
    public func setSetting(_ key: String, _ name: String, _ value: Any?) {
        lock.withLock {
            var data = load(key)
            var settings = data["settings"] as? [String: Any] ?? [:]
            settings[name] = value
            data["settings"] = settings
            save(key, data)
        }
    }
    public func isSignedIn(_ key: String) -> Bool { value(key, "account") != nil }
    public func remove(_ key: String) { lock.withLock { cache[key] = nil; try? FileManager.default.removeItem(at: file(key)) } }

    func handle(_ request: [String: Any], fallbackKey: String) throws -> String? {
        let key = request["key"] as? String ?? fallbackKey
        if let name = request["get"] as? String { return MangaHost.json(value(key, name)) }
        if let name = request["set"] as? String { set(key, name, request["value"]); return nil }
        if let name = request["delete"] as? String { set(key, name, nil); return nil }
        return nil
    }
}
