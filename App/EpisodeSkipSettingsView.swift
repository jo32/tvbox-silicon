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
    /// Each segment's start and end as typed: an empty intro start is the video's start, an empty outro end its end.
    @State private var introStart = ""
    @State private var intro = ""
    @State private var outro = ""
    @State private var outroEnd = ""
    /// The outro's "Starts at" counts back from the end: the stored value is already a distance from the end, so
    /// showing it that way holds for every episode, however long (#2673).
    @State private var outroFromEnd = false
    private var video: PlaybackSession? { book ? nil : session as? PlaybackSession }
    /// The service a segment was filled from online (#2653), and what it was filled with: said under the segment
    /// until either time is changed.
    @State private var introFrom: Found?
    @State private var outroFrom: Found?
    private struct Found: Equatable { var source: String, start: String, end: String }

    private var draft: EpisodeSkipSettings? {
        let length = session.skipDuration
        guard let introEnd = intro.isEmpty ? 0 : EpisodeSkipSettings.parseTime(intro),
              let introBegin = introStart.isEmpty ? 0 : EpisodeSkipSettings.parseTime(introStart),
              let outroBegin = outro.isEmpty ? length : EpisodeSkipSettings.parseTime(outro),
              let outroFinish = outroEnd.isEmpty ? length : EpisodeSkipSettings.parseTime(outroEnd),
              outroBegin <= length, outroFinish <= length else { return nil }
        return EpisodeSkipSettings(enabled: enabled, introEnd: introEnd,
                                   outroLength: outro.isEmpty ? 0 : (outroFromEnd ? outroBegin : length - outroBegin),
                                   introStart: introEnd > 0 ? introBegin : 0,
                                   outroTail: outro.isEmpty ? 0 : length - outroFinish)
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
                // Online times go into the fields below, not a list of their own: one set of times (#2653).
                if let video {
                    Section {
                        // At once, not on Save: what it finds fills the fields while the sheet is open.
                        Toggle(L10n.text("Look Up Intro and Outro Times Online"), isOn: Binding(
                            get: { video.looksUpSkipsOnline }, set: { video.looksUpSkipsOnline = $0 }))
                            .settingsSwitch()
                            .accessibilityIdentifier("player.skip.online")
                        OnlineSkipStatusRow(status: video.onlineSkipStatus)
                    } footer: {
                        Text(L10n.text("Looks up this episode's intro and outro in TheIntroDB, IntroDB and TheOtherDB, which then learn what you play. Times found fill the empty fields below; until you save them they only offer Skip."))
                    }
                }
                Section(L10n.text("Intro")) {
                    timeField(L10n.text("Starts at"), text: $introStart, prompt: "00:00", identifier: "player.skip.introStart")
                    timeField(L10n.text("Ends at"), text: $intro, prompt: "01:30", identifier: "player.skip.intro")
                    Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.skipPosition))) {
                        intro = EpisodeSkipSettings.formatTime(session.skipPosition); enabled = true
                    }.disabled(session.skipDuration <= 0)
                    .accessibilityIdentifier("player.skip.markIntro")
                    if let introFrom, introFrom == Found(source: introFrom.source, start: introStart, end: intro) { foundNote(introFrom.source) }
                }
                Section(L10n.text("Outro")) {
                    // From the end, the typed time is the outro's length itself; flipping the switch keeps the
                    // same outro start by counting the other way from this episode's length.
                    Toggle(L10n.text("Count back from the end"), isOn: Binding(
                        get: { outroFromEnd },
                        set: { value in
                            let length = session.skipDuration
                            if let typed = EpisodeSkipSettings.parseTime(outro), length > 0 {
                                outro = EpisodeSkipSettings.formatTime(max(0, length - typed))
                            }
                            outroFromEnd = value
                        }))
                        .accessibilityIdentifier("player.skip.outroFromEnd")
                    timeField(L10n.text("Starts at"), text: $outro, prompt: outroFromEnd ? "02:00" : "21:30", identifier: "player.skip.outro")
                    timeField(L10n.text("Ends at"), text: $outroEnd, prompt: L10n.text("End"), identifier: "player.skip.outroEnd")
                    Button(L10n.text("Use current position (%@)", EpisodeSkipSettings.formatTime(session.skipPosition))) {
                        outro = EpisodeSkipSettings.formatTime(session.skipPosition); outroFromEnd = false; enabled = true
                    }.disabled(session.skipDuration <= 0)
                    .accessibilityIdentifier("player.skip.markOutro")
                    if let outroFrom, outroFrom == Found(source: outroFrom.source, start: outro, end: outroEnd) { foundNote(outroFrom.source) }
                    Text(L10n.text("With no start, the intro starts the video; with no end, the outro ends it. Leave a segment's times empty to keep it. Format: minutes:seconds."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let issue {
                    Section { Text(issue).foregroundStyle(.orange).accessibilityIdentifier("player.skip.validation") }
                }
                Section {
                    Button(L10n.text("Reset intro and outro"), role: .destructive) {
                        enabled = false; introStart = ""; intro = ""; outro = ""; outroEnd = ""; outroFromEnd = false
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
            let value = session.skipSettings, length = session.skipDuration
            enabled = value.enabled
            introStart = value.introEnd > 0 && value.introStart > 0 ? EpisodeSkipSettings.formatTime(value.introStart) : ""
            intro = value.introEnd > 0 ? EpisodeSkipSettings.formatTime(value.introEnd) : ""
            outro = value.outroLength > 0 ? EpisodeSkipSettings.formatTime(value.outroLength) : ""
            outroFromEnd = value.outroLength > 0
            outroEnd = value.outroLength > 0 && value.outroTail > 0 ? EpisodeSkipSettings.formatTime(max(0, length - value.outroTail)) : ""
            video?.lookUpSkipsOnlineNow()
            fillFound()
        }
        .onChange(of: video?.onlineSkipStatus) { fillFound() }
        .onDisappear { session.endEditingSkip() }
        #if os(macOS)
        .frame(width: 500, height: 640)
        #else
        .presentationDetents([.large])
        #endif
    }

    /// Online times fill a segment the viewer left empty (#2653). They stay editable, and are the viewer's own, for
    /// every episode, once saved; times the viewer set are never replaced.
    private func fillFound() {
        guard case .found(let found)? = video?.onlineSkipStatus else { return }
        let length = session.skipDuration
        if intro.isEmpty, introStart.isEmpty, let source = found.introSource,
           let skip = found.skips.first(where: { $0.kind == .intro }) {
            introStart = skip.start >= 1 ? EpisodeSkipSettings.formatTime(skip.start) : ""
            intro = EpisodeSkipSettings.formatTime(skip.end)
            introFrom = Found(source: source, start: introStart, end: intro)
        }
        if outro.isEmpty, outroEnd.isEmpty, length > 0, let source = found.outroSource,
           let skip = found.skips.first(where: { $0.kind == .outro }) {
            outro = EpisodeSkipSettings.formatTime(skip.start)
            outroFromEnd = false
            outroEnd = skip.end < length - 1 ? EpisodeSkipSettings.formatTime(skip.end) : ""
            outroFrom = Found(source: source, start: outro, end: outroEnd)
        }
    }

    private func foundNote(_ source: String) -> some View {
        Text(L10n.text("Found online in %@. You can change it.", source)).font(.footnote).foregroundStyle(.secondary)
    }

    /// A time typed in switches automatic skipping on, as Use Current Position does. Saved with the switch at the top
    /// still off, the times skipped nothing, and nothing said why (#865).
    private func timeField(_ title: String, text: Binding<String>, prompt: String, identifier: String) -> some View {
        LabeledContent(title) {
            // No title here: LabeledContent already shows `title`. Repeating it made a second,
            // clipped label on the macOS panel edge (#2747); the prompt is the field's placeholder.
            TextField("", text: Binding(get: { text.wrappedValue }, set: { value in
                text.wrappedValue = value
                if !value.isEmpty { enabled = true }
            }), prompt: Text(prompt))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
        }
    }
}

/// Where the online lookup for the playing episode stands (#2653), under its switch; what it found is in the fields.
private struct OnlineSkipStatusRow: View {
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
            let sources = [found.introSource, found.outroSource].compactMap { $0 }
            Text(L10n.text("Found in %@.", sources.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")))
                .font(.footnote).foregroundStyle(.secondary)
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
