import SwiftUI
import TVCore
#if !os(macOS)
import UIKit
#endif

/// Downloaded episodes, the download queue, and how much space they take.
struct DownloadsView: View {
    @Environment(Store.self) private var store
    @State private var deleting: DownloadShow?
    /// Videos or songs, once there are songs; videos first unless only songs are saved.
    @State private var kind = Kind.videos
    private var library: DownloadLibrary { .shared }
    enum Kind: Hashable { case videos, music }

    var body: some View {
        let pending = library.items.filter(\.isPending)
        let shows = DownloadShow.group(library.items.filter { $0.status == .completed })
        Group {
            if hasMusic && kind == .music {
                MusicDownloadsView(embedded: true)
            } else if library.items.isEmpty {
                // One message instead of an empty storage card above it: a 0 KB total says nothing new.
                EmptyDownloads(available: library.usage.available) { store.section = .sites }
            } else {
                content(pending: pending, shows: shows)
            }
        }
        .modifier(DownloadKindBar(shown: hasMusic, kind: $kind))
        .onAppear { if library.items.isEmpty && hasMusic { kind = .music } }
        .screenBackdrop()
        .tabTitle(L10n.text("Downloads"))
        .task { await library.measure() }
        .onChange(of: library.items.filter { $0.status == .completed }.count) { Task { await library.measure() } }
        #if os(macOS)
        // Files may have been deleted or moved in Finder while the app was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.measure() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { NSWorkspace.shared.open(hasMusic && kind == .music ? MusicDownloadLibrary.shared.root : library.root) } label: {
                    Label(L10n.text("Show in Finder"), systemImage: "folder")
                }
                .help(L10n.text("Show in Finder"))
            }
        }
        #endif
        .confirmationDialog(L10n.text("Delete all downloaded episodes of %@?", deleting?.title ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Delete Downloads"), role: .destructive) {
                if let deleting { library.remove(deleting.items.map(\.id)) }
                deleting = nil
            }
        }
    }

    /// Songs are saved apart, in Music; this page leads there too.
    private var hasMusic: Bool { !MusicDownloadLibrary.shared.items.isEmpty }

    private func content(pending: [DownloadItem], shows: [DownloadShow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                StorageCard(usage: library.usage, songs: MusicDownloadLibrary.shared.size)
                if !pending.isEmpty { queue(pending) }
                if !shows.isEmpty {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        SectionHeader(title: L10n.text("Downloaded"))
                        // Not lazy: the remote only moves focus to views that exist, and below a download queue
                        // as tall as the screen a lazy stack had built none, so Down stopped at the queue.
                        VStack(spacing: Layout.cardSpacing) {
                            ForEach(shows) { show in
                                ShowPanel(show: show) { store.playing = library.channel(for: $0) } delete: { deleting = show }
                            }
                        }
                    }.tvFocusSection()
                }
            }.pageContainer()
        }
    }

    private func queue(_ pending: [DownloadItem]) -> some View {
        let paused = pending.filter { $0.status == .paused || $0.status == .failed }
        return VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            HStack(alignment: .center, spacing: 12) {
                SectionHeader(title: L10n.text("Downloading"))
                Text("\(pending.count)").font(.headline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Menu {
                    Picker(L10n.text("At a Time"), selection: Binding(get: { library.simultaneous }, set: { library.simultaneous = $0 })) {
                        ForEach(1...4, id: \.self) { Text(L10n.text("%lld at a time", $0)).tag($0) }
                    }
                } label: {
                    Label(L10n.text("%lld at a time", library.simultaneous), systemImage: "square.stack.3d.down.right")
                        .lineLimit(1).fixedSize()
                }
                .controlButton()
                if paused.count == pending.count {
                    Button { library.resumeAll() } label: { Label(L10n.text("Resume All"), systemImage: "play.fill").lineLimit(1).fixedSize() }.controlButton()
                } else {
                    Button { library.pauseAll() } label: { Label(L10n.text("Pause All"), systemImage: "pause.fill").lineLimit(1).fixedSize() }.controlButton()
                }
            }
            VStack(spacing: DownloadMetrics.rowSpacing) {
                ForEach(pending) { item in
                    QueueRow(item: item, rate: library.rates[item.id], position: queuePosition(item, in: pending))
                }
            }
        }.tvFocusSection()
    }

    /// 1 for the next download to start.
    private func queuePosition(_ item: DownloadItem, in pending: [DownloadItem]) -> Int? {
        guard item.status == .queued else { return nil }
        return (pending.filter { $0.status == .queued }.firstIndex { $0.id == item.id } ?? 0) + 1
    }
}

/// Videos | Music once songs are saved too: in the window's toolbar on the Mac, beside the title, as
/// Music and Photos place theirs; a band of its own took a second row there. On iPhone and iPad it is
/// pinned under the title while the page scrolls under it; on Apple TV it is two chips over the page,
/// like the Music page's kinds.
private struct DownloadKindBar: ViewModifier {
    let shown: Bool
    @Binding var kind: DownloadsView.Kind

    func body(content: Content) -> some View {
        if shown {
            #if os(macOS)
            content.toolbar {
                ToolbarItem(placement: .principal) { picker.fixedSize() }
            }
            #elseif os(tvOS)
            content.safeAreaInset(edge: .top, spacing: 0) {
                GlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Chip(title: L10n.text("Videos"), selected: kind == .videos) { kind = .videos }
                        Chip(title: L10n.text("Music"), selected: kind == .music) { kind = .music }
                    }
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Layout.gutter)
                .background(TVStyle.background)
                .focusSection()
            }
            #else
            content.topBar {
                picker
                    .frame(maxWidth: 320)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Layout.gutter).padding(.vertical, 8)
            }
            #endif
        } else {
            content
        }
    }

    private var picker: some View {
        Picker(L10n.text("Downloads"), selection: $kind) {
            Text(L10n.text("Videos")).tag(DownloadsView.Kind.videos)
            Text(L10n.text("Music")).tag(DownloadsView.Kind.music)
        }
        .pickerStyle(.segmented).labelsHidden()
    }
}

enum DownloadMetrics {
    #if os(tvOS)
    static let thumb: CGFloat = 96, showPoster: CGFloat = 170, episodeMin: CGFloat = 440, rowSpacing: CGFloat = 20
    #elseif os(macOS)
    static let thumb: CGFloat = 44, showPoster: CGFloat = 96, episodeMin: CGFloat = 260, rowSpacing: CGFloat = 10
    #else
    static let thumb: CGFloat = 46, showPoster: CGFloat = 84, episodeMin: CGFloat = 220, rowSpacing: CGFloat = 10
    #endif
}

/// Finished episodes of one video from one source.
struct DownloadShow: Identifiable {
    let id: String
    let title: String
    let poster: URL?
    let posterHeaders: [String: String]
    let sourceName: String
    let items: [DownloadItem]
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    /// Most recently finished first; episodes in the order the source lists them.
    static func group(_ items: [DownloadItem]) -> [DownloadShow] {
        let groups = Dictionary(grouping: items) { $0.source.siteKey + "\u{1F}" + $0.source.videoID }
        return groups.map { key, items in
            let first = items[0]
            return DownloadShow(id: key, title: first.title, poster: first.poster, posterHeaders: first.posterHeaders,
                                sourceName: first.source.siteName,
                                items: items.sorted { $0.episode.localizedStandardCompare($1.episode) == .orderedAscending })
        }
        .sorted { ($0.items.compactMap(\.finished).max() ?? .distantPast) > ($1.items.compactMap(\.finished).max() ?? .distantPast) }
    }
}

enum DownloadFormat {
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file) }
    static func rate(_ bytes: Double) -> String { L10n.text("%@/s", size(Int64(bytes))) }
    static func remaining(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute] : [.second]
        formatter.maximumUnitCount = 2
        return L10n.text("%@ left", formatter.string(from: max(1, seconds)) ?? "")
    }
}

/// The page before anything is downloaded: what the page is for, the way to start, and the room there is.
private struct EmptyDownloads: View {
    let available: Int64?
    let browse: () -> Void
    var body: some View {
        EmptyPage(symbol: "arrow.down", title: L10n.text("No Downloads"),
                  message: L10n.text("Choose Download on a video's page to save episodes for watching offline."),
                  action: L10n.text("Browse Sources"), actionSymbol: AppSection.sites.icon, perform: browse) {
            if let available {
                Label(L10n.text("%@ available on this device", DownloadFormat.size(available)), systemImage: "internaldrive")
            }
        }
    }
}

/// Space used by downloads against the rest of the device, as one bar.
private struct StorageCard: View {
    let usage: DownloadLibrary.Usage
    /// Downloaded songs, kept apart from the episodes.
    var songs: Int64 = 0
    var body: some View {
        let downloads = usage.downloads + songs
        let capacity = usage.capacity ?? 0
        let free = usage.available ?? 0
        let other = max(0, capacity - free - downloads)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "internaldrive.fill").foregroundStyle(Brand.accent).accessibilityHidden(true)
                Text(L10n.text("Storage")).font(.headline)
                Spacer(minLength: 8)
                if usage.available != nil {
                    Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(DownloadFormat.size(downloads)).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                Text(L10n.text("used by downloads")).font(.subheadline).foregroundStyle(.secondary)
            }
            if capacity > 0 {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let share = { (bytes: Int64) in width * CGFloat(Double(bytes) / Double(capacity)) }
                    HStack(spacing: 2) {
                        Rectangle().fill(Brand.cyan).frame(width: downloads > 0 ? max(4, share(downloads)) : 0)
                        Rectangle().fill(Color.primary.opacity(0.28)).frame(width: share(other))
                        Rectangle().fill(Color.primary.opacity(0.08))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: DownloadMetrics.thumb > 60 ? 16 : 10)
                .accessibilityHidden(true)
                HStack(spacing: 18) {
                    legend(Brand.cyan, L10n.text("Downloads"), downloads)
                    legend(Color.primary.opacity(0.28), L10n.text("Other"), other)
                    legend(Color.primary.opacity(0.12), L10n.text("Free"), free)
                }
                .font(.caption)
            }
            #if os(tvOS)
            Text(L10n.text("tvOS may remove downloads when Apple TV runs low on storage.")).font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .padding(DownloadMetrics.thumb > 60 ? 28 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
        .accessibilityElement(children: .combine)
        #if os(tvOS)
        // Focusable so the remote can scroll back up to it.
        .focusable()
        #endif
    }
    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(DownloadFormat.size(bytes)).monospacedDigit()
        }.lineLimit(1)
    }
}

/// A download in the queue: progress, speed and its controls.
private struct QueueRow: View {
    let item: DownloadItem
    let rate: Double?
    let position: Int?
    private var library: DownloadLibrary { .shared }
    var body: some View {
        HStack(spacing: 14) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: DownloadMetrics.thumb)
                .overlay { PosterImage(url: item.poster, headers: item.posterHeaders) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.episode).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let quality = item.quality { Pill(text: quality) }
                }
                ProgressView(value: item.fraction)
                    .tint(item.status == .failed ? Brand.rose : item.status == .paused ? Color.secondary : Brand.accent)
                // One line: drop the byte counts when the full status doesn't fit (phones).
                ViewThatFits(in: .horizontal) {
                    Text(status(compact: false)).fixedSize()
                    Text(status(compact: true)).lineLimit(item.status == .failed ? 2 : 1)
                }
                .font(.caption).monospacedDigit()
                .foregroundStyle(item.status == .failed ? AnyShapeStyle(Brand.rose) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                switch item.status {
                case .paused, .failed:
                    control(item.status == .failed ? "arrow.clockwise" : "play.fill", L10n.text(item.status == .failed ? "Retry" : "Resume")) { library.resume(item.id) }
                case .finishing: EmptyView()
                default:
                    control("pause.fill", L10n.text("Pause")) { library.pause(item.id) }
                }
                control("xmark", L10n.text("Cancel Download")) { library.remove([item.id]) }
            }
        }
        .padding(DownloadMetrics.thumb > 60 ? 18 : 12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if item.status == .queued, (position ?? 1) > 1 {
                Button(L10n.text("Download Next"), systemImage: "arrow.up.to.line") { library.prioritize(item.id) }
            }
            Button(L10n.text("Cancel Download"), systemImage: "xmark", role: .destructive) { library.remove([item.id]) }
        }
    }

    private func status(compact: Bool) -> String {
        let percent = Int((item.fraction * 100).rounded(.down))
        let amount = item.expected.map { L10n.text("%@ of %@", DownloadFormat.size(item.received), DownloadFormat.size($0)) }
            ?? DownloadFormat.size(item.received)
        switch item.status {
        case .queued:
            return position.map { L10n.text("Waiting · #%lld in queue", $0) } ?? L10n.text("Waiting")
        case .downloading:
            guard item.kind != nil else { return L10n.text("Getting the video link…") }
            var parts = compact ? ["\(percent)%"] : ["\(percent)%", amount]
            if let rate, rate > 1024 {
                parts.append(DownloadFormat.rate(rate))
                if let expected = item.expected, expected > item.received { parts.append(DownloadFormat.remaining(Double(expected - item.received) / rate)) }
            }
            return parts.joined(separator: " · ")
        case .finishing: return L10n.text("Finishing…")
        case .paused: return L10n.text("Paused") + " · \(percent)%" + (compact ? "" : " · " + amount)
        case .failed: return item.failure ?? L10n.text("Download failed")
        case .completed: return ""
        }
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: DownloadMetrics.thumb > 60 ? 24 : 13, weight: .semibold)).frame(width: DownloadMetrics.thumb > 60 ? 32 : 18)
        }
        .controlButton()
        .accessibilityLabel(label)
        .help(label)
    }
}

/// One video's downloaded episodes.
private struct ShowPanel: View {
    let show: DownloadShow
    let play: (DownloadItem) -> Void
    let delete: () -> Void
    private var library: DownloadLibrary { .shared }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: DownloadMetrics.showPoster)
                .overlay { PosterImage(url: show.poster, headers: show.posterHeaders) }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(show.title).font(.headline).lineLimit(2)
                    Text([SourceLabel(show.sourceName).text, show.items.count == 1 ? L10n.text("1 episode") : L10n.text("%lld episodes", show.items.count), DownloadFormat.size(show.size)].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                EpisodeGrid(minimum: DownloadMetrics.episodeMin, spacing: 8, rowSpacing: DownloadMetrics.thumb > 60 ? 12 : 4).callAsFunction {
                    ForEach(show.items) { item in episode(item) }
                }
                .tvFocusSection()
                Button(role: .destructive, action: delete) {
                    Label(L10n.text("Delete Downloads"), systemImage: "trash").font(.subheadline)
                }
                .controlButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DownloadMetrics.thumb > 60 ? 22 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func episode(_ item: DownloadItem) -> some View {
        Button { play(item) } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 10)).foregroundStyle(.secondary)
                Text(item.episode).lineLimit(1)
                Spacer(minLength: 8)
                if let quality = item.quality { Text(quality).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(DownloadFormat.size(item.size)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            #if !os(tvOS)
            .padding(.horizontal, 10).frame(minHeight: 34)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .glassRow()
        .accessibilityLabel(L10n.text("Play %@", item.episode))
        .contextMenu {
            #if os(macOS)
            if let file = library.file(for: item) {
                Button(L10n.text("Show in Finder"), systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            #endif
            Button(L10n.text("Delete Download"), systemImage: "trash", role: .destructive) { library.remove([item.id]) }
        }
    }
}

/// LazyVGrid's adaptive columns, built all at once, for the same reason as the list of shows: a lazy grid below
/// the screen has no episodes yet for the remote to move to.
private struct EpisodeGrid: SwiftUI.Layout {
    let minimum: CGFloat
    let spacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minimum
        let rows = rows(subviews, width: width)
        return CGSize(width: width, height: rows.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = cellWidth(bounds.width)
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            for (column, index) in row.indices.enumerated() {
                subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(column) * (cell + spacing), y: y),
                                      proposal: ProposedViewSize(width: cell, height: row.height))
            }
            y += row.height + rowSpacing
        }
    }

    private func columns(_ width: CGFloat) -> Int { max(1, Int((width + spacing) / (minimum + spacing))) }
    private func cellWidth(_ width: CGFloat) -> CGFloat {
        let count = CGFloat(columns(width))
        return max(0, (width - spacing * (count - 1)) / count)
    }
    private func rows(_ subviews: Subviews, width: CGFloat) -> [(indices: Range<Int>, height: CGFloat)] {
        let count = columns(width), cell = ProposedViewSize(width: cellWidth(width), height: nil)
        return stride(from: 0, to: subviews.count, by: count).map { start in
            let indices = start..<min(start + count, subviews.count)
            return (indices, indices.map { subviews[$0].sizeThatFits(cell).height }.max() ?? 0)
        }
    }
}

/// A downloaded episode's mark on a short episode chip.
struct DownloadedBadge: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: DownloadMetrics.thumb > 60 ? 22 : 12, weight: .semibold))
            .foregroundStyle(Brand.onAccent, Brand.accent)
            .offset(x: 4, y: -4)
            .accessibilityLabel(L10n.text("Downloaded"))
    }
}

/// A download's state beside an episode name: downloaded, progress, waiting or failed.
struct DownloadState: View {
    let status: DownloadItem.Status
    let fraction: Double
    init(item: DownloadItem) { status = item.status; fraction = item.fraction }
    init(status: DownloadItem.Status, fraction: Double) { self.status = status; self.fraction = fraction }
    static var size: CGFloat { DownloadMetrics.thumb > 60 ? 24 : 13 }
    var body: some View {
        let size = Self.size
        Group {
            switch status {
            case .completed:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent).accessibilityLabel(L10n.text("Downloaded"))
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.rose).accessibilityLabel(L10n.text("Download failed"))
            case .downloading, .finishing:
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.03, fraction)).stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: size, height: size)
                .accessibilityLabel(L10n.text("Downloading"))
            case .queued, .paused:
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).accessibilityLabel(L10n.text("In Queue"))
            }
        }
        .font(.system(size: size))
        .animation(.smooth, value: fraction)
    }
}

/// Picks episodes of the current line to download.
struct DownloadPicker: View {
    let video: Video
    let site: Site
    let flag: String
    let episodes: [Episode]
    var added: (Int) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    private var library: DownloadLibrary { .shared }
    private func source(_ episode: Episode) -> DownloadSource { DownloadSource(site: site, videoID: video.id, episode: episode) }
    private var available: [Episode] { episodes.filter { library.item(for: source($0)).map { $0.status == .failed } ?? true } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: DownloadMetrics.thumb * 1.2)
                    .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Download Episodes")).font(.title2.weight(.bold))
                    Text(video.name).font(.headline).lineLimit(2)
                    if !flag.isEmpty { Text(SourceLabel(flag).text).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                let all = !available.isEmpty && available.allSatisfy { selection.contains($0.id) }
                Button { selection = all ? [] : Set(available.map(\.id)) } label: {
                    Label(L10n.text(all ? "Deselect All" : "Select All"), systemImage: all ? "circle" : "checkmark.circle")
                }
                .controlButton().disabled(available.isEmpty)
                Spacer(minLength: 8)
                if let free = library.usage.available {
                    Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .tvFocusSection()
            ScrollView {
                // One column of glass rows on the TV, as in the danmaku list; a compact grid elsewhere.
                LazyVGrid(columns: Self.columns, spacing: DownloadMetrics.thumb > 60 ? 4 : 8) {
                    ForEach(episodes) { episode in row(episode) }
                }
                .padding(.vertical, 4)
                .glassRowInsets()
            }
            #if os(tvOS)
            // Let the insets reach into the page margin, so the rows' glass lines up with the header.
            .padding(.horizontal, -40)
            #endif
            .tvFocusSection()
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(L10n.text("Cancel")) { dismiss() }.controlButton()
                Button {
                    let chosen = episodes.filter { selection.contains($0.id) }
                    for episode in chosen { library.download(source(episode), title: video.name, poster: video.poster, posterHeaders: video.posterHeaders) }
                    added(chosen.count)
                    dismiss()
                } label: {
                    Label(selection.isEmpty ? L10n.text("Download") : L10n.text("Download %lld", selection.count), systemImage: "arrow.down.circle.fill")
                }
                .controlButton(prominent: true).disabled(selection.isEmpty)
            }
            // A full-width focus section: the buttons sit at the right, out of line with most episodes,
            // and the remote only finds them moving down when the whole row takes focus.
            .tvFocusSection()
        }
        .padding(DownloadMetrics.thumb > 60 ? 60 : 22)
        #if os(macOS)
        .frame(width: 600, height: 620)
        #elseif os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(maxWidth: 1300).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Backdrop() }
        #endif
        .task { await library.measure() }
    }

    private static var columns: [GridItem] {
        #if os(tvOS)
        [GridItem(.flexible())]
        #else
        [GridItem(.adaptive(minimum: 220), spacing: 8)]
        #endif
    }

    private func row(_ episode: Episode) -> some View {
        let existing = library.item(for: source(episode))
        let locked = existing.map { $0.status != .failed } ?? false
        let selected = selection.contains(episode.id)
        return Button {
            if selected { selection.remove(episode.id) } else { selection.insert(episode.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: locked ? "checkmark.circle.fill" : selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(locked ? AnyShapeStyle(.tertiary) : selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
                Text(episode.name).lineLimit(1)
                Spacer(minLength: 6)
                if let existing, locked {
                    Text(existing.status == .completed ? L10n.text("Downloaded") : L10n.text("In Queue")).font(.caption).foregroundStyle(.secondary)
                }
            }
            #if !os(tvOS)
            .padding(.horizontal, 10).frame(minHeight: 36)
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(selected ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .glassRow()
        .disabled(locked)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension View {
    /// A sheet, or on tvOS a full-screen page: tvOS sheets are small and let the page show through.
    @ViewBuilder func downloadPicker<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

/// Downloads keep going briefly after the app leaves the screen, then stop and resume when it returns.
@MainActor enum DownloadsLifecycle {
    #if !os(macOS)
    private static var task: UIBackgroundTaskIdentifier = .invalid
    static func enteredBackground() {
        guard DownloadLibrary.shared.items.contains(where: \.isActive) || MusicDownloadLibrary.shared.items.contains(where: \.isActive),
              task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Downloads") {
            DownloadLibrary.shared.suspend()
            MusicDownloadLibrary.shared.suspend()
            end()
        }
    }
    static func becameActive() {
        end()
        DownloadLibrary.shared.wake()
        MusicDownloadLibrary.shared.wake()
    }
    private static func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
    #endif
}
