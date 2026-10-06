import Foundation
import CryptoKit

/// Local content identity shared by download artifacts and Java conversion caches.
enum PluginChecksum {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
