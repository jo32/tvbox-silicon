import Foundation

/// What a listed plugin setting (`Video.action`) is for. FTY's 我的云盘┃配置 lists its drive settings as titles:
/// LoginShow and pushCkShow open an Android dialog with a code that leads to TVBox's own page for pasting a
/// drive's cookie, quarkClean/ucClean/BdClean/aliClean drop the plugin's copy of a sign-in, and the rest open
/// Android dialogs (panSortShow). Yingxia keeps drive sign-ins under Cloud Drive Accounts and supplies them to
/// plugins, so sign-in settings lead there and clearing one signs that drive out.
public enum PluginAction: Equatable, Sendable {
    /// Opens Cloud Drive Accounts.
    case signIn
    /// Signs this drive out (`quark`, `uc`, `baidu`, `aliyun`), in Yingxia and in the plugin.
    case signOut(drive: String)
    /// Anything else: run by the plugin, which reports back.
    case run

    public init(_ action: String) {
        let name = action.lowercased()
        if name.contains("login") || name.hasPrefix("pushck") { self = .signIn; return }
        if name.hasSuffix("clean") || name.hasSuffix("clear") {
            let drives: [(prefix: String, drive: String)] = [("quark", "quark"), ("uc", "uc"), ("bd", "baidu"), ("baidu", "baidu"), ("ali", "aliyun")]
            if let match = drives.first(where: { name.hasPrefix($0.prefix) }) { self = .signOut(drive: match.drive); return }
        }
        self = .run
    }
}
