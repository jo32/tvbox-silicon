import Foundation

/// Shared by the SwiftUI app and core errors. Source keys are readable English.
/// Production follows Apple's per-app language selection; explicit languages are
/// useful for previews and tests and do not mutate global preferences.
public enum L10n {
    public static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja"]

    public static func text(_ key: String, _ arguments: CVarArg..., language: String? = nil) -> String {
        let bundle: Bundle
        if let language {
            let match = Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: [language]).first ?? "en"
            let selected = supportedLanguages.contains(match) ? match : "en"
            bundle = Bundle.module.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.module
        } else { bundle = Bundle.module }
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language ?? bundle.preferredLocalizations.first ?? "en"), arguments: arguments)
    }
}
