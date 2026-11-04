import Foundation

/// Where the viewer's chosen speech-recognition language lives.
///
/// Kept apart from `SpeechSubtitles` because that type only exists where the platform has an
/// on-device recogniser: the settings page that stores the choice still has to compile — and still
/// has to remember the choice — on a platform that cannot recognise anything itself.
public enum SpeechSubtitlePreference {

    /// The key the choice is stored under, read by both the settings page and the player.
    public static let key = "speechSubtitles.preferredLanguage"

    /// Languages worth asking the OS about, best first: the viewer's pick, then the phone's own
    /// languages, then the two this app is most used in.
    ///
    /// Without the duplicate pass the list reads as a bug: `zh-Hans-CN` and `zh-Hans` both localise
    /// to the same name, and a page that shows one language twice — with two check marks — looks
    /// broken even though the codes differ.
    public static func candidates(stored: String) -> [String] {
        var seen = Set<String>()
        return ((stored.isEmpty ? [] : [stored]) + Locale.preferredLanguages + ["zh-Hans-CN", "zh-CN", "en-US"])
            .filter { seen.insert($0).inserted }
    }
}
