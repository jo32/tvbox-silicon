//
//  EpisodePicker.swift
//  TVBox
//
//  The episode sheet the player opens straight into, ported from One's layout:
//  a compact picture at the top, the line switcher and the episode grid under it,
//  so tapping a video lands on "pick an episode" instead of a bare player.
//
//  Two behaviours the requirement calls out, both of which the previous sheet
//  did not have:
//
//  1. Reopening a video resumes the last episode at its saved position on the
//     last-used line. That state already exists — PlaybackHistoryContext records
//     `sourceKey`, `videoID` and `episodeFlag`, and PlaybackHistoryEntry keeps the
//     position — so this view only has to read it back, and fall back to episode 1
//     at 0 s when there is nothing saved.
//
//  2. Switching lines shows each line's health before committing. Readings are
//     lazy: only the lines in the visible grid get probed, one at a time, and the
//     result is cached so reopening the sheet does not re-measure everything.
//

import SwiftUI
import TVCore

// MARK: - Line health row model

/// One line of the current video, with whatever health we already know.
struct EpisodeLine: Identifiable, Hashable {
    let flag: String
    var probe: SourceProbeResult

    var id: String { flag }
}

// MARK: - Probe controller

/// Drives lazy probing for the picker. Keeps at most one probe in flight per
/// video so opening the sheet never fires a burst of requests.
@MainActor
@Observable
final class EpisodeProbeController {
    private(set) var readings: [String: SourceProbeResult] = [:]
    /// Line flag → probe host, so cooldown is queried by host (the rotator's key), not by flag.
    private var bases: [String: String] = [:]
    private var inFlight: Set<String> = []
    private let store = SourceProbeStore.shared

    func loadCached(sourceKey: String, videoID: String) {
        readings.merge(store.probes(sourceKey: sourceKey, videoID: videoID)) { current, _ in current }
    }

    /// Probes one line unless it is already known and fresh, or already running.
    func probeIfNeeded(
        line: String,
        address: String,
        headers: [String: String],
        sourceKey: String,
        videoID: String,
        force: Bool = false
    ) async {
        guard !line.isEmpty, let url = URL(string: address), !inFlight.contains(line) else { return }
        if let host = url.host { bases[line] = host }
        if !force, let known = readings[line] ?? store.probe(sourceKey: sourceKey, videoID: videoID, lineFlag: line),
           !known.isStale(), known.reachability != .unknown {
            readings[line] = known
            return
        }

        inFlight.insert(line)
        defer { inFlight.remove(line) }

        // HostRotation is keyed by host: claim it, then record success/failure/cancel on the same key.
        let base = url.host
        if let base, !store.beginBase(base) { return }

        let result = await SourceProbeRunner.probe(url: url, headers: headers)
        if Task.isCancelled {
            if let base { store.cancelBase(base) }
            return
        }
        if let base {
            switch result.reachability {
            case .reachable, .slow: store.succeedBase(base)
            case .unreachable: store.failBase(base)
            case .unknown: store.cancelBase(base)
            }
        }
        readings[line] = result
        store.record(result, sourceKey: sourceKey, videoID: videoID, lineFlag: line)
    }

    func reading(for line: String) -> SourceProbeResult? { readings[line] }

    /// Seconds until `line` may be tried again, or nil when it may be tried now.
    func cooldownRemaining(for line: String, now: Date = Date()) -> TimeInterval? {
        guard let base = bases[line] else { return nil }
        return store.cooldownRemaining(for: base, now: now)
    }

    /// The soonest any cooling line becomes usable, or nil when one already is.
    func soonestCooldown(now: Date = Date()) -> TimeInterval? {
        store.soonestCooldown(now: now)
    }
}

// MARK: - Picker

struct EpisodePicker: View {
    let video: Video
    let sourceKey: String
    let sourceName: String
    let origin: URL
    /// Saved context for this video, if it has ever been played.
    let resumeContext: PlaybackHistoryContext?
    /// Saved position to jump to on open, in seconds.
    let resumePosition: Double?
    let headers: [String: String]
    let play: @MainActor (Episode) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    @State private var state = EpisodeProbeController()
    @State private var activeLine: String

    private var playlist: EpisodePlaylist { EpisodePlaylist(video.episodes) }
    /// Lines the picker shows: the full flag list minus the viewer-hidden ones. A hidden line is
    /// restored from the source's full detail, where a small button brings it back.
    private var flags: [String] { playlist.flags.filter { !store.lineSettings.isHidden(origin: origin, sourceKey: sourceKey, flag: $0) } }
    /// All flags, including hidden ones, for the "restore hidden lines" button.
    private var hiddenFlags: [String] { playlist.flags.filter { store.lineSettings.isHidden(origin: origin, sourceKey: sourceKey, flag: $0) } }

    init(
        video: Video,
        sourceKey: String,
        sourceName: String,
        origin: URL,
        resumeContext: PlaybackHistoryContext?,
        resumePosition: Double?,
        headers: [String: String],
        play: @escaping @MainActor (Episode) -> Void
    ) {
        self.video = video
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.origin = origin
        self.resumeContext = resumeContext
        self.resumePosition = resumePosition
        self.headers = headers
        self.play = play
        // Reopen on the line that was in use; fall back to the source's first.
        let saved = resumeContext?.episodeFlag
        let firstFlags = EpisodePlaylist(video.episodes).flags
        let first = firstFlags.first ?? ""
        _activeLine = State(initialValue: saved.flatMap { firstFlags.contains($0) ? $0 : nil } ?? first)
    }

    private var episodesOnActiveLine: [Episode] { playlist.episodes(for: activeLine) }

    /// The episode the play button should resume: the saved one when it still
    /// exists on this line, else the first.
    private var resumeEpisode: Episode? {
        if let context = resumeContext, let saved = context.episode(in: episodesOnActiveLine) { return saved }
        return episodesOnActiveLine.first
    }

    private var resumeTargetText: String? {
        guard let episode = resumeEpisode else { return nil }
        guard let position = resumePosition, position > 1 else { return episode.name }
        let pattern: Duration.TimeFormatStyle.Pattern = position >= 3600 ? .hourMinuteSecond : .minuteSecond
        return L10n.text("%@ · from %@", episode.name, Duration.seconds(Int(position)).formatted(.time(pattern: pattern)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if flags.count > 1 { lineSwitcher }
                    episodeGrid
                }
                .padding(18)
            }
            .background(.background)
            .navigationTitle(video.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Close")) { dismiss() }
                }
            }
        }
        .onAppear {
            // The saved/fallback line can be one the viewer hid after it was last used. If the active
            // line is no longer visible, step to the first visible line so the grid never shows a
            // hidden line's episodes with no matching chip.
            if !flags.contains(activeLine), let first = flags.first {
                activeLine = first
            }
        }
        .task(id: activeLine) {
            await loadReadings()
            await probeVisibleLines()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            poster
            VStack(alignment: .leading, spacing: 6) {
                Text(video.name).font(.headline).lineLimit(2)
                if !video.remarks.isEmpty {
                    Text(video.remarks).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if let target = resumeTargetText {
                    Label(target, systemImage: "play.circle")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                }
                Button {
                    guard let episode = resumeEpisode else { return }
                    play(episode)
                    dismiss()
                } label: {
                    Label(
                        resumePosition.map { $0 > 1 } == true ? L10n.text("Continue") : L10n.text("Play"),
                        systemImage: "play.fill"
                    )
                    .frame(maxWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .disabled(resumeEpisode == nil)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    private var poster: some View {
        Group {
            if let address = video.poster {
                AsyncImage(url: address) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 108, height: 162)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Line switcher

    private var lineSwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Source")).font(.subheadline).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        lineChip(flag)
                    }
                }
            }
            if !hiddenFlags.isEmpty {
                Button {
                    store.lineSettings.restoreAll(origin: origin, sourceKey: sourceKey)
                } label: {
                    // A hidden line is hidden for every video from this source, so the label says so.
                    Label(L10n.text("Show %lld hidden lines (all videos)", hiddenFlags.count), systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                .accessibilityIdentifier("lines.restoreHidden")
            }
            allCoolingNotice
        }
    }

    private func lineChip(_ flag: String) -> some View {
        let reading = state.reading(for: flag)
        let selected = flag == activeLine
        // A line that failed recently is not offered again until its backoff expires. Showing the
        // countdown matters more than hiding the chip: a line that silently vanished reads as a bug.
        let cooling = state.cooldownRemaining(for: flag)
        return Button {
            guard cooling == nil else { return }
            activeLine = flag
            Task { await probe(flag) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if cooling != nil {
                        Image(systemName: "clock.arrow.circlepath").font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Circle().fill(color(for: reading)).frame(width: 7, height: 7)
                    }
                    Text(flag.isEmpty ? L10n.text("Line 1") : flag)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(cooling == nil ? .primary : .secondary)
                }
                Text(cooling.map { L10n.text("Retry in %@s", String(Int($0.rounded(.up)))) }
                     ?? reading?.summary() ?? L10n.text("Tap to check"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            .opacity(cooling == nil ? 1 : 0.55)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(cooling != nil)
        .contextMenu {
            // Per-line routing: this line alone can go direct or through a custom proxy, whatever its source does.
            Menu {
                Button { store.lineSettings.setRoute(nil, origin: origin, sourceKey: sourceKey, flag: flag) } label: {
                    Label(L10n.text("Follow Source"), systemImage: store.lineSettings.route(origin: origin, sourceKey: sourceKey, flag: flag) == nil ? "checkmark" : "arrow.uturn.backward")
                }
                Button { store.lineSettings.setRoute(.direct, origin: origin, sourceKey: sourceKey, flag: flag) } label: {
                    Label(L10n.text("Direct"), systemImage: store.lineSettings.route(origin: origin, sourceKey: sourceKey, flag: flag) == .direct ? "checkmark" : "bolt")
                }
                if let proxy = store.customProxy.store.endpoints.first {
                    Button { store.lineSettings.setRoute(.proxy(proxy.id), origin: origin, sourceKey: sourceKey, flag: flag) } label: {
                        Label(proxy.name, systemImage: store.lineSettings.route(origin: origin, sourceKey: sourceKey, flag: flag)?.proxyID == proxy.id ? "checkmark" : "network")
                    }
                }
            } label: {
                Label(L10n.text("Connection"), systemImage: "network")
            }
            Button(role: .destructive) {
                store.lineSettings.setHidden(true, origin: origin, sourceKey: sourceKey, flag: flag)
            } label: {
                Label(L10n.text("Hide Line"), systemImage: "eye.slash")
            }
        }
    }

    /// Shown under the switcher when every line is inside its backoff, so the list does not look
    /// broken. Wording follows One's own copy for the same situation.
    @ViewBuilder private var allCoolingNotice: some View {
        if let soonest = state.soonestCooldown() {
            Label(L10n.text("Every line is cooling down. Soonest is ready in %@s.", String(Int(soonest.rounded(.up)))),
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for reading: SourceProbeResult?) -> Color {
        switch reading?.reachability {
        case .reachable: return .green
        case .slow: return .orange
        case .unreachable: return .red
        case .unknown, .none: return .secondary
        }
    }

    // MARK: Episodes

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Episodes"))
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(episodesOnActiveLine) { episode in
                    episodeCell(episode)
                }
            }
        }
    }

    private func episodeCell(_ episode: Episode) -> some View {
        let isResume = episode.id == resumeEpisode?.id
        return Button {
            play(episode)
            dismiss()
        } label: {
            VStack(spacing: 2) {
                Text(episode.name).font(.subheadline).lineLimit(1)
                if isResume, let position = resumePosition, position > 1 {
                    Text(progressText(position))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isResume ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func progressText(_ position: Double) -> String {
        let pattern: Duration.TimeFormatStyle.Pattern = position >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(Int(position)).formatted(.time(pattern: pattern))
    }

    // MARK: Probing

    /// Cached readings first, so the sheet paints instantly with whatever the
    /// last visit learned.
    private func loadReadings() async {
        state.loadCached(sourceKey: sourceKey, videoID: video.id)
    }

    /// Probes only the active line's address. Other lines are measured when the
    /// user actually selects them, which keeps opening the sheet cheap.
    private func probeVisibleLines() async {
        if let episode = episodesOnActiveLine.first {
            await probe(activeLine, address: episode.address)
        }
    }

    private func probe(_ flag: String) async {
        guard let episode = playlist.episodes(for: flag).first else { return }
        await probe(flag, address: episode.address)
    }

    private func probe(_ flag: String, address: String) async {
        await state.probeIfNeeded(
            line: flag,
            address: address,
            headers: headers,
            sourceKey: sourceKey,
            videoID: video.id
        )
    }
}
