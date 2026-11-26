import SwiftUI
import TVCore

/// The days and ended programs a channel can replay (#2386), shared by the replay sheet, the Apple TV page and the
/// Apple TV player's strip. A program guide alone never offers it: the playlist must declare a catchup template.
@MainActor @Observable final class ProgrammeCatchupModel {
    let channel: Channel
    let guide: LiveGuide
    var line: Int
    var day: Date
    private(set) var programmes: [Programme] = []
    private(set) var loading = false
    /// The picked program left the provider's replay window while the list was open.
    private(set) var expired = false

    init(channel: Channel, guide: LiveGuide, line: Int) {
        self.channel = channel; self.guide = guide
        let lines = channel.lines.indices.filter { ProgramCatchup.supports(channel, line: $0) }
        self.line = lines.contains(line) ? line : lines.first ?? 0
        day = Date()
        day = calendar.startOfDay(for: day)
    }

    var supportedLines: [Int] { channel.lines.indices.filter { ProgramCatchup.supports(channel, line: $0) } }

    /// A DIYP guide answers by its China date; XMLTV times are absolute, so its days are the viewer's own.
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if case .perChannel = guide.address, let china = TimeZone(identifier: "Asia/Shanghai") { calendar.timeZone = china }
        return calendar
    }

    /// Today, then each day back as far as the playlist keeps (a guide address without `{date}` has today only).
    var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        if case let .perChannel(template) = guide.address, !template.contains("{date}") { return [today] }
        let count = min(31, max(1, Int(ProgramCatchup.lookback(for: [channel]) / 86400)))
        return (0...count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    func title(of day: Date) -> String {
        if calendar.isDate(day, inSameDayAs: Date()) { return L10n.text("Today") }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month().day()
        style.timeZone = calendar.timeZone
        return day.formatted(style)
    }

    /// Changes when the list needs loading again.
    var request: String { "\(day.timeIntervalSince1970):\(line)" }

    func load() async {
        let requested = day, line = line
        loading = true; programmes = []; expired = false
        let fetched = await guide.programmes(for: channel, on: requested)
        guard !Task.isCancelled, day == requested, self.line == line else { return }
        programmes = fetched.filter { calendar.isDate($0.start, inSameDayAs: requested)
            && ProgramCatchup.replay(channel, programme: $0, line: line) != nil }.sorted { $0.start > $1.start }
        loading = false
    }

    /// The program as a channel to play, checked again now: the list can outlive the replay window.
    func replay(_ programme: Programme) -> Channel? {
        let replay = ProgramCatchup.replay(channel, programme: programme, line: line)
        expired = replay == nil
        return replay
    }
}

/// The replay entry of a channel: a sheet on iPhone, iPad and Mac, a page on Apple TV (a sheet or alert on a pushed
/// Apple TV page never finishes presenting on tvOS 27).
struct ProgrammeCatchupButton: View {
    let channel: Channel
    var line = 0
    let play: (Channel) -> Void
    @Environment(LiveGuide.self) private var guide: LiveGuide?
    #if !os(tvOS)
    @State private var showing = false
    #endif

    var body: some View {
        if let guide, ProgramCatchup.supports(channel) {
            #if os(tvOS)
            RouteLink { ProgrammeCatchupPage(model: ProgrammeCatchupModel(channel: channel, guide: guide, line: line), play: play) } label: { label }
            #else
            Button { showing = true } label: { label }
                .sheet(isPresented: $showing) {
                    ProgrammeCatchupSheet(model: ProgrammeCatchupModel(channel: channel, guide: guide, line: line)) { replay in
                        showing = false
                        play(replay)
                    }
                }
            #endif
        }
    }

    private var label: some View {
        Label(L10n.text("Replay Programs"), systemImage: "clock.arrow.circlepath").accessibilityIdentifier("live.programme-replay")
    }
}

#if os(tvOS)
/// Apple TV: the channel's replayable programs as rows, with the day (and line) on pages of their own.
struct ProgrammeCatchupPage: View {
    @State var model: ProgrammeCatchupModel
    let play: (Channel) -> Void

    var body: some View {
        TVSettingsSubpage(symbol: "clock.arrow.circlepath", title: model.channel.name, subtitle: L10n.text("Replay Programs")) {
            TVSettingsSection {
                RouteLink { ProgrammeCatchupChoices(title: L10n.text("Date"), options: model.days, label: model.title(of:),
                                                    selection: Binding(get: { model.day }, set: { model.day = $0 })) } label: {
                    TVSettingsRowLabel(title: L10n.text("Date"), value: model.title(of: model.day), chevron: true)
                }
                .glassRow()
                if model.supportedLines.count > 1 {
                    RouteLink { ProgrammeCatchupChoices(title: L10n.text("Lines"), options: model.supportedLines, label: { L10n.text("Line %@", "\($0 + 1)") },
                                                        selection: Binding(get: { model.line }, set: { model.line = $0 })) } label: {
                        TVSettingsRowLabel(title: L10n.text("Lines"), value: L10n.text("Line %@", "\(model.line + 1)"), chevron: true)
                    }
                    .glassRow()
                }
            }
            TVSettingsSection(title: model.title(of: model.day), footer: model.expired ? L10n.text("This program can no longer be replayed.") : nil) {
                if model.loading {
                    TVSettingsRowLabel(title: L10n.text("Loading…"), busy: true)
                } else if model.programmes.isEmpty {
                    TVSettingsRowLabel(title: L10n.text("No programs to replay on this date."))
                }
                ForEach(model.programmes, id: \.self) { programme in
                    Button { if let replay = model.replay(programme) { play(replay) } } label: {
                        TVSettingsRowLabel(title: programme.title, value: programme.start.formatted(date: .omitted, time: .shortened))
                    }
                    .glassRow()
                    .accessibilityIdentifier("live.programme-replay.item")
                }
            }
        }
        .task(id: model.request) { await model.load() }
    }
}

/// One choice of several, as a page of rows; picking one goes back.
private struct ProgrammeCatchupChoices<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let label: (Option) -> String
    @Binding var selection: Option
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TVSettingsSubpage(symbol: "clock.arrow.circlepath", title: title) {
            TVSettingsSection {
                ForEach(options, id: \.self) { option in
                    Button { selection = option; dismiss() } label: {
                        TVSettingsRowLabel(title: label(option)) {
                            if option == selection { Image(systemName: "checkmark").font(.system(size: 28, weight: .semibold)) }
                        }
                    }
                    .glassRow()
                }
            }
        }
    }
}
#else
/// iPhone, iPad and Mac: the day (and line) to replay, then its programs.
struct ProgrammeCatchupSheet: View {
    @State var model: ProgrammeCatchupModel
    let play: (Channel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Picker(L10n.text("Date"), selection: $model.day) {
                        ForEach(model.days, id: \.self) { day in Text(model.title(of: day)).tag(day) }
                    }
                    if model.supportedLines.count > 1 {
                        Picker(L10n.text("Lines"), selection: $model.line) {
                            ForEach(model.supportedLines, id: \.self) { index in Text(L10n.text("Line %@", "\(index + 1)")).tag(index) }
                        }
                    }
                }
                Section {
                    if model.loading { ProgressView().frame(maxWidth: .infinity) }
                    else if model.programmes.isEmpty { Text(L10n.text("No programs to replay on this date.")).foregroundStyle(.secondary) }
                    ForEach(model.programmes, id: \.self) { programme in
                        Button { if let replay = model.replay(programme) { play(replay) } } label: {
                            HStack {
                                Text(programme.title).lineLimit(2)
                                Spacer(minLength: 12)
                                Text(programme.start, format: .dateTime.hour().minute()).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live.programme-replay.item")
                    }
                } footer: {
                    if model.expired { Text(L10n.text("This program can no longer be replayed.")) }
                }
            }
            .navigationTitle(model.channel.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        .task(id: model.request) { await model.load() }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}
#endif
