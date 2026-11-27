import SwiftUI
import TVCore

/// A player whose title keeps intro and outro times (`EpisodeSkipSettings`): the video player's series, or the music
/// player's audiobook (#1486), whose chapters open and close with the same jingle.
@MainActor protocol SkipTimesEditing: AnyObject {
    var skipSettings: EpisodeSkipSettings { get }
    /// Where the player is, and how long this episode or chapter runs; 0 while unknown.
    var skipPosition: Double { get }
    var skipDuration: Double { get }
    func beginEditingSkip()
    func endEditingSkip()
    func applySkipSettings(_ settings: EpisodeSkipSettings)
}

#if !os(tvOS)
struct EpisodeSkipSettingsView: View {
    let session: any SkipTimesEditing
    /// An audiobook's times, which apply to its chapters rather than a series' episodes.
    var book = false
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var intro = ""
    @State private var outro = ""
    private var video: PlaybackSession? { book ? nil : session as? PlaybackSession }
    /// The service an empty field was filled from, and what it was filled with: said under the field until changed.
    @State private var introFrom: (source: String, value: String)?
    @State private var outroFrom: (source: String, value: String)?

    private var draft: EpisodeSkipSettings? {
        guard let introEnd = intro.isEmpty ? 0 : EpisodeSkipSettings.parseTime(intro),
              let outroStart = outro.isEmpty ? session.skipDuration : EpisodeSkipSettings.parseTime(outro),
              outroStart <= session.skipDuration else { return nil }
        return EpisodeSkipSettings(enabled: enabled, introEnd: introEnd,
                                   outroLength: outro.isEmpty ? 0 : session.skipDuration - outroStart)
    }
    private var issue: String? {
        guard let draft else { return L10n.text("Enter a valid time such as 01:30.") }
        return draft.validationError(duration: session.skipDuration)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L10n.text("Automatically skip intro and outro"), isOn: $enabled)
                        .settingsSwitch()
                        .accessibilityIdentifier("player.skip.enabled")
                    // Switched on with no times, nothing is skipped: say so where it is switched on (#1405).
                    if enabled && intro.isEmpty && outro.isEmpty {
                        Text(L10n.text("Nothing is skipped until you set where the intro ends or the outro starts. Play to that place and tap Use current position."))
                            .font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("player.skip.needsTimes")
                    } else {
                        Text(book ? L10n.text("Times apply to this book and all its chapters. Automatic skipping is a global switch. The outro is remembered as time remaining.")
                             : L10n.text("Times apply to this series and all its episodes. Automatic skipping is a global switch. The outro is remembered as time remaining."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let video {
                    Section {
                        // At once, not on Save: the lookup's answer shows here while the sheet is open.
                        Toggle(L10n.text("Look Up Intro and Outro Times Online"), isOn: Binding(
                            get: { video.looksUpSkipsOnline }, set: { video.looksUpSkipsOnline = $0 }))
                            .settingsSwitch()
                            .accessibilityIdentifier("player.skip.online")
                        OnlineSkipResult(status: video.onlineSkipStatus)
                    } footer: {
                        Text(L10n.text("Looks up a TV episode's or movie's intro and outro times in TheIntroDB, IntroDB and TheOtherDB, which then learn what you play. Their times show a Skip button; they don't skip by themselves."))
                    }
                }
                Section(L10n.text("Intro ends at")) {
                    timeField(L10n.text("Intro ends at"), text: $intro, identifier: "player.skip.intro")
                    Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.skipPosition))) {
                        intro = EpisodeSkipSettings.formatTime(session.skipPosition); enabled = true
                    }.disabled(session.skipDuration <= 0)
                    .accessibilityIdentifier("player.skip.markIntro")
                    if let introFrom, introFrom.value == intro { foundNote(introFrom.source) }
                }
                Section(L10n.text("Outro starts at")) {
                    timeField(L10n.text("Outro starts at"), text: $outro, identifier: "player.skip.outro")
                    Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.skipPosition))) {
                        outro = EpisodeSkipSettings.formatTime(session.skipPosition); enabled = true
                    }.disabled(session.skipDuration <= 0)
                    .accessibilityIdentifier("player.skip.markOutro")
                    if let outroFrom, outroFrom.value == outro { foundNote(outroFrom.source) }
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
            video?.lookUpSkipsOnlineNow()
            intro = value.introEnd > 0 ? EpisodeSkipSettings.formatTime(value.introEnd) : ""
            outro = value.outroLength > 0 ? EpisodeSkipSettings.formatTime(max(0, session.skipDuration - value.outroLength)) : ""
            fillFound()
        }
        .onChange(of: video?.onlineSkipStatus) { fillFound() }
        .onDisappear { session.endEditingSkip() }
        #if os(macOS)
        .frame(width: 500, height: 570)
        #else
        .presentationDetents([.large])
        #endif
    }

    /// Online times fill a field the viewer left empty (#2653): an intro that starts the episode, an outro that ends
    /// it, the only kinds the viewer's own times hold. They stay editable, and are the viewer's own once saved.
    private func fillFound() {
        guard case .found(let found)? = video?.onlineSkipStatus else { return }
        if intro.isEmpty, let source = found.introSource,
           let skip = found.skips.first(where: { $0.kind == .intro && $0.start < 1 }) {
            intro = EpisodeSkipSettings.formatTime(skip.end); introFrom = (source, intro)
        }
        if outro.isEmpty, let source = found.outroSource, session.skipDuration > 0,
           let skip = found.skips.first(where: { $0.kind == .outro && $0.end > session.skipDuration - 1 }) {
            outro = EpisodeSkipSettings.formatTime(skip.start); outroFrom = (source, outro)
        }
    }

    private func foundNote(_ source: String) -> some View {
        Text(L10n.text("Found online in %@. You can change it.", source)).font(.footnote).foregroundStyle(.secondary)
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

/// What the online lookup found for the playing episode (#2653), under its switch in the sheet.
private struct OnlineSkipResult: View {
    let status: PlaybackSession.OnlineSkipStatus

    var body: some View {
        switch status {
        case .off: EmptyView()
        case .waiting, .looking:
            HStack(spacing: 8) { ProgressView(); Text(L10n.text("Searching…")).foregroundStyle(.secondary) }
        case .unmatched:
            Text(L10n.text("This video isn't matched to a TMDB title, so there is nothing to look up."))
                .font(.footnote).foregroundStyle(.secondary)
        case .found(let found) where found.skips.isEmpty:
            Text(L10n.text("No intro or outro times found for this episode.")).font(.footnote).foregroundStyle(.secondary)
        case .found(let found):
            ForEach(found.skips, id: \.self) { skip in
                LabeledContent(skip.kind == .intro ? L10n.text("Intro") : L10n.text("Outro"),
                               value: EpisodeSkipSettings.formatTime(skip.start) + " – " + EpisodeSkipSettings.formatTime(skip.end)
                                + ((skip.kind == .intro ? found.introSource : found.outroSource).map { " · " + $0 } ?? ""))
                    .monospacedDigit()
            }
        }
    }
}

/// Skip Intro / Outro in a player's settings menu, with what it skips for this title beneath (#1488): where people look
/// for a player setting, on the iPhone's video page too, rather than behind the episode menu's More button.
struct SkipTimesMenuButton: View {
    let session: any SkipTimesEditing
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(L10n.text("Skip intro / outro"), systemImage: "arrow.right.to.line")
            Text(session.skipSettings.summary)
        }
        .accessibilityIdentifier("player.skip")
    }
}
#endif

#if os(tvOS)
/// Apple TV's transport-bar menu for a title's intro and outro (#808, #1284). No keyboard for a time here: the intro
/// ends, or the outro starts, where the picture or the sound is now. Its title says what is skipped, as Quality does.
enum SkipTimesMenu {
    /// `online`: the switch for online intro and outro times, for a video (#2653); nil for an audiobook.
    static func make(_ skipping: EpisodeSkipSettings, set: @escaping @MainActor (EpisodeSkipSettings) -> Void,
                     mark: @escaping @MainActor (_ intro: Bool) -> Void,
                     online: Bool? = nil, setOnline: @escaping @MainActor (Bool) -> Void = { _ in }) -> UIMenu {
        var options: [UIMenuElement] = [
            UIAction(title: L10n.text("Automatically skip intro and outro"), state: skipping.enabled ? .on : .off) { _ in
                var value = skipping; value.enabled.toggle(); set(value)
            },
            UIAction(title: L10n.text("Intro Ends Here"),
                     subtitle: skipping.introEnd > 0 ? EpisodeSkipSettings.formatTime(skipping.introEnd) : L10n.text("Not set")) { _ in mark(true) },
            UIAction(title: L10n.text("Outro Starts Here"),
                     subtitle: skipping.outroLength > 0 ? L10n.text("%@ before the end", EpisodeSkipSettings.formatTime(skipping.outroLength))
                        : L10n.text("Not set")) { _ in mark(false) },
        ]
        if let online {
            options.insert(UIAction(title: L10n.text("Look Up Intro and Outro Times Online"), state: online ? .on : .off) { _ in
                setOnline(!online)
            }, at: 1)
        }
        if skipping.hasTimes {
            options.append(UIAction(title: L10n.text("Clear Intro and Outro"), image: UIImage(systemName: "xmark")) { _ in
                set(EpisodeSkipSettings(enabled: skipping.enabled))
            })
        }
        // Not forward.end: beside Next Episode's forward.end.fill it read as a second Next button.
        return UIMenu(title: L10n.text("Skip intro / outro") + " · " + skipping.summary, image: UIImage(systemName: "arrow.right.to.line"),
                      children: options)
    }
}
#endif
