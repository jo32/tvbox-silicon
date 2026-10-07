import Foundation
import CommonCrypto
import CryptoKit
import Compression

/// Native AES, hashes and HMAC for scripts (`nativeCrypto` in the prelude). Pure-JavaScript
/// crypto is too slow on QuickJS for multi-megabyte payloads such as bridge relays.
/// Request: {"op": "aes", "encrypt": true, "mode": "CBC"|"ECB", "padding": true, "key", "iv", "data", "output"}
///          {"op": "hash", "alg": "md5"|"sha1"|"sha256"|"sha512", "data"}
///          {"op": "hmac", "alg": ..., "key", "data"}
///          {"op": "pow", "alg": "sha256"|"md5", "prefix", "target", "match": "prefix"|"equal", "start", "end", "limitMs"}
///          {"op": "inflate", "data", "raw": false, "output"}  zlib (or raw deflate) decompression
/// Each binary field X may be given as X (base64), XText (UTF-8) or XHex. `output` selects the
/// AES result: "base64" (default), "hex" or "text" (UTF-8). Answer: {"data"|"hex"|"text": ...}.
enum ScriptCrypto {
    /// Deflate decompression; Compression's ZLIB codec reads raw deflate, so a zlib header is skipped.
    static func inflate(_ input: Data, zlibHeader: Bool) throws -> Data {
        let source = zlibHeader && input.count > 2 ? input.dropFirst(2) : input[...]
        guard !source.isEmpty else { return Data() }
        var capacity = max(64 * 1024, source.count * 8)
        while capacity <= 256 * 1024 * 1024 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { out in
                source.withUnsafeBytes { inp in
                    compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              inp.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { throw ScriptHostError("inflate failed") }
            if written < capacity { return output.prefix(written) }
            capacity *= 4
        }
        throw ScriptHostError("inflate output too large")
    }

    static func run(_ json: String) throws -> String {
        let request = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        func bytes(_ name: String) throws -> Data {
            if let text = request[name + "Text"]?.string { return Data(text.utf8) }
            if let hex = request[name + "Hex"]?.string {
                guard let data = Data(hex: hex) else { throw ScriptHostError("crypto field \(name)Hex is not hex") }
                return data
            }
            guard let text = request[name]?.string else { return Data() }
            guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { throw ScriptHostError("crypto field \(name) is not base64") }
            return data
        }
        func flag(_ name: String, _ fallback: Bool) -> Bool { if case .bool(let value) = request[name] { value } else { fallback } }
        let hex: ([UInt8]) -> String = { $0.map { String(format: "%02x", $0) }.joined() }
        let answer: [String: String]
        switch request["op"]?.string {
        case "aes":
            let ecb = request["mode"]?.string?.uppercased() == "ECB"
            let encrypt = flag("encrypt", false)
            let result = try aes(encrypt: encrypt, ecb: ecb, padding: flag("padding", true), key: bytes("key"), iv: bytes("iv"), data: bytes("data"))
            switch request["output"]?.string {
            case "hex": answer = ["hex": hex(Array(result))]
            case "text": answer = ["text": String(decoding: result, as: UTF8.self)]
            default: answer = ["data": result.base64EncodedString()]
            }
        case "hash":
            let data = try bytes("data")
            switch request["alg"]?.string?.lowercased() {
            case "md5": answer = ["hex": hex(Array(Insecure.MD5.hash(data: data)))]
            case "sha1": answer = ["hex": hex(Array(Insecure.SHA1.hash(data: data)))]
            case "sha256": answer = ["hex": hex(Array(SHA256.hash(data: data)))]
            case "sha512": answer = ["hex": hex(Array(SHA512.hash(data: data)))]
            default: throw ScriptHostError("unsupported hash")
            }
        case "hmac":
            let key = SymmetricKey(data: try bytes("key")), data = try bytes("data")
            switch request["alg"]?.string?.lowercased() {
            case "md5": answer = ["hex": hex(Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key)))]
            case "sha1": answer = ["hex": hex(Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key)))]
            case "sha256": answer = ["hex": hex(Array(HMAC<SHA256>.authenticationCode(for: data, using: key)))]
            case "sha512": answer = ["hex": hex(Array(HMAC<SHA512>.authenticationCode(for: data, using: key)))]
            default: throw ScriptHostError("unsupported hmac")
            }
        case "pow":
            answer = ["nonce": proofOfWork(request)]
        case "inflate":
            let result = try inflate(bytes("data"), zlibHeader: !flag("raw", false))
            switch request["output"]?.string {
            case "hex": answer = ["hex": hex(Array(result))]
            case "base64": answer = ["data": result.base64EncodedString()]
            default: answer = ["text": String(decoding: result, as: UTF8.self)]
            }
        default: throw ScriptHostError("unsupported crypto operation")
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    }

    /// Anti-bot proof of work: the first nonce in [start, end] whose hex digest of `prefix + nonce`
    /// starts with (`match: "prefix"`) or equals (`"equal"`) `target`; "" when none is found in time.
    static func proofOfWork(_ request: [String: JSONValue]) -> String {
        let prefix = request["prefix"]?.string ?? ""
        let target = (request["target"]?.string ?? "").lowercased()
        let equal = request["match"]?.string == "equal"
        let md5 = request["alg"]?.string?.lowercased() == "md5"
        let start = request["start"]?.int ?? 0, end = request["end"]?.int ?? 2_100_000
        let deadline = Date().addingTimeInterval(Double(request["limitMs"]?.int ?? 20000) / 1000)
        guard !target.isEmpty, start <= end else { return "" }
        let wanted = Array(target.utf8)
        let digits = Array("0123456789abcdef".utf8)
        for nonce in start...end {
            let data = Data((prefix + String(nonce)).utf8)
            let digest: [UInt8] = md5 ? Array(Insecure.MD5.hash(data: data)) : Array(SHA256.hash(data: data))
            var matched = !equal || wanted.count == digest.count * 2
            var index = 0
            while matched && index < wanted.count {
                guard index / 2 < digest.count else { matched = false; break }
                let byte = digest[index / 2]
                matched = digits[Int(index % 2 == 0 ? byte >> 4 : byte & 15)] == wanted[index]
                index += 1
            }
            if matched { return String(nonce) }
            if nonce & 1023 == 0 && Date() > deadline { return "" }
        }
        return ""
    }

    static func aes(encrypt: Bool, ecb: Bool, padding: Bool, key: Data, iv: Data, data: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw ScriptHostError("AES key must be 16, 24 or 32 bytes") }
        guard ecb || iv.count == kCCBlockSizeAES128 else { throw ScriptHostError("AES IV must be 16 bytes") }
        var options = CCOptions(0)
        if padding { options |= CCOptions(kCCOptionPKCS7Padding) }
        if ecb { options |= CCOptions(kCCOptionECBMode) }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                keyBytes.baseAddress, key.count, ecb ? nil : ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ScriptHostError("AES \(encrypt ? "encryption" : "decryption") failed (\(status))") }
        output.count = moved
        return output
    }
}

private extension Data {
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        func value(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 65...70: c - 55; case 97...102: c - 87; default: nil }
        }
        var index = 0
        while index < digits.count {
            guard let high = value(digits[index]), let low = value(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }
}
