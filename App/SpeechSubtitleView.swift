import SwiftUI
import TVCore
#if canImport(Speech)
import Speech
#endif

/// Turns a video's own audio into subtitles, on this device.
///
/// The list is not "every language" — it is the languages this phone has a model for, because any
/// other entry would either fail or (worse) quietly send the audio to a server. The footer says
/// that plainly.
struct SpeechSubtitleView: View {
    @Environment(Store.self) private var store
    @State private var available: [String] = []
    @State private var selected: String = ""
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
                            selected = code
                        } label: {
                            HStack {
                                Text(Locale.current.localizedString(forIdentifier: code) ?? code)
                                Spacer()
                                if code == selected {
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
                Text(L10n.text("Recognition runs entirely on this device. No audio leaves the phone."))
            }
        }
        .settingsForm(L10n.text("Speech Subtitles"))
        .task { await load() }
    }

    private func load() async {
        #if canImport(Speech)
        // Candidates come from the app's own localisations: those are the languages a viewer is
        // most likely to want, and asking the OS about a hundred others would be wasteful.
        let candidates = ArtworkLanguage.choices
        available = SpeechSubtitles.availableLanguages(from: candidates)
        if selected.isEmpty { selected = available.first ?? "" }
        #endif
        checking = false
    }
}
