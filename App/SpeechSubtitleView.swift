import SwiftUI
import TVCore
#if canImport(Speech) && !os(tvOS)
import Speech
#endif

/// Turns a video's own audio into subtitles, on this device.
///
/// The list is not "every language" — it is the languages this device has a model for, because any
/// other entry would either fail or (worse) quietly send the audio to a server. The footer says
/// that plainly.
///
/// The choice is stored, not just displayed: the player reads the same key, so picking a language
/// here is what makes the item in its options menu recognise in that language.
struct SpeechSubtitleView: View {
    @AppStorage(SpeechSubtitlePreference.key) private var stored = ""
    @State private var available: [String] = []
    @State private var checking = true

    var body: some View {
        Form {
            Section {
                if checking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Checking")).foregroundStyle(.secondary)
                    }
                } else if available.isEmpty {
                    Label(L10n.text("No on-device model for this language"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(available, id: \.self) { code in
                        Button {
                            stored = code
                        } label: {
                            HStack {
                                Text(displayName(code))
                                Spacer()
                                if code == chosen {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(L10n.text("Generate Subtitles from Audio"))
            } footer: {
                // Two facts a viewer needs before trusting it: nothing leaves the device, and the
                // list is short because the phone's models are, not because languages were hidden.
                Text(L10n.text("Recognition runs entirely on this device. No audio leaves the phone. Only languages this device has a model for are listed; the player uses the one picked here."))
            }
        }
            .settingsPage()
        .settingsForm(L10n.text("Speech Subtitles"))
        .task { await load() }
    }

    /// What the player will actually use: the stored pick while the device still supports it,
    /// otherwise the first language it falls back to. Showing the fallback rather than the raw
    /// stored code keeps the check mark next to something that is really in effect.
    private var chosen: String {
        #if canImport(Speech) && !os(tvOS)
        SpeechSubtitles.preferredLanguage(stored: stored) ?? ""
        #else
        ""
        #endif
    }

    private func displayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    private func load() async {
        #if canImport(Speech) && !os(tvOS)
        // Candidates come from the app's own localisations: those are the languages a viewer is
        // most likely to want, and asking the OS about a hundred others would be wasteful.
        // Two codes can localise to the same name ("en-US" and "en_US"), and the phone's own
        // languages overlap the app's list, so the list is de-duplicated by what is on screen
        // rather than by code: one row, one check mark.
        var shown = Set<String>()
        available = SpeechSubtitles.availableLanguages(
            from: SpeechSubtitlePreference.candidates(stored: stored) + ArtworkLanguage.choices)
            .filter { shown.insert(displayName($0)).inserted }
        // Adopt the fallback on first visit, so the player and this page agree from the start.
        if stored.isEmpty, let first = available.first { stored = first }
        #endif
        checking = false
    }
}
