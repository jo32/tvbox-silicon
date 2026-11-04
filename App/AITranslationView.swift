import SwiftUI
import TVCore

/// Configures an OpenAI-compatible subtitle translation service.
///
/// The page states the trade against the device's own Translation, because that is the choice being
/// made: the system translator is free, offline, and limited to the pairs iOS carries; a service
/// covers any pair for an API key and a network round trip. Leaving every field empty keeps the
/// system translator — an unconfigured app behaves exactly as before.
struct AITranslationView: View {
    @Environment(Store.self) private var store
    @State private var draft = SubtitleTranslator.Configuration(baseURL: "", model: "", apiKey: "", targetLanguage: "")
    @State private var testing = false
    @State private var result: String?

    var body: some View {
        Form {
            Section {
                Picker(L10n.text("Service"), selection: providerBinding) {
                    Text(L10n.text("None")).tag("")
                    ForEach(SubtitleTranslator.Provider.known) { provider in
                        Text(provider.name).tag(provider.name)
                    }
                }
                // `textInputAutocapitalization` is iOS/tvOS only; the Mac's text field has no such modifier.
                TextField(L10n.text("Complete Address"), text: $draft.baseURL)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                TextField(L10n.text("Model"), text: $draft.model)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                SecureField(L10n.text("API Key"), text: $draft.apiKey)
            } header: {
                Text(L10n.text("Translate Subtitles"))
            } footer: {
                Text(L10n.text("Leave every field empty to keep the device's own translation, which is free and offline but limited to the language pairs the system carries. A service covers any pair, at the cost of an API key and a network request per batch."))
            }

            Section {
                Picker(L10n.text("Translate Into"), selection: $draft.targetLanguage) {
                    ForEach(ArtworkLanguage.choices, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                    }
                }
                TextField(L10n.text("Custom Translation Rules"), text: $draft.extraInstructions, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text(L10n.text("Language"))
            } footer: {
                Text(L10n.text("Rules are added to the built-in ones, which already ask the model to keep tone, register, humour and implied subjects using nearby subtitle context."))
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        if testing { ProgressView().controlSize(.small) }
                        Text(testing ? L10n.text("Testing") : L10n.text("Test Translation Service"))
                    }
                }
                .disabled(testing || !draft.isComplete)
                if let result {
                    Text(result).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.text("Sends one test line, to confirm the address, model and key work together."))
            }
        }
            .settingsPage()
        .settingsForm(L10n.text("AI Translation"))
        .task {
            draft = store.aiTranslation
            if draft.targetLanguage.isEmpty {
                draft.targetLanguage = L10n.resolvedLanguage()
            }
        }
        .onChange(of: draft) { _, new in
            store.aiTranslation = new
            store.saveVault()
            // Re-install immediately: the repackager reads the translator when it prepares a file,
            // so a change must take effect without a relaunch.
            SubtitleTranslationSetup.installAI(configuration: new.isComplete ? new : nil)
        }
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: {
                SubtitleTranslator.Provider.known.first { $0.baseURL == draft.baseURL }?.name ?? ""
            },
            set: { name in
                guard let provider = SubtitleTranslator.Provider.known.first(where: { $0.name == name }) else {
                    draft.baseURL = ""; draft.model = ""; return
                }
                draft.baseURL = provider.baseURL
                if draft.model.isEmpty { draft.model = provider.model }
            }
        )
    }

    private func test() async {
        testing = true; result = nil
        defer { testing = false }
        let track = SubtitleTrack(name: "test", language: "en", cues: [
            SubtitleTrack.Cue(start: 0, end: 1_000_000, text: "Hello, this is a subtitle translation test."),
        ])
        do {
            let translated = try await SubtitleTranslator().translate(track, configuration: draft)
            result = L10n.text("Test succeeded: %@", translated.cues.first?.text ?? "")
        } catch {
            result = L10n.text("Test failed: %@", "\(error)")
        }
    }
}
