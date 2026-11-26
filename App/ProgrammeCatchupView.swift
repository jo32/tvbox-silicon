import SwiftUI
import TVCore

/// The same replay entry in a playlist and in the player's channel panel. An EPG alone never enables it.
struct ProgrammeCatchupButton: View {
    let channel: Channel
    var line = 0
    let play: (Channel) -> Void
    @Environment(LiveGuide.self) private var guide: LiveGuide?
    @State private var showing = false
    var body: some View {
        if let guide, ProgramCatchup.supports(channel) {
            Button { showing = true } label: { Label(L10n.text("Replay Programmes"), systemImage: "clock.arrow.circlepath") }
                .accessibilityIdentifier("live.programme-replay")
                .sheet(isPresented: $showing) {
                    ProgrammeCatchupView(channel: channel, guide: guide, line: line) { replay in
                        showing = false
                        play(replay)
                    }
                }
        }
    }
}

struct ProgrammeCatchupView: View {
    let channel: Channel
    let guide: LiveGuide
    let play: (Channel) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var programmes: [Programme] = []
    @State private var loading = false
    @State private var expired = false
    @State private var line: Int

    init(channel: Channel, guide: LiveGuide, line: Int, play: @escaping (Channel) -> Void) {
        self.channel = channel; self.guide = guide; self.play = play
        _line = State(initialValue: line)
    }
    private var supportedLines: [Int] { channel.lines.indices.filter { ProgramCatchup.supports(channel, line: $0) } }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if case .perChannel = guide.address { calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")! }
        else { calendar.timeZone = channel.lines.indices.contains(line) ? channel.lines[line].catchup?.zone ?? .gmt : .gmt }
        return calendar
    }
    private var dates: [Date] {
        let today = calendar.startOfDay(for: Date())
        if case let .perChannel(template) = guide.address, !template.contains("{date}") { return [today] }
        let count = min(31, max(1, Int(ProgramCatchup.lookback(for: [channel]) / 86400)))
        return (0...count).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
    private var day: Date { calendar.startOfDay(for: date) }

    var body: some View {
        NavigationStack {
            List {
                if supportedLines.count > 1 {
                    Picker(L10n.text("Lines"), selection: $line) {
                        ForEach(supportedLines, id: \.self) { index in Text(L10n.text("Line %@", "\(index + 1)")).tag(index) }
                    }
                }
                Picker(L10n.text("Date"), selection: $date) {
                    ForEach(dates, id: \.self) { day in Text(day, format: .dateTime.month().day()).tag(day) }
                }
                if loading { ProgressView() }
                else if programmes.isEmpty { Text(L10n.text("No replayable programmes on this date.")).foregroundStyle(.secondary) }
                ForEach(programmes, id: \.self) { programme in
                    Button {
                        // A sheet can outlive the retention window; selection must validate again.
                        if let replay = ProgramCatchup.replay(channel, programme: programme, line: line) { play(replay) }
                        else { expired = true }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(programme.title)
                            Text(programme.start, format: .dateTime.hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .environment(\.timeZone, calendar.timeZone)
            .navigationTitle(channel.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        .onAppear {
            if !supportedLines.contains(line), let first = supportedLines.first { line = first }
            date = calendar.startOfDay(for: date)
        }
        .onChange(of: line) { _, _ in date = calendar.startOfDay(for: date) }
        .task(id: "\(day.timeIntervalSince1970):\(line)") {
            let requested = day
            loading = true; programmes = []
            let fetched = await guide.programmes(for: channel, on: requested)
            guard !Task.isCancelled, day == requested else { return }
            programmes = fetched.filter { calendar.isDate($0.start, inSameDayAs: requested)
                && ProgramCatchup.replay(channel, programme: $0, line: line) != nil }.sorted { $0.start > $1.start }
            loading = false
        }
        .alert(L10n.text("This programme is no longer available for replay."), isPresented: $expired) {
            Button(L10n.text("OK"), role: .cancel) {}
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }
}
