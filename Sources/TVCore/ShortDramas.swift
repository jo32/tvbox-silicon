import Foundation

/// Built-in short-drama sources beside Hongguo, adapted from jackotom/hongguo-drama (see
/// `ScriptAssets/sites/hongguo/NOTICE.txt`): Xifan's public app API and Hema's website. Each lists only
/// the episodes its service gives away.
public enum ShortDramas {
    public static let xifanKey = "builtin.xifan"
    public static let hemaKey = "builtin.hema"
    static let keys: Set<String> = [xifanKey, hemaKey]

    static func configuration(name: String) -> JSONValue {
        func named(_ text: String) -> JSONValue { .string(L10n.text(text).replacingOccurrences(of: "%@", with: name)) }
        return .object([
            "name": .string(name),
            "episode": .string(L10n.text("Episode %@")),
            "episodes": .string(L10n.text("%@ Episodes")),
            "free": .string(L10n.text("%@ of %@ episodes free")),
            "all": .string(L10n.text("All")),
            "unavailable": named("%@ could not be reached. Try again later."),
            "changed": named("%@ returned incomplete data. Please refresh and try again."),
            "locked": named("This episode isn't free on %@.")
        ])
    }
}

extension Site {
    public static let xifan = shortDrama(key: ShortDramas.xifanKey, name: L10n.text("Xifan"), api: "csp_YingxiaXifan")
    public static let hema = shortDrama(key: ShortDramas.hemaKey, name: L10n.text("Hema"), api: "csp_YingxiaHema")
    private static func shortDrama(key: String, name: String, api: String) -> Site {
        let raw: [String: JSONValue] = ["key": .string(key), "name": .string(name), "type": .number(3), "api": .string(api),
                                       "searchable": .number(1), "quickSearch": .number(1)]
        return Site(key: key, name: name, type: 3, api: api, raw: raw)
    }
}
