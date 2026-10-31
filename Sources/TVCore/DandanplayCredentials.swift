import CryptoKit
import Foundation

/// Injected by the app build, never checked into source control.
public struct DandanplayCredentials: Sendable, Codable {
    public let appId: String
    private let appSecret: String

    public init(appId: String, appSecret: String) {
        self.appId = appId; self.appSecret = appSecret
    }

    public static var bundled: Self? {
        guard let url = Bundle.main.url(forResource: "DandanplayCredentials", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListDecoder().decode(Self.self, from: data),
              !value.appId.isEmpty, !value.appSecret.isEmpty else { return nil }
        return value
    }

    static func isOfficial(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "api.dandanplay.net" && (url.port == nil || url.port == 443)
    }

    func sign(_ request: inout URLRequest, timestamp: Int64 = Int64(Date().timeIntervalSince1970)) {
        guard let url = request.url, Self.isOfficial(url) else { return }
        let timestamp = String(timestamp)
        let digest = SHA256.hash(data: Data((appId + timestamp + url.path + appSecret).utf8))
        request.setValue(appId, forHTTPHeaderField: "X-AppId")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(Data(digest).base64EncodedString(), forHTTPHeaderField: "X-Signature")
    }
}

/// Comments redirect to Dandanplay's CDN using a server-issued signed URL.
/// Follow only its HTTPS hosts, without forwarding the API authentication headers.
final class DandanplayRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = DandanplayRedirectPolicy()
    static func sanitized(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.hasSuffix(".dandanplay.net") else { return nil }
        var safe = request
        for header in ["X-AppId", "X-Timestamp", "X-Signature", "X-AppSecret", "Authorization"] {
            safe.setValue(nil, forHTTPHeaderField: header)
        }
        return safe
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(Self.sanitized(request))
    }
}
