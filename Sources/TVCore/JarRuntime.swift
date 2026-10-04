import Foundation
import CryptoKit
import DexRuntime

public struct JarReport: Sendable {
    public let status: Int
    public let dexFiles: Int
    public let classes: Int
    public let nativeLibraries: Int
    public let instructions: UInt64
    public let value: Int
    public let message: String
    public var needsAndroidNativeRuntime: Bool { nativeLibraries > 0 }
    init(_ result: TVJarResult) {
        status = Int(result.status); dexFiles = Int(result.dex_count); classes = Int(result.class_count)
        nativeLibraries = Int(result.native_library_count); instructions = result.instructions; value = Int(result.integer_value)
        var buffer = result.message
        message = withUnsafeBytes(of: &buffer) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// This actor owns the experimental interpreter boundary. A successful probe
/// validates DEX execution only, not arbitrary JVM/CatVod/Android compatibility.
public actor JarRuntime {
    public init() {}
    public func inspect(_ data: Data) -> JarReport {
        let started = ContinuousClock.now
        let report = data.withUnsafeBytes { raw in
            JarReport(tv_jar_inspect(raw.bindMemory(to: UInt8.self).baseAddress, raw.count))
        }
        Diagnostics.shared.record(report.status == 0 ? .info : .error, "jar.dex", "status=\(report.status) bytes=\(data.count) duration=\(started.duration(to: .now)) detail=\(report.message)")
        return report
    }
    public func runStaticInt(_ data: Data, className: String, method: String) -> JarReport {
        let started = ContinuousClock.now
        let report = data.withUnsafeBytes { raw in
            className.withCString { className in
                method.withCString { method in
                    JarReport(tv_jar_run_static_int(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, className, method))
                }
            }
        }
        Diagnostics.shared.record(report.status == 0 ? .info : .error, "jar.dex", "status=\(report.status) bytes=\(data.count) duration=\(started.duration(to: .now)) detail=\(report.message)")
        return report
    }
    public func inspect(subscription: Subscription) async throws -> JarReport {
        do {
            guard let url = subscription.spiderURL else { throw TVError.unsupported(L10n.text("This configuration has no global spider JAR.")) }
            let (data, _) = try await HTTPClient().get(url)
            if let text = subscription.raw["spider"]?.string {
                let fields = text.components(separatedBy: ";md5;")
                if fields.count > 1 {
                    let expected = fields[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    // Match TVBox's legacy content fingerprint. Remote MD5 manifests
                    // aren't interpreted as hashes or executed.
                    if expected.count == 32 && expected.allSatisfy(\.isHexDigit) {
                        let actual = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        guard actual == expected else { throw TVError.unsupported(L10n.text("The plugin MD5 does not match the subscription. Refresh the subscription before checking again.")) }
                    }
                }
            }
            return inspect(data)
        } catch {
            Diagnostics.shared.record(.error, "jar.inspect", "Download or validation failed: \(error.localizedDescription)")
            throw error
        }
    }
}
