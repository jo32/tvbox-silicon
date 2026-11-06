import Foundation

/// The drive's own app for a sign-in code on this iPhone or iPad, which can't scan its own screen. For Quark and UC the
/// app opens the code's page itself, where the sign-in is confirmed, in the format Alibaba's own "open in app" script
/// builds (`<scheme>://www.uc.cn/<app key>?action=open_url&url=…`, see share pages on pan.quark.cn). Baidu Netdisk's
/// app only opens (`bdnetdisk://n/action.EXTERNAL_ACTIVITY`, as pan.baidu.com's share pages call it): the code is then
/// scanned there from Photos. Aliyun Drive, 115, Tianyi and Guangya publish no way in, so their codes are saved or scanned.
public struct DriveAppLink: Sendable, Equatable {
    /// The app, as the viewer knows it ("Quark", "UC Browser", "Baidu Netdisk").
    public let app: String
    /// Tried in order until one opens: the main app first, then an older or companion one.
    public let urls: [URL]
    /// True when the app opens the code's page; false when it only opens and the code is scanned from Photos.
    public let opensPage: Bool

    /// For a plugin's drive (`quark`, `uc`, `baidu`) or a CatPawOpen bundle's provider (`ucCookie`, `ucToken`), with
    /// the code's text (an address); nil when the drive's app can't be opened or a page needs a code it hasn't got.
    public static func target(drive: String, page: String?, pad: Bool) -> DriveAppLink? {
        let page = page.flatMap { $0.hasPrefix("http") ? $0 : nil }
        switch drive {
        case "quark":
            guard let page else { return nil }
            return DriveAppLink(app: L10n.text("Quark"), urls: [
                openURL(scheme: "qklink", key: pad ? "e7d506280d7f0140e2ee4ba5b030d82d" : "656bdcddd4758b39206a8181c91a7d14", page: page),
                // The Quark Cloud Drive app signs in to the same accounts.
                openURL(scheme: "qkcloudlink", key: "ca7b1fad21e741b3a4aa4284ce58d686", page: page),
            ].compactMap { $0 }, opensPage: true)
        case "uc", "ucCookie", "ucToken":
            guard let page else { return nil }
            return DriveAppLink(app: L10n.text("UC Browser"), urls: [
                openURL(scheme: "uclink", key: pad ? "3898f2889dfc4651a3726ffbc5d1e198" : "f11f7cb5d16fa0969d670c1eccc6053d", page: page),
                URL(string: "ucbrowser://" + page),
            ].compactMap { $0 }, opensPage: true)
        case "baidu":
            return DriveAppLink(app: L10n.text("Baidu Netdisk"), urls: [
                URL(string: "bdnetdisk://n/action.EXTERNAL_ACTIVITY?m_n_v=10.0.20"), URL(string: "baiduyun://"),
            ].compactMap { $0 }, opensPage: false)
        default:
            return nil
        }
    }

    /// The app for a page a plugin opens, when the page only works there: Bilibili's sign-in confirmation
    /// (`account.bilibili.com/h5/account-h5/auth/scan-web`, what its app shows after scanning a code) needs the
    /// app's signed-in account, so it opens in the app's own browser (`bilibili://browser?url=`).
    public static func app(opening page: URL) -> DriveAppLink? {
        guard page.host?.lowercased() == "account.bilibili.com", page.path.contains("/auth/scan-web") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        guard let encoded = page.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "bilibili://browser?url=" + encoded) else { return nil }
        return DriveAppLink(app: L10n.text("Bilibili"), urls: [url], opensPage: true)
    }

    /// `encodeURIComponent`, which the apps decode the page with.
    static func openURL(scheme: String, key: String, page: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))
        guard let encoded = page.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "\(scheme)://www.uc.cn/\(key)?src_ch=yingxia&action=open_url&url=\(encoded)")
    }
}
