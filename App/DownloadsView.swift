import SwiftUI
import TVCore
#if !os(macOS)
import UIKit
#endif
#if os(iOS)
import BackgroundTasks
#endif

/// Downloaded episodes, the download queue, and how much space they take.
struct DownloadsView: View {
    @Environment(Store.self) private var store
    @State private var deleting: DownloadShow?
    /// Videos or songs, once there are songs; videos first unless only songs are saved.
    @State private var kind = Kind.videos
    /// How the downloaded shows are listed, and 倒序 (#653): the other way round.
    @AppStorage("downloads.sort") private var sort = DownloadSort.date
    @AppStorage("downloads.reversed") private var reversed = false
    private var library: DownloadLibrary { .shared }
    enum Kind: Hashable { case videos, music }

    var body: some View {
        let pending = library.items.filter(\.isPending)
        let shows = DownloadShow.group(library.items.filter { $0.status == .completed }, by: sort, reversed: reversed)
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
        .tabTitle(L10n.text("Offline Cache"))
        .task { await library.measure() }
        .onChange(of: library.items.filter { $0.status == .completed }.count) { Task { await library.measure() } }
        #if os(macOS)
        // Space in one line under the window title, as Finder's status bar has it: beside a whole disk the
        // downloads were a sliver on a bar that was nearly all "Other".
        .navigationSubtitle(library.items.isEmpty || (hasMusic && kind == .music) ? "" : storageSummary)
        // Files may have been deleted or moved in Finder while the app was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await library.measure() }
        }
        #endif
        .confirmationDialog(L10n.text("Delete all cached episodes of %@?", deleting?.title ?? ""),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L10n.text("Delete Cached Items"), role: .destructive) {
                if let deleting { library.remove(deleting.items.map(\.id)) }
                deleting = nil
            }
        }
    }

    /// Songs are saved apart, in Music; this page leads there too.
    private var hasMusic: Bool { !MusicDownloadLibrary.shared.items.isEmpty }

    #if os(macOS)
    private var storageSummary: String {
        let used = L10n.text("%@ used by the cache", DownloadFormat.size(library.usage.downloads + MusicDownloadLibrary.shared.size))
        guard let free = library.usage.available else { return used }
        return used + " · " + L10n.text("%@ free", DownloadFormat.size(free))
    }
    #endif

    private func content(pending: [DownloadItem], shows: [DownloadShow]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                #if !os(macOS)
                StorageCard(usage: library.usage, songs: MusicDownloadLibrary.shared.size)
                #endif
                if !pending.isEmpty { queue(pending) }
                if !shows.isEmpty {
                    VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                        downloadedHeader(count: shows.count)
                        // Not lazy: the remote only moves focus to views that exist, and below a download queue
                        // as tall as the screen a lazy grid had built none, so Down stopped at the queue.
                        EpisodeGrid(minimum: DownloadMetrics.cardMin, spacing: Layout.gridSpacing, rowSpacing: Layout.gridRowSpacing).callAsFunction {
                            ForEach(shows) { show in card(show) }
                        }
                    }.tvFocusSection()
                }
            }.pageContainer()
        }
        // TMDB's art for the shows this device hasn't matched yet, one at a time while the page is open.
        .task(id: shows.map(\.id)) { await DownloadArtwork.shared.load(shows) }
    }

    /// A show with several episodes opens its page; a film (one download) plays at once.
    @ViewBuilder private func card(_ show: DownloadShow) -> some View {
        let label = DownloadShowCard(show: show, details: DownloadArtwork.shared.details(for: show))
        Group {
            if show.items.count == 1, let item = show.items.first {
                Button { store.playing = library.channel(for: item) } label: { label }
                    .accessibilityLabel(L10n.text("Play %@", show.title))
            } else {
                RouteLink { DownloadShowPage(id: show.id) } label: { label }
            }
        }
        .downloadCardButton()
        .contextMenu {
            Button(L10n.text("Delete Cached Items"), systemImage: "trash", role: .destructive) { deleting = show }
        }
    }

    /// "Cached", how many shows, then how they are sorted and 倒序, as glass controls.
    private func downloadedHeader(count: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            SectionHeader(title: L10n.text("Cached")).fixedSize().layoutPriority(1)
            Text("\(count)").font(.headline).monospacedDigit().foregroundStyle(.secondary)
            Spacer(minLength: 12)
            #if os(macOS)
            Menu {
                Picker(L10n.text("Sort By"), selection: $sort) {
                    ForEach(DownloadSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(sort.title)
            }
            .menuStyle(.button).buttonStyle(.borderless).fixedSize()
            .help(L10n.text("Sort By"))
            ReverseOrderButton(reversed: $reversed).accessibilityIdentifier("downloads.reverse")
            #else
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        Picker(L10n.text("Sort By"), selection: $sort) {
                            ForEach(DownloadSort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: {
                        FittingLabel(title: sort.title, symbol: "line.3.horizontal.decrease")
                    }
                    .controlButton()
                    .accessibilityLabel(L10n.text("Sort By"))
                    // Filled while the list runs the other way round.
                    ReverseOrderButton(reversed: $reversed).accessibilityIdentifier("downloads.reverse")
                }
            }
            .environment(\.glassControls, true)
            #endif
        }
    }

    #if os(macOS)
    /// The queue as Safari's downloads list: one grouped box of rows, with quiet text controls above it.
    private func queue(_ pending: [DownloadItem]) -> some View {
        let paused = pending.filter { $0.status == .paused || $0.status == .failed }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L10n.text("Caching")).font(.title3.weight(.semibold))
                Text("\(pending.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Menu {
                    Picker(L10n.text("At a Time"), selection: Binding(get: { library.simultaneous }, set: { library.simultaneous = $0 })) {
                        ForEach(1...4, id: \.self) { Text(L10n.text("%lld at a time", $0)).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(L10n.text("%lld at a time", library.simultaneous))
                }
                .menuStyle(.button).buttonStyle(.borderless).fixedSize()
                Divider().frame(height: 12)
                if paused.count == pending.count {
                    Button(L10n.text("Resume All")) { library.resumeAll() }.buttonStyle(.borderless)
                } else {
                    Button(L10n.text("Pause All")) { library.pauseAll() }.buttonStyle(.borderless)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(pending.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 70) }
                    QueueRow(item: item, rate: library.rates[item.id], position: queuePosition(item, in: pending))
                }
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)) }
        }
    }
    #else
    private func queue(_ pending: [DownloadItem]) -> some View {
        let paused = pending.filter { $0.status == .paused || $0.status == .failed }
        return VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            HStack(alignment: .center, spacing: 12) {
                SectionHeader(title: L10n.text("Caching")).fixedSize().layoutPriority(1)
                Text("\(pending.count)").font(.headline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Menu {
                    Picker(L10n.text("At a Time"), selection: Binding(get: { library.simultaneous }, set: { library.simultaneous = $0 })) {
                        ForEach(1...4, id: \.self) { Text(L10n.text("%lld at a time", $0)).tag($0) }
                    }
                } label: {
                    FittingLabel(title: L10n.text("%lld at a time", library.simultaneous), symbol: "square.stack.3d.down.right")
                }
                .controlButton()
                if paused.count == pending.count {
                    Button { library.resumeAll() } label: { FittingLabel(title: L10n.text("Resume All"), symbol: "play.fill") }.controlButton()
                } else {
                    Button { library.pauseAll() } label: { FittingLabel(title: L10n.text("Pause All"), symbol: "pause.fill") }.controlButton()
                }
            }
            VStack(spacing: DownloadMetrics.rowSpacing) {
                ForEach(pending) { item in
                    QueueRow(item: item, rate: library.rates[item.id], position: queuePosition(item, in: pending))
                }
            }
        }
        // Liquid Glass controls over the glass rows, as on the watch page.
        .environment(\.glassControls, true)
        .tvFocusSection()
    }
    #endif

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
        Picker(L10n.text("Offline Cache"), selection: $kind) {
            Text(L10n.text("Videos")).tag(DownloadsView.Kind.videos)
            Text(L10n.text("Music")).tag(DownloadsView.Kind.music)
        }
        .pickerStyle(.segmented).labelsHidden()
    }
}

enum DownloadMetrics {
    #if os(tvOS)
    static let thumb: CGFloat = 96, rowSpacing: CGFloat = 20
    /// The shows' cards, a show page's banner and its episode tiles.
    static let cardMin: CGFloat = 500, cardCorner: CGFloat = 20, banner: CGFloat = 520, episodeTile: CGFloat = 360
    #elseif os(macOS)
    static let thumb: CGFloat = 44, rowSpacing: CGFloat = 10
    static let cardMin: CGFloat = 280, cardCorner: CGFloat = 14, banner: CGFloat = 360, episodeTile: CGFloat = 200
    #else
    static let thumb: CGFloat = 46, rowSpacing: CGFloat = 10
    static let cardMin: CGFloat = 300, cardCorner: CGFloat = 16, banner: CGFloat = 280, episodeTile: CGFloat = 150
    #endif
}

/// How the downloaded shows are listed (#653).
enum DownloadSort: String, CaseIterable {
    /// Most recently finished first.
    case date
    case name
    /// Largest first.
    case size
    var title: String {
        switch self {
        case .date: L10n.text("Date Cached")
        case .name: L10n.text("Name")
        case .size: L10n.text("Size")
        }
    }
}

/// Finished episodes of one video from one source.
struct DownloadShow: Identifiable {
    let id: String
    let title: String
    let poster: URL?
    let posterHeaders: [String: String]
    let siteKey: String
    let videoID: String
    let sourceName: String
    let items: [DownloadItem]
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    /// When its last episode finished.
    var latest: Date { items.compactMap(\.finished).max() ?? .distantPast }
    /// The show a download belongs to: its video on its source.
    static func key(for item: DownloadItem) -> String { item.source.siteKey + "\u{1F}" + item.source.videoID }
    /// The video's key in `TMDBMatchStore`, as its page has it.
    var tmdbKey: String { TMDBMatchStore.key(source: siteKey, video: videoID) }
    /// Episodes in the order the source lists them; the shows by `sort` (most recently finished first by default), or
    /// the other way round.
    static func group(_ items: [DownloadItem], by sort: DownloadSort = .date, reversed: Bool = false) -> [DownloadShow] {
        let groups = Dictionary(grouping: items, by: key(for:))
        let shows = groups.map { key, items in
            let first = items[0]
            return DownloadShow(id: key, title: first.title, poster: first.poster, posterHeaders: first.posterHeaders,
                                siteKey: first.source.siteKey, videoID: first.source.videoID, sourceName: first.source.siteName,
                                items: items.sorted { $0.episode.localizedStandardCompare($1.episode) == .orderedAscending })
        }
        // The id breaks ties, so shows of one name or size keep their places between updates.
        let sorted = shows.sorted { a, b in
            switch sort {
            case .date: if a.latest != b.latest { return a.latest > b.latest }
            case .name:
                let order = a.title.localizedStandardCompare(b.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .size: if a.size != b.size { return a.size > b.size }
            }
            return a.id < b.id
        }
        return reversed ? sorted.reversed() : sorted
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
        EmptyPage(symbol: "arrow.down", title: L10n.text("Nothing Cached"),
                  message: L10n.text("Choose Cache on a video's page to keep episodes for watching offline."),
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
                Text(L10n.text("used by the cache")).font(.subheadline).foregroundStyle(.secondary)
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
                    legend(Brand.cyan, L10n.text("Offline Cache"), downloads)
                    legend(Color.primary.opacity(0.28), L10n.text("Other"), other)
                    legend(Color.primary.opacity(0.12), L10n.text("Free"), free)
                }
                .font(.caption)
            }
            #if os(tvOS)
            Text(L10n.text("tvOS may remove cached videos when Apple TV runs low on storage.")).font(.caption).foregroundStyle(.secondary)
            #endif
        }
        .padding(DownloadMetrics.thumb > 60 ? 28 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel(cornerRadius: 22)
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
        #if os(macOS)
        macRow.contextMenu { menu }
        #else
        regularRow.contextMenu { menu }
        #endif
    }

    @ViewBuilder private var menu: some View {
        if item.status == .queued, (position ?? 1) > 1 {
            Button(L10n.text("Cache Next"), systemImage: "arrow.up.to.line") { library.prioritize(item.id) }
        }
        Button(L10n.text("Cancel Caching"), systemImage: "xmark", role: .destructive) { library.remove([item.id]) }
    }

    #if os(macOS)
    /// A row of the grouped queue, as in Safari's downloads: the title, then the episode and quality, a thin bar,
    /// the numbers, and small round controls.
    private var macRow: some View {
        let detail = [item.episode == item.title ? nil : item.episode, item.quality].compactMap { $0?.isEmpty == false ? $0 : nil }
        let tint = item.status == .failed ? Brand.rose : item.status == .paused || item.status == .queued ? Color.secondary : Brand.accent
        return HStack(spacing: 14) {
            Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 40)
                .overlay { PosterImage(url: item.poster, headers: item.posterHeaders) }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)) }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.body.weight(.semibold)).lineLimit(1).help(item.title)
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { proxy in
                    Capsule().fill(Color.primary.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: max(item.fraction > 0 ? 4 : 0, proxy.size.width * item.fraction))
                        }
                }
                .frame(height: 4).padding(.vertical, 2)
                .animation(.smooth, value: item.fraction)
                .accessibilityHidden(true)
                Text(status(compact: false)).font(.caption).monospacedDigit().lineLimit(1)
                    .foregroundStyle(item.status == .failed ? AnyShapeStyle(Brand.rose) : AnyShapeStyle(.secondary))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                switch item.status {
                case .paused, .failed:
                    roundControl(item.status == .failed ? "arrow.clockwise.circle.fill" : "play.circle.fill",
                                 L10n.text(item.status == .failed ? "Retry" : "Resume")) { library.resume(item.id) }
                case .finishing, .queued: EmptyView()
                default:
                    roundControl("pause.circle.fill", L10n.text("Pause")) { library.pause(item.id) }
                }
                roundControl("xmark.circle.fill", L10n.text("Cancel Caching")) { library.remove([item.id]) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func roundControl(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 22)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
    #endif

    private var regularRow: some View {
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
                control("xmark", L10n.text("Cancel Caching")) { library.remove([item.id]) }
            }
        }
        .padding(DownloadMetrics.thumb > 60 ? 18 : 12)
        .contentPanel(cornerRadius: 18)
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
        case .failed: return item.failure ?? L10n.text("Caching failed")
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

/// A control's title and symbol, or the symbol alone where the row has no room for both (a phone held upright).
private struct FittingLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Label(title, systemImage: symbol).lineLimit(1).fixedSize()
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
    }
}

/// 倒序 (#653): turns a list of downloads the other way round. Filled while it is (white, as a chosen chip, on Apple TV).
struct ReverseOrderButton: View {
    @Binding var reversed: Bool
    var body: some View {
        Button { reversed.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down")
                #if os(macOS)
                .foregroundStyle(reversed ? Brand.accent : Color.secondary)
                .frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())
                #endif
        }
        #if os(macOS)
        .buttonStyle(.borderless)
        #elseif os(tvOS)
        .glassPill(selected: reversed)
        #else
        .controlButton(prominent: reversed)
        #endif
        .help(L10n.text("Reverse Order"))
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversed ? .isSelected : [])
    }
}

extension View {
    /// A show's card: on Apple TV the whole card lifts with a glass rim, elsewhere it presses like other cards.
    @ViewBuilder fileprivate func downloadCardButton() -> some View {
        #if os(tvOS)
        panelCardButton(cornerRadius: DownloadMetrics.cardCorner)
        #else
        cardButton()
        #endif
    }
}

/// TMDB's pictures and facts for the downloaded shows (#653). First the match the video's page found, kept on this
/// device however old it is, so it shows offline too; or the work the viewer picked on that page. A show never looked
/// up is looked up once with what its download knows, one show at a time while the page is open. Shows TMDB doesn't
/// have, and sources it doesn't cover (short dramas, Bilibili), keep the source's cover.
@MainActor @Observable final class DownloadArtwork {
    static let shared = DownloadArtwork()
    struct Entry {
        let details: TMDBMatch.Details
        let numbering: TMDBMatch.Numbering
        let offset: Int
    }
    private(set) var entries: [String: Entry] = [:]
    /// Shows looked at in this run of the app, found or not.
    @ObservationIgnored private var tried: Set<String> = []

    func details(for show: DownloadShow) -> TMDBMatch.Details? { entries[show.tmdbKey]?.details }

    /// TMDB's episode for each of the show's downloads (by download id), where its season lines up.
    func episodes(of show: DownloadShow) -> [String: TMDBMatch.EpisodeInfo] {
        guard let entry = entries[show.tmdbKey], entry.details.season != nil else { return [:] }
        let mapped = entry.details.episodes(for: show.items.map(\.episode), numbering: entry.numbering, offset: entry.offset)
        var result: [String: TMDBMatch.EpisodeInfo] = [:]
        for (item, info) in zip(show.items, mapped) { result[item.id] = info }
        return result
    }

    /// The show's own pictures, for the episodes TMDB has no still for.
    func backdrops(for show: DownloadShow) -> [URL] {
        guard let details = details(for: show) else { return [] }
        if let stills = details.stills, !stills.isEmpty { return stills }
        return details.backdrop.map { [$0] } ?? []
    }

    func load(_ shows: [DownloadShow]) async {
        guard TMDBMatch.enabled else { return }
        for show in shows where !tried.contains(show.tmdbKey) {
            guard !Task.isCancelled else { return }
            let key = show.tmdbKey
            tried.insert(key)
            if let entry = await Self.resolve(show) {
                withAnimation(.smooth(duration: 0.35)) { entries[key] = entry }
            } else if Task.isCancelled {
                // The page closed during the lookup: try again when it opens.
                tried.remove(key)
            }
        }
    }

    private static func resolve(_ show: DownloadShow) async -> Entry? {
        guard !TMDBMatch.skipsSource(key: show.siteKey, api: "") else { return nil }
        let store = TMDBMatchStore.shared, key = show.tmdbKey
        // Answers the download's own lookup found, kept apart from the page's: the page asks with the source's
        // details (year, synopsis, every episode), and its answer wins once it has one.
        let own = "download|" + key
        let kept = await store.kept(for: key)
        if let choice = await store.choice(for: key) {
            guard case .work(let type, let id, let season) = choice,
                  let details = try? await TMDBMatch.details(type, id: id, season: season) else { return nil }
            return Entry(details: details, numbering: kept?.match?.numbering ?? kept?.numbering ?? .season, offset: 0)
        }
        if let entry = entry(kept) { return entry }
        // The page asked lately and TMDB has no single match for it: neither would this.
        if await store.answer(for: key) != nil { return nil }
        if let entry = entry(await store.kept(for: own)) { return entry }
        if await store.answer(for: own) != nil { return nil }
        var request = TMDBMatch.Request(video: Video(id: show.videoID, name: show.title),
                                        source: TMDBMatch.SourceRef(key: show.siteKey, name: show.sourceName))
        request.episodes = show.items.prefix(400).map { String($0.episode.prefix(60)) }
        guard !TMDBMatch.labeledNotOnTMDB(request) else { return nil }
        do {
            let answer = try await TMDBMatch.lookup(request) { _ in }
            await store.save(answer, for: own)
            return entry(answer)
        } catch {
            if !Task.isCancelled { Diagnostics.shared.record(.warning, "tmdb", "download lookup failed: \(error.localizedDescription)") }
            return nil
        }
    }

    private static func entry(_ answer: TMDBMatch.Answer?) -> Entry? {
        guard let answer, answer.status == .matched, let details = answer.details else { return nil }
        return Entry(details: details, numbering: answer.match?.numbering ?? answer.numbering,
                     offset: answer.match.flatMap { $0.id == details.id ? $0.offset : nil } ?? 0)
    }
}

/// A downloaded show on the Downloads page: its picture with TMDB's logo over it, then the name and what is saved.
private struct DownloadShowCard: View {
    let show: DownloadShow
    let details: TMDBMatch.Details?
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DownloadMetrics.cardCorner, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { DownloadShowArt(show: show, details: details) }
                .overlay(alignment: .topTrailing) { if show.items.count > 1 { badge } }
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.12)) }
            VStack(alignment: .leading, spacing: 3) {
                Text(details?.name ?? show.title).font(.headline).lineLimit(1)
                Text(caption).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "2024 · 剧情 · 玩偶 · 4.2 GB": TMDB's year and genre, then the source and the space it takes.
    private var caption: String {
        let facts = details.map { [$0.year.map(String.init), $0.genres.first].compactMap { $0 } } ?? []
        return (facts + [SourceLabel(show.sourceName).text, DownloadFormat.size(show.size)]).joined(separator: " · ")
    }

    private var badge: some View {
        Text(L10n.text("%lld episodes", show.items.count))
            .font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 5)
            #if os(tvOS)
            .background(.black.opacity(0.55), in: Capsule())
            #else
            .glassSurface(.regular, in: Capsule())
            #endif
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
            .padding(DownloadMetrics.cardCorner * 0.5)
    }
}

/// A show's picture: TMDB's backdrop with its logo, else the source's cover centred on a blur of itself, which also
/// stands under the backdrop until it is in (or when it can't load, offline).
private struct DownloadShowArt: View {
    let show: DownloadShow
    let details: TMDBMatch.Details?
    @State private var logoAspect: CGFloat?
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.12)
                PosterImage(url: show.poster, headers: show.posterHeaders)
                    .frame(width: size.width, height: size.height).clipped()
                    .blur(radius: 30).scaleEffect(1.3)
                    .overlay(Color.black.opacity(0.3))
                if let backdrop = details?.backdrop {
                    TMDBArtwork(url: backdrop, maxPixels: 1280).frame(width: size.width, height: size.height).clipped()
                } else {
                    let height = size.height * 0.84
                    PosterImage(url: show.poster, headers: show.posterHeaders)
                        .frame(width: height * 2 / 3, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                        .frame(width: size.width, height: size.height)
                }
                if let logo = details?.logo {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    // Wide logos get a width limit, tall ones a height limit.
                    let aspect = max(logoAspect ?? 3, 0.5)
                    let width = min(size.width * 0.5, size.height * 0.3 * aspect)
                    TMDBArtwork(url: logo, maxPixels: 600, fill: false, aspect: $logoAspect)
                        .frame(width: width, height: width / aspect)
                        .opacity(logoAspect == nil ? 0 : 1)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                        .padding(size.width * 0.045)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One downloaded show (#653): TMDB's banner (one made from the cover when TMDB doesn't have it), its story, and the
/// saved episodes as tiles with TMDB's stills and titles, in the source's order or, with 倒序, the other way round.
struct DownloadShowPage: View {
    let id: String
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("downloads.episodesReversed") private var reversed = false
    @State private var deleting = false
    @State private var coverAspect: CGFloat?
    private var library: DownloadLibrary { .shared }
    private var artwork: DownloadArtwork { .shared }

    var body: some View {
        let show = DownloadShow.group(library.items.filter { $0.status == .completed && DownloadShow.key(for: $0) == id }).first
        Group {
            if let show { content(show) } else { Color.clear }
        }
        .screenBackdrop()
        .screenTitle(show.map { artwork.details(for: $0)?.name ?? $0.title } ?? "")
        // Its last episode deleted: back to Downloads.
        .onChange(of: show == nil) { _, gone in if gone { dismiss() } }
        .task { if let show { await artwork.load([show]) } }
        .confirmationDialog(L10n.text("Delete all cached episodes of %@?", show?.title ?? ""), isPresented: $deleting, titleVisibility: .visible) {
            Button(L10n.text("Delete Cached Items"), role: .destructive) {
                if let show { library.remove(show.items.map(\.id)) }
            }
        }
    }

    private func content(_ show: DownloadShow) -> some View {
        let details = artwork.details(for: show)
        return ScrollView {
            VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
                VStack(alignment: .leading, spacing: Layout.headerSpacing) {
                    banner(show, details)
                    // Under TMDB's banner: what is saved, then the story.
                    if let details {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(summary(show)).font(.subheadline.weight(.semibold)).monospacedDigit()
                            if !details.story.isEmpty {
                                Text(details.story).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                            }
                        }
                        .frame(maxWidth: TMDBBannerMetrics.textWidth, alignment: .leading)
                    }
                }
                .tvFocusSection()
                episodes(show, details)
            }
            .pageContainer()
        }
    }

    /// "玩偶 · 4 集 · 1.2 GB": the source, how many episodes are saved and the space they take.
    private func summary(_ show: DownloadShow) -> String {
        let count = show.items.count == 1 ? L10n.text("1 episode") : L10n.text("%lld episodes", show.items.count)
        return [SourceLabel(show.sourceName).text, count, DownloadFormat.size(show.size)].joined(separator: " · ")
    }

    @ViewBuilder private func banner(_ show: DownloadShow, _ details: TMDBMatch.Details?) -> some View {
        Group {
            if let details, let backdrop = details.backdrop {
                TMDBBanner(details: details, backdrop: backdrop, unmatched: "") { actions(show) }
            } else {
                PosterBanner(poster: show.poster, headers: show.posterHeaders, title: show.title, subtitle: summary(show), aspect: $coverAspect) {
                    actions(show)
                }
            }
        }
        .frame(height: DownloadMetrics.banner)
    }

    /// Play from the first episode, or delete them all: Liquid Glass over the banner.
    private func actions(_ show: DownloadShow) -> some View {
        HStack(spacing: 10) {
            if let first = show.items.first {
                Button { store.playing = library.channel(for: first) } label: {
                    Label(L10n.text("Play"), systemImage: "play.fill").lineLimit(1).fixedSize()
                }
                .controlButton(prominent: true)
            }
            Button(role: .destructive) { deleting = true } label: {
                Label(L10n.text("Delete Cached Items"), systemImage: "trash").lineLimit(1).fixedSize()
            }
            .controlButton()
        }
        .environment(\.glassControls, true)
    }

    private func episodes(_ show: DownloadShow, _ details: TMDBMatch.Details?) -> some View {
        let infos = artwork.episodes(of: show), backdrops = artwork.backdrops(for: show)
        let items = reversed ? Array(show.items.reversed()) : show.items
        return VStack(alignment: .leading, spacing: Layout.headerSpacing) {
            HStack(alignment: .center, spacing: 10) {
                SectionHeader(title: L10n.text("Episodes"))
                Text("\(show.items.count)").font(.headline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if details != nil { TMDBBadge() }
                ReverseOrderButton(reversed: $reversed)
                    .environment(\.glassControls, true)
                    .accessibilityIdentifier("downloads.episodes.reverse")
            }
            .tvFocusSection()
            // Not lazy, as on the Downloads page: the remote only moves to tiles that exist.
            EpisodeGrid(minimum: DownloadMetrics.episodeTile, spacing: Layout.gridSpacing, rowSpacing: Layout.gridRowSpacing).callAsFunction {
                ForEach(items) { item in tile(item, info: infos[item.id], backdrops: backdrops) }
            }
            .tvFocusSection()
        }
    }

    private func tile(_ item: DownloadItem, info: TMDBMatch.EpisodeInfo?, backdrops: [URL]) -> some View {
        let detail = [item.quality, DownloadFormat.size(item.size)].compactMap { $0 }.joined(separator: " · ")
        return Button { store.playing = library.channel(for: item) } label: {
            TMDBEpisodeTile(name: EpisodeRow.title(item.episode), info: info, detail: detail, width: nil, backdrops: backdrops)
        }
        .cardButton()
        .accessibilityLabel(L10n.text("Play %@", item.episode))
        .contextMenu {
            Button(L10n.text("Delete from Cache"), systemImage: "trash", role: .destructive) { library.remove([item.id]) }
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
        // SwiftUI can ask for the size at an unbounded width (.infinity), not only an unspecified one; Int(_:)
        // in columns(_:) traps on that (TestFlight crash on iPad, build 44, opening Downloads).
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimum
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
            .accessibilityLabel(L10n.text("Cached"))
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
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent).accessibilityLabel(L10n.text("Cached"))
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(Brand.rose).accessibilityLabel(L10n.text("Caching failed"))
            case .downloading, .finishing:
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.03, fraction)).stroke(Brand.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: size, height: size)
                .accessibilityLabel(L10n.text("Caching"))
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
    #if os(macOS)
    /// The checklist's natural height, so the sheet fits a few episodes instead of a fixed, mostly empty box.
    @State private var listHeight: CGFloat = 0
    var body: some View { macBody.task { await library.measure() } }
    #else
    var body: some View { regularBody }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: DownloadMetrics.thumb * 1.2)
                    .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Cache Episodes")).font(.title2.weight(.bold))
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
                downloadButton
            }
            // A full-width focus section: the buttons sit at the right, out of line with most episodes,
            // and the remote only finds them moving down when the whole row takes focus.
            .tvFocusSection()
        }
        .padding(DownloadMetrics.thumb > 60 ? 60 : 22)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(maxWidth: 1300).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Backdrop() }
        #endif
        .task { await library.measure() }
    }
    #endif

    private var downloadButton: some View {
        Button {
            let chosen = episodes.filter { selection.contains($0.id) }
            for episode in chosen { library.download(source(episode), title: video.name, poster: video.poster, posterHeaders: video.posterHeaders) }
            added(chosen.count)
            dismiss()
        } label: {
            Label(selection.isEmpty ? L10n.text("Cache") : L10n.text("Cache %lld", selection.count), systemImage: "arrow.down.circle.fill")
        }
        .controlButton(prominent: true).disabled(selection.isEmpty)
    }

    #if os(macOS)
    /// A compact header, the episodes as a checklist that grows with them up to a scrolling height, and a footer
    /// with Select All beside Cancel and Download (Esc and Return).
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 44)
                    .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.1)) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Cache Episodes")).font(.title3.weight(.semibold))
                    Text(video.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(macSubtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            Divider()
            ScrollView {
                macChecklist
                    .padding(16)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 56), 380))
            Divider()
            HStack(spacing: 10) {
                Toggle(L10n.text("Select All"), isOn: Binding(
                    get: { !available.isEmpty && available.allSatisfy { selection.contains($0.id) } },
                    set: { selection = $0 ? Set(available.map(\.id)) : [] }))
                .toggleStyle(.checkbox)
                .disabled(available.isEmpty)
                if let free = library.usage.available {
                    Text(L10n.text("%@ free", DownloadFormat.size(free))).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                        .lineLimit(1).fixedSize()
                }
                Spacer(minLength: 12)
                // Liquid Glass, as the sheet's own surface is.
                Button(L10n.text("Cancel")) { dismiss() }.controlButton().keyboardShortcut(.cancelAction)
                downloadButton.keyboardShortcut(.defaultAction)
            }
            .environment(\.glassControls, true)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 540)
    }

    /// The line's name and how many episodes it has.
    private var macSubtitle: String {
        let count = episodes.count == 1 ? L10n.text("1 episode") : L10n.text("%lld episodes", episodes.count)
        return flag.isEmpty ? count : SourceLabel(flag).text + " · " + count
    }

    /// Short names (第1集, EP01) as a grid of chips; long ones (a film's full title) as a list, one per row.
    @ViewBuilder private var macChecklist: some View {
        if episodes.allSatisfy({ $0.name.count <= 10 }) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(episodes) { episode in macChip(episode) }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                    if index > 0 { Divider().padding(.leading, 40) }
                    macRow(episode)
                }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)) }
        }
    }

    private func macRow(_ episode: Episode) -> some View {
        let existing = library.item(for: source(episode))
        let locked = existing.map { $0.status != .failed } ?? false
        let selected = selection.contains(episode.id)
        return Button { toggle(episode) } label: {
            HStack(spacing: 10) {
                checkmark(selected: selected, locked: locked)
                Text(episode.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(locked ? .secondary : .primary)
                Spacer(minLength: 8)
                if let existing, locked { stateLabel(existing) }
            }
            .padding(.horizontal, 12).frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(episode.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func macChip(_ episode: Episode) -> some View {
        let existing = library.item(for: source(episode))
        let locked = existing.map { $0.status != .failed } ?? false
        let selected = selection.contains(episode.id)
        return Button { toggle(episode) } label: {
            HStack(spacing: 6) {
                checkmark(selected: selected, locked: locked)
                Text(episode.name).lineLimit(1).foregroundStyle(locked ? .secondary : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(selected ? Brand.accent.opacity(0.16) : Color.primary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Brand.accent.opacity(0.5) : Color.primary.opacity(0.06))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help(existing.flatMap { locked ? ($0.status == .completed ? L10n.text("Cached") : L10n.text("In Queue")) : nil } ?? episode.name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Downloaded or queued episodes show the download mark instead of a box to tick.
    private func checkmark(selected: Bool, locked: Bool) -> some View {
        Image(systemName: locked ? "arrow.down.circle.fill" : selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(locked ? AnyShapeStyle(.tertiary) : selected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            .frame(width: 18)
    }

    private func stateLabel(_ item: DownloadItem) -> some View {
        Text(item.status == .completed ? L10n.text("Cached") : L10n.text("In Queue"))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
    }

    private func toggle(_ episode: Episode) {
        if selection.contains(episode.id) { selection.remove(episode.id) } else { selection.insert(episode.id) }
    }
    #endif

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
                    Text(existing.status == .completed ? L10n.text("Cached") : L10n.text("In Queue")).font(.caption).foregroundStyle(.secondary)
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

/// Downloads keep going after the app leaves the screen. On iOS 26 and later a continued-processing task keeps
/// them running until the queue is empty (see `ContinuedDownloads`). Otherwise, or when the system ends that task,
/// they get the usual short grace period, then stop and resume when the app returns.
@MainActor enum DownloadsLifecycle {
    #if !os(macOS)
    private static var task: UIBackgroundTaskIdentifier = .invalid
    static func install() {
        #if os(iOS)
        DownloadLibrary.shared.onStart = { started() }
        MusicDownloadLibrary.shared.onStart = { started() }
        #endif
    }
    static func enteredBackground() {
        guard hasWork, task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: "Downloads") {
            if !continuing { suspend() }
            end()
        }
    }
    static func becameActive() {
        end()
        DownloadLibrary.shared.wake()
        MusicDownloadLibrary.shared.wake()
        started()
    }
    static var hasWork: Bool {
        DownloadLibrary.shared.items.contains(where: \.isActive) || MusicDownloadLibrary.shared.items.contains(where: \.isActive)
    }
    private static func suspend() {
        DownloadLibrary.shared.suspend()
        MusicDownloadLibrary.shared.suspend()
    }
    private static func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
    /// A download started or the app came back: ask for a continued-processing task while the app is open.
    private static func started() {
        #if os(iOS)
        if #available(iOS 26.0, *) { ContinuedDownloads.begin() }
        #endif
    }
    private static var continuing: Bool {
        #if os(iOS)
        if #available(iOS 26.0, *) { return ContinuedDownloads.isRunning }
        #endif
        return false
    }
    /// The continued-processing task ended: the queue emptied, or the system (or the person, from its progress)
    /// stopped it. Off screen, stop as the grace period's end would.
    static func continuedEnded(expired: Bool) {
        guard UIApplication.shared.applicationState != .active else { return }
        if expired { suspend() }
        end()
    }
    #endif
}

#if os(iOS)
/// iOS 26 lets an app keep work a person started running in the background, as a continued-processing task whose
/// progress the system shows on the Lock Screen and in the Dynamic Island. The task can only be asked for while the
/// app is open, so it starts with the first download and follows every download (videos and songs) until the queue
/// is empty. When the system ends it early, the downloads stop as before and carry on when the app comes back.
@available(iOS 26.0, *)
@MainActor enum ContinuedDownloads {
    private static var task: BGContinuedProcessingTask?
    /// When a request was submitted and its task hasn't started yet.
    private static var submitted: Date?
    /// Downloads this task has followed, for its progress: finished, paused or removed ones count as done.
    private static var followed: Set<String> = []
    private static var subtitle = ""
    private static var follower: Task<Void, Never>?

    static var isRunning: Bool { task != nil }

    static func begin() {
        guard task == nil, submitted.map({ Date().timeIntervalSince($0) > 10 }) ?? true,
              UIApplication.shared.applicationState == .active, let name = current() else { return }
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.tvbox.yingxia").downloads.\(UUID().uuidString)"
        // Each request has its own identifier, registered just before it is submitted (allowed for this kind of task).
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { run(task) }
        }
        guard registered else {
            Diagnostics.shared.record(.warning, "download", "continued task not permitted")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: L10n.text("Caching"), subtitle: name)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            submitted = Date()
        } catch {
            Diagnostics.shared.record(.warning, "download", "continued task refused \(error)")
        }
    }

    private static func run(_ started: BGTask) {
        submitted = nil
        guard let started = started as? BGContinuedProcessingTask else { started.setTaskCompleted(success: false); return }
        guard task == nil, let name = current() else { started.setTaskCompleted(success: true); return }
        task = started
        followed = []
        subtitle = name
        started.expirationHandler = { Task { @MainActor in expire() } }
        Diagnostics.shared.record(.info, "download", "continued task started")
        follower = Task {
            while !Task.isCancelled, follow() {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Reports progress; false, after ending the task, once nothing is left to download.
    private static func follow() -> Bool {
        guard let task else { return false }
        var fractions: [String: Double] = [:]
        for item in DownloadLibrary.shared.items where item.status == .queued || item.isActive { fractions["v" + item.id] = item.fraction }
        for item in MusicDownloadLibrary.shared.items where item.status == .queued || item.isActive { fractions["m" + item.id] = item.fraction }
        guard !fractions.isEmpty else {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            finish(success: true)
            DownloadsLifecycle.continuedEnded(expired: false)
            return false
        }
        followed.formUnion(fractions.keys)
        let done = followed.reduce(0.0) { $0 + (fractions[$1] ?? 1) }
        task.progress.totalUnitCount = Int64(followed.count) * 1000
        task.progress.completedUnitCount = Int64(done * 1000)
        if let name = current(), name != subtitle {
            subtitle = name
            task.updateTitle(L10n.text("Caching"), subtitle: name)
        }
        return true
    }

    private static func expire() {
        guard task != nil else { return }
        Diagnostics.shared.record(.info, "download", "continued task expired")
        finish(success: false)
        DownloadsLifecycle.continuedEnded(expired: true)
    }

    private static func finish(success: Bool) {
        follower?.cancel(); follower = nil
        task?.setTaskCompleted(success: success)
        task = nil
    }

    /// The download running now (else the next one waiting), as the progress names it.
    private static func current() -> String? {
        let videos = DownloadLibrary.shared.items, songs = MusicDownloadLibrary.shared.items
        if let item = videos.first(where: \.isActive) ?? videos.first(where: { $0.status == .queued }) {
            return item.episode.isEmpty ? item.title : "\(item.title) · \(item.episode)"
        }
        return (songs.first(where: \.isActive) ?? songs.first(where: { $0.status == .queued }))?.track.title
    }
}
#endif
