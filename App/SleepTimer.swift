import AVFoundation
import SwiftUI
import TVCore

/// Stops playback after a while, or when the song or episode playing ends, for people who listen as they fall
/// asleep (#1157, #1198). One timer for the whole app: music and the video player both obey it. When the time
/// is up the sound fades out over a few seconds and playback pauses where it is, to continue in the morning.
@MainActor final class SleepTimer: ObservableObject {
    enum Mode: Equatable {
        case off
        /// Pauses at this moment.
        case at(Date)
        /// Pauses when the song or episode playing ends.
        case endOfItem
    }

    static let shared = SleepTimer()
    /// Posted when the timer runs out: each player fades its sound and pauses.
    static let fired = Notification.Name("SleepTimerFired")
    /// Posted when the mode changes, so the video player stops queueing the next episode.
    static let changed = Notification.Name("SleepTimerChanged")
    /// The choices, in minutes.
    static let durations = [15, 30, 45, 60, 90]
    /// How long the sound takes to fade out.
    static let fadeLength: Double = 6

    @Published private(set) var mode: Mode = .off
    private var task: Task<Void, Never>?

    var isOn: Bool { mode != .off }
    var endsWithItem: Bool { mode == .endOfItem }
    /// The minutes picked last, which the menu ticks while they run.
    @Published private(set) var minutes: Int?

    func start(minutes: Int) {
        set(.at(Date().addingTimeInterval(Double(minutes) * 60)), minutes: minutes)
    }

    func stopAtEndOfItem() { set(.endOfItem, minutes: nil) }

    #if DEBUG
    /// `-qaSleepTimer <seconds>` runs out that many seconds after launch; `-qaSleepTimer end` stops at the end of the item.
    func qaStart() {
        guard let value = UserDefaults.standard.string(forKey: "qaSleepTimer") else { return }
        if value == "end" { stopAtEndOfItem() } else if let seconds = Double(value) { set(.at(Date().addingTimeInterval(seconds)), minutes: nil) }
    }
    #endif

    func cancel() { set(.off, minutes: nil) }

    private func set(_ new: Mode, minutes: Int?) {
        task?.cancel(); task = nil
        mode = new; self.minutes = minutes
        Diagnostics.shared.record(.info, "sleep", "timer \(Self.describe(new))")
        NotificationCenter.default.post(name: Self.changed, object: self)
        guard case .at(let deadline) = new else { return }
        task = Task { [weak self] in
            // Sleeping to a moment in a loop survives the clock changing and the app waiting in the background.
            while !Task.isCancelled {
                let left = deadline.timeIntervalSinceNow
                if left <= 0 { break }
                try? await Task.sleep(for: .seconds(min(left, 30)))
            }
            guard !Task.isCancelled, let self else { return }
            self.fire()
        }
    }

    /// A song or episode played to its end: true when the timer was waiting for that, and has now stopped playback.
    func itemEnded() -> Bool {
        guard mode == .endOfItem else { return false }
        fire()
        return true
    }

    private func fire() {
        Diagnostics.shared.record(.info, "sleep", "timer fired")
        task = nil; mode = .off; minutes = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
        NotificationCenter.default.post(name: Self.fired, object: self)
    }

    /// Time left, for the label: "23:41" or "1:05:00".
    func remaining(at now: Date = Date()) -> String? {
        guard case .at(let deadline) = mode else { return nil }
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The menu's subtitle: when playback stops ("Until 1:45 AM", which stays true while a menu is open), or "End of Song".
    func status(item: SleepTimerItem) -> String {
        switch mode {
        case .off: L10n.text("Off")
        case .at(let deadline): L10n.text("Until %@", deadline.formatted(date: .omitted, time: .shortened))
        case .endOfItem: item.title
        }
    }

    /// The badge's text: the time left, ticking, or "End of Song".
    func countdown(item: SleepTimerItem, at now: Date) -> String {
        remaining(at: now) ?? item.title
    }

    static func label(minutes: Int) -> String {
        minutes < 60 || minutes % 60 != 0
            ? L10n.text("%d Minutes", minutes)
            : (minutes == 60 ? L10n.text("1 Hour") : L10n.text("%d Hours", minutes / 60))
    }

    private static func describe(_ mode: Mode) -> String {
        switch mode {
        case .off: "off"
        case .at(let date): "at +\(Int(date.timeIntervalSinceNow))s"
        case .endOfItem: "end of item"
        }
    }

    /// Lowers a player's sound to nothing, pauses it, then gives the sound back for the next time it plays.
    static func fadeOut(_ player: AVPlayer, pause: @escaping @MainActor () -> Void) {
        let start = player.volume, steps = 30
        Task { @MainActor in
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(fadeLength / Double(steps)))
                // Someone paused, or picked something else, meanwhile: the fade has nothing left to do.
                if player.rate == 0 { break }
                player.volume = start * Float(steps - step) / Float(steps)
            }
            pause()
            player.volume = start
        }
    }
}

/// What "the end" means in the menu: the song for music, the episode for video.
enum SleepTimerItem {
    case song, episode
    var title: String { self == .song ? L10n.text("End of Song") : L10n.text("End of Episode") }
}

#if !os(tvOS)
/// The Sleep Timer submenu, for the music player's and the video player's menus.
struct SleepTimerMenu: View {
    var item: SleepTimerItem
    /// Live channels never end, so they have no "End of Episode".
    var offersEnd = true
    private var timer: SleepTimer { .shared }

    var body: some View {
        Menu {
            Picker(L10n.text("Sleep Timer"), selection: selection) {
                Text(L10n.text("Off")).tag(Choice.off)
                ForEach(SleepTimer.durations, id: \.self) { Text(SleepTimer.label(minutes: $0)).tag(Choice.minutes($0)) }
                if offersEnd { Text(item.title).tag(Choice.endOfItem) }
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(L10n.text("Sleep Timer"))
                if timer.isOn { Text(timer.status(item: item)) }
            } icon: {
                Image(systemName: timer.isOn ? "moon.zzz.fill" : "moon.zzz")
            }
        }
        .accessibilityIdentifier("sleepTimer.menu")
    }

    private enum Choice: Hashable { case off, minutes(Int), endOfItem }

    private var selection: Binding<Choice> {
        Binding {
            switch timer.mode {
            case .off: .off
            case .at: timer.minutes.map(Choice.minutes) ?? .off
            case .endOfItem: .endOfItem
            }
        } set: { choice in
            switch choice {
            case .off: timer.cancel()
            case .minutes(let minutes): timer.start(minutes: minutes)
            case .endOfItem: timer.stopAtEndOfItem()
            }
        }
    }
}

/// The time left, ticking, with the moon: shown while a timer runs. A tap opens the same choices.
struct SleepTimerBadge: View {
    var item: SleepTimerItem
    private var timer: SleepTimer { .shared }

    var body: some View {
        if timer.isOn {
            Menu {
                SleepTimerMenu(item: item)
                Button(L10n.text("Turn Off Sleep Timer"), systemImage: "xmark") { timer.cancel() }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Label(timer.countdown(item: item, at: context.date), systemImage: "moon.zzz.fill")
                        .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Sleep Timer"))
            .accessibilityValue(timer.status(item: item))
            .accessibilityIdentifier("sleepTimer.badge")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}
#endif

#if canImport(UIKit)
extension SleepTimer {
    /// The Sleep Timer submenu for AVKit's transport bar on Apple TV, and other UIKit menus.
    func uiMenu(item: SleepTimerItem, offersEnd: Bool = true) -> UIMenu {
        let title = L10n.text("Sleep Timer") + (isOn ? " · " + status(item: item) : "")
        var options: [UIMenuElement] = [UIAction(title: L10n.text("Off"), state: mode == .off ? .on : .off) { _ in SleepTimer.shared.cancel() }]
        for minutes in Self.durations {
            let on = self.minutes == minutes && isOn
            options.append(UIAction(title: Self.label(minutes: minutes), state: on ? .on : .off) { _ in SleepTimer.shared.start(minutes: minutes) })
        }
        if offersEnd {
            options.append(UIAction(title: item.title, state: endsWithItem ? .on : .off) { _ in SleepTimer.shared.stopAtEndOfItem() })
        }
        return UIMenu(title: title, image: UIImage(systemName: isOn ? "moon.zzz.fill" : "moon.zzz"), children: options)
    }
}
#endif
