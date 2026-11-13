#if !os(tvOS)
import SwiftUI
import TVCore

struct EpisodeSkipSettingsView: View {
    let session: PlaybackSession
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var intro = ""
    @State private var outro = ""

    private var draft: EpisodeSkipSettings? {
        guard let introEnd = intro.isEmpty ? 0 : EpisodeSkipSettings.parseTime(intro),
              let outroStart = outro.isEmpty ? session.duration : EpisodeSkipSettings.parseTime(outro),
              outroStart <= session.duration else { return nil }
        return EpisodeSkipSettings(enabled: enabled, introEnd: introEnd,
                                   outroLength: outro.isEmpty ? 0 : session.duration - outroStart)
    }
    private var issue: String? {
        guard let draft else { return L10n.text("Enter a valid time such as 01:30.") }
        return draft.validationError(duration: session.duration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L10n.text("Automatically skip intro and outro"), isOn: $enabled)
                        .settingsSwitch()
                        .accessibilityIdentifier("player.skip.enabled")
                    Text(L10n.text("Times apply to this series and all its episodes. Automatic skipping is a global switch. The outro is remembered as time remaining."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("Intro ends at")) {
                    timeField(L10n.text("Intro ends at"), text: $intro, identifier: "player.skip.intro")
                    Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.position))) {
                        intro = EpisodeSkipSettings.formatTime(session.position); enabled = true
                    }.disabled(session.duration < 120)
                    .accessibilityIdentifier("player.skip.markIntro")
                }
                Section(L10n.text("Outro starts at")) {
                    timeField(L10n.text("Outro starts at"), text: $outro, identifier: "player.skip.outro")
                    Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.position))) {
                        outro = EpisodeSkipSettings.formatTime(session.position); enabled = true
                    }.disabled(session.duration < 120)
                    .accessibilityIdentifier("player.skip.markOutro")
                    Text(L10n.text("Leave a time empty to keep that segment. Format: minutes:seconds."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let issue {
                    Section { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("player.skip.validation") }
                }
                Section {
                    Button(L10n.text("Reset intro and outro"), role: .destructive) {
                        enabled = false; intro = ""; outro = ""
                    }
                }
            }
            .navigationTitle(L10n.text("Skip intro / outro"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save")) {
                        if let draft { session.applySkipSettings(draft); dismiss() }
                    }
                    .disabled(draft == nil || (enabled && issue != nil))
                    .accessibilityIdentifier("player.skip.save")
                }
            }
        }
        .onAppear {
            session.beginEditingSkip()
            let value = session.skipSettings
            enabled = value.enabled
            intro = value.introEnd > 0 ? EpisodeSkipSettings.formatTime(value.introEnd) : ""
            outro = value.outroLength > 0 ? EpisodeSkipSettings.formatTime(max(0, session.duration - value.outroLength)) : ""
        }
        .onDisappear { session.endEditingSkip() }
        #if os(macOS)
        .frame(width: 500, height: 570)
        #else
        .presentationDetents([.large])
        #endif
    }

    /// A time typed in switches automatic skipping on, as Use Current Position does. Saved with the switch at the top
    /// still off, the times skipped nothing, and nothing said why (#865).
    private func timeField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        TextField(title, text: Binding(get: { text.wrappedValue }, set: { value in
            text.wrappedValue = value
            if !value.isEmpty { enabled = true }
        }), prompt: Text("01:30"))
            .monospacedDigit()
            .accessibilityIdentifier(identifier)
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
    }
}
#endif
