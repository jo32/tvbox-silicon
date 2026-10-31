import SwiftUI
import TVCore

struct SitesView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    /// Groups the viewer folded. Every group starts open, subscriptions and hidden sources included,
    /// so nothing on the page needs finding. Reset with the page, not with a pushed source: the state
    /// lives here and `prepared` keeps the reset to once per visit.
    @State private var collapsed: Set<String> = []
    @State private var prepared = false
    /// The fold as it was when a search began; restored when the search is cleared.
    @State private var foldBeforeSearch: Set<String>?
    @State private var arranging = false
    var body: some View {
        Group {
            if let config = store.subscription {
                let groups = store.sourceGroups(includeHidden: false).filtered(by: query)
                let sites = store.orderedSites(config)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        if query.isEmpty && sites.count > 1 {
                            SourceOrderCard(sites: sites) { arranging = true }.tvFocusSection()
                        }
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.id) {
                                LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                                    ForEach(group.sites) { site in
                                        RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, dimmed: group.kind == .hidden) }.tileButton()
                                            .contextMenu {
                                                PinSourceButton(site: site, origin: config.origin)
                                                HideSourceButton(site: site, origin: config.origin)
                                                if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                                            }
                                    }
                                }
                                // Unfolds from under its header; folding only fades, as the groups below slide up.
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
                            }
                        }
                    }.pageContainer()
                }
                .sheet(isPresented: $arranging) { SourceOrderEditor(sites: sites, automatic: store.automaticSites(config)) }
                #if DEBUG
                // `-qaArrangeSources 1` opens the editor for screenshots.
                .task {
                    guard UserDefaults.standard.bool(forKey: "qaArrangeSources") else { return }
                    store.setCustomSourceOrder(true)
                    // Let launch settle first: on tvOS a sheet asked for straight away never appeared.
                    try? await Task.sleep(for: .seconds(2))
                    arranging = true
                }
                #endif
            } else { ContentUnavailableView(L10n.text("No Sources Yet"), systemImage: "square.grid.2x2", description: Text(L10n.text("Add a TVBox subscription in Settings."))) }
        }
        .screenBackdrop()
        .catalogSearchable(text: $query, prompt: L10n.text("Find a source")).tabTitle(L10n.text("Sources"))
        .task(id: store.section) {
            if store.section == .sites && !prepared {
                applyDefaultFold()
                prepared = true
            }
        }
        .onChange(of: store.section) { _, new in
            if new != .sites { prepared = false }
        }
        .onChange(of: query) { old, new in
            if old.isEmpty && !new.isEmpty {
                foldBeforeSearch = collapsed
                collapsed = []
            } else if !old.isEmpty && new.isEmpty, let saved = foldBeforeSearch {
                collapsed = saved
                foldBeforeSearch = nil
            }
        }
    }

    @ViewBuilder
    private func groupHeader(_ group: SourceGroup) -> some View {
        let open = !collapsed.contains(group.id)
        let header = Button {
            withAnimation(.snappy(duration: 0.3)) {
                if open { collapsed.insert(group.id) } else { collapsed.remove(group.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(L10n.text(group.title)).font(.headline).lineLimit(1)
                Text("\(group.sites.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // One chevron that turns, rather than two symbols swapped.
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("sources.group." + group.id)
        #if !os(tvOS)
        if case .subscription = group.kind, query.isEmpty {
            header
                .draggable(group.id)
                .dropDestination(for: String.self) { items, _ in
                    guard query.isEmpty, let address = items.first else { return false }
                    store.moveSourceGroup(address, onto: group.id, includeHidden: false)
                    return true
                }
        } else {
            header
        }
        #else
        header
        #endif
    }

    /// The default view of the page: every group open.
    private func applyDefaultFold() {
        collapsed = []
        foldBeforeSearch = nil
    }
}

private extension Array where Element == SourceGroup {
    /// Sites whose name contains the query, ignoring case; groups left empty drop out.
    func filtered(by query: String) -> [SourceGroup] {
        guard !query.isEmpty else { return self }
        return compactMap { group in
            var kept = group
            kept.sites = group.sites.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return kept.sites.isEmpty ? nil : kept
        }
    }
}

extension Store {
    /// How a source has been answering lately; see `SourceHealth`.
    func health(of site: Site) -> SourceHealth.Status {
        subscription.map { SourceHealth.shared.status(site, origin: $0.origin) } ?? .unknown
    }
}

extension SourceHealth.Status {
    /// The dot that marks it; none until the source has been asked.
    var tint: Color? {
        switch self {
        case .unknown: nil
        case .healthy: .green
        case .unstable: Brand.amber
        case .failing: Brand.rose
        }
    }
    /// Only trouble: in search results every listed source has just answered.
    var warning: Color? { self == .unstable || self == .failing ? tint : nil }
    var summary: String {
        switch self {
        case .unknown: ""
        case .healthy: L10n.text("Responding normally")
        case .unstable: L10n.text("Slow or unreliable lately")
        case .failing: L10n.text("Failing; skipped in search for now")
        }
    }
}

/// A source's health as a dot beside its name.
struct SourceHealthDot: View {
    let status: SourceHealth.Status
    #if os(tvOS)
    private let size: CGFloat = 14
    #else
    private let size: CGFloat = 8
    #endif
    var body: some View {
        if let tint = status.tint {
            Image(systemName: "circle.fill").font(.system(size: size)).foregroundStyle(tint).accessibilityLabel(status.summary)
        }
    }
}

/// A source as an app-icon tile plus its name: the name's emoji becomes the icon, its taglines
/// ("不卡", "秒播") and engine a quiet second line, so a page of sources reads like a launcher
/// rather than a wall of identical badges. Use with `tileButton()`: on tvOS the card lights up itself.
struct SiteCard: View {
    @Environment(Store.self) private var store
    @Environment(\.isFocused) private var isFocused
    let site: Site
    /// A source the viewer hid, shown only while hidden sources are revealed.
    var dimmed = false
    /// The pin badge on the icon; off in Watch Now's Pinned Sources, where every card is pinned.
    var marksPinned = true
    #if os(tvOS)
    private var focused: Bool { isFocused }
    private let icon: CGFloat = 88, padding: CGFloat = 20, radius: CGFloat = 28
    #else
    private let icon: CGFloat = 48, padding: CGFloat = 12, radius: CGFloat = 16
    // Keyboard focus on the Mac must not turn the text black on a dark panel.
    private let focused = false
    #endif
    var body: some View {
        let label = SourceLabel(site.name)
        let pinned = marksPinned && (store.subscription.map { store.pinnedSources.contains(site, origin: $0.origin) } ?? false)
        let runs = site.isBuiltIn || site.canBrowse(jarURL: store.subscription?.spiderURL)
        let detail = runs ? (label.parts.dropFirst() + [engine].compactMap { $0 }).joined(separator: " · ") : site.compatibility
        HStack(spacing: padding) {
            SourceIcon(site: site, label: label, size: icon)
                .opacity(runs ? 1 : 0.45)
                // A badge on the icon, not another line, so pinned cards keep the grid's height.
                .overlay(alignment: .bottomTrailing) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: icon * 0.18, weight: .bold)).foregroundStyle(Brand.onAccent)
                            .frame(width: icon * 0.36, height: icon * 0.36).background(Brand.accent, in: Circle())
                            .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1) }
                            .offset(x: icon * 0.1, y: icon * 0.1)
                            .accessibilityLabel(L10n.text("Pinned"))
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label.parts[0]).font(.headline).lineLimit(1)
                        .foregroundStyle(focused ? Color.black : runs ? Color.primary : Color.secondary)
                    if runs { SourceHealthDot(status: store.health(of: site)) }
                    if dimmed { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !detail.isEmpty {
                    Text(detail).font(.subheadline).lineLimit(1)
                        .foregroundStyle(focused ? Color.black.opacity(0.6) : runs ? Color.secondary : Brand.amber)
                }
            }
            Spacer(minLength: 0)
            #if !os(tvOS)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            #endif
        }
        .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        .background { TileSurface(focused: focused, radius: radius) }
        .accessibilityElement(children: .combine)
        .opacity(dimmed ? 0.45 : 1)
    }

    /// Which engine runs a source is an implementation detail; only built-in sources say so.
    private var engine: String? { site.isBuiltIn ? L10n.text("Built-in") : nil }
}

/// A launcher tile's own surface (source cards, live playlists).
struct TileSurface: View {
    var focused: Bool
    var radius: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if os(tvOS)
        // Like the system's focused buttons: a quiet tile at rest, a bright plate under focus.
        shape.fill(focused ? Color.white : Color.white.opacity(0.07))
            .overlay { shape.strokeBorder(.white.opacity(focused ? 0 : 0.06), lineWidth: 1) }
        #else
        Color.clear.contentPanel(cornerRadius: radius)
        #endif
    }
}

/// A source's icon: Bilibili's own mark, otherwise a `MonogramIcon`.
struct SourceIcon: View {
    let site: Site
    let label: SourceLabel
    var size: CGFloat
    var body: some View {
        if site.isBilibili { BilibiliMark(size: size) } else {
            MonogramIcon(seed: site.name, label: label, size: size, systemImage: site.key == Hongguo.siteKey ? "play.rectangle.fill" : nil)
        }
    }
}

/// The emoji a name starts with (or its first character, or a symbol) on a tile whose colour is
/// derived from the name, so neighbours differ.
struct MonogramIcon: View {
    let seed: String
    let label: SourceLabel
    var size: CGFloat
    var systemImage: String?
    private static let tints: [Color] = [
        Brand.indigo, Brand.amber, Brand.rose,
        Color(red: 0.30, green: 0.66, blue: 0.60), Color(red: 0.42, green: 0.56, blue: 0.92),
        Color(red: 0.62, green: 0.48, blue: 0.88), Color(red: 0.52, green: 0.72, blue: 0.38),
    ]
    var body: some View {
        // A stable hash: `hashValue` changes every launch.
        let tint = Self.tints[seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.tints.count]
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let systemImage {
                // Sized by frame rather than font: font-sized symbols sit off-center (baseline/ascent padding) before macOS 26.
                Image(systemName: systemImage).resizable().scaledToFit().fontWeight(.semibold)
                    .frame(width: size * 0.46, height: size * 0.46).foregroundStyle(.white)
            } else if let symbol = label.symbol {
                Text(symbol).font(.system(size: size * 0.5))
            } else {
                Text(String(label.parts[0].prefix(1)).uppercased()).font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size, alignment: .center)
        .background(LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

struct PinSourceButton: View {
    @Environment(Store.self) private var store
    let site: Site
    let origin: URL
    var body: some View {
        let pinned = store.pinnedSources.contains(site, origin: origin)
        Button { store.pinnedSources.toggle(site, origin: origin) } label: {
            Label(L10n.text(pinned ? "Unpin source" : "Pin source"), systemImage: pinned ? "pin.slash" : "pin")
        }.accessibilityIdentifier("source.pin." + site.key)
    }
}

struct HideSourceButton: View {
    @Environment(Store.self) private var store
    let site: Site
    let origin: URL
    var body: some View {
        let hidden = store.hiddenSources.contains(site, origin: origin)
        Button { store.hiddenSources.toggle(site, origin: origin) } label: {
            Label(L10n.text(hidden ? "Unhide Source" : "Hide Source"), systemImage: hidden ? "eye" : "eye.slash")
        }.accessibilityIdentifier("source.hide." + site.key)
    }
}

/// Context-menu moves within the viewer's own source order.
struct MoveSourceButtons: View {
    @Environment(Store.self) private var store
    let site: Site
    let sites: [Site]
    var body: some View {
        if let index = sites.firstIndex(where: { $0.id == site.id }) {
            if index > 0 {
                Button { store.moveSource(site, to: 0) } label: { Label(L10n.text("Move to Top"), systemImage: "arrow.up.to.line") }
            }
            if index < sites.count - 1 {
                Button { store.moveSource(site, to: sites.count) } label: { Label(L10n.text("Move to Bottom"), systemImage: "arrow.down.to.line") }
            }
        }
    }
}

/// The Sources page's header: the switch for the viewer's own order (`SourceOrder`), the top of
/// that order at a glance, and the way into arranging it.
struct SourceOrderCard: View {
    @Environment(Store.self) private var store
    let sites: [Site]
    let arrange: () -> Void
    private var enabled: Binding<Bool> {
        Binding { store.sourceOrder.enabled } set: { on in withAnimation(.smooth) { store.setCustomSourceOrder(on) } }
    }
    private var detail: String {
        L10n.text(store.sourceOrder.enabled ? "Sources at the top are searched first, and their results are listed first."
                                            : "Yingxia searches quick, reliable sources first.")
    }
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 8) {
            TVSettingsToggle(title: L10n.text("Custom Search Order"), detail: detail, isOn: enabled)
                .accessibilityIdentifier("sources.order.toggle")
            if store.sourceOrder.enabled {
                Button(action: arrange) {
                    TVSettingsRowLabel(title: L10n.text("Arrange Sources"), chevron: true) { SourceOrderPreview(sites: sites) }
                }
                .glassRow()
                .accessibilityIdentifier("sources.order.arrange")
            }
        }
        #else
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "arrow.up.arrow.down", tint: Brand.indigo, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Custom Search Order")).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle(L10n.text("Custom Search Order"), isOn: enabled).labelsHidden().toggleStyle(.switch).settingsSwitch()
                    .accessibilityIdentifier("sources.order.toggle")
            }
            if store.sourceOrder.enabled {
                Divider()
                HStack(spacing: 12) {
                    // As many icons as fit beside the button.
                    ViewThatFits(in: .horizontal) {
                        SourceOrderPreview(sites: sites, limit: 5)
                        SourceOrderPreview(sites: sites, limit: 4)
                        SourceOrderPreview(sites: sites, limit: 3)
                    }
                    Spacer(minLength: 8)
                    Button(action: arrange) {
                        Label(L10n.text("Arrange"), systemImage: "arrow.up.arrow.down")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.onAccent)
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Brand.accent, in: Capsule())
                    }
                    .buttonStyle(LiftButtonStyle())
                    .accessibilityIdentifier("sources.order.arrange")
                }
            }
        }
        .padding(16)
        .contentPanel(cornerRadius: 22)
        #endif
    }
}

/// The first sources of an order, as numbered icons.
struct SourceOrderPreview: View {
    let sites: [Site]
    var limit = 5
    #if os(tvOS)
    private let size: CGFloat = 44
    #else
    private let size: CGFloat = 30
    #endif
    var body: some View {
        let shown = Array(sites.prefix(limit))
        HStack(spacing: size * 0.32) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, site in
                SourceIcon(site: site, label: SourceLabel(site.name), size: size)
                    .overlay(alignment: .topLeading) {
                        SourceRankBadge(rank: index + 1, size: size * 0.52).offset(x: -size * 0.18, y: -size * 0.18)
                    }
            }
            if sites.count > shown.count {
                Text(verbatim: "+\(sites.count - shown.count)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        // Room for the badges that stick out.
        .padding(.top, size * 0.18).padding(.leading, size * 0.18)
        .accessibilityHidden(true)
    }
}

struct SourceRankBadge: View {
    let rank: Int
    var size: CGFloat
    var body: some View {
        Text(rank, format: .number).font(.system(size: size * 0.62, weight: .bold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Brand.onAccent)
            .padding(.horizontal, size * 0.2)
            .frame(minWidth: size, minHeight: size)
            .background(Brand.accent, in: Capsule())
            .overlay { Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 1) }
    }
}

/// One source in the order editor: its place, icon, name and health.
private struct SourceOrderRow: View {
    @Environment(Store.self) private var store
    let site: Site
    let rank: Int
    #if os(tvOS)
    private let icon: CGFloat = 56, rankWidth: CGFloat = 44
    private let title = Font.system(size: 29, weight: .medium), caption = Font.system(size: 22)
    #else
    private let icon: CGFloat = 32, rankWidth: CGFloat = 26
    private let title = Font.body.weight(.medium), caption = Font.caption
    #endif
    var body: some View {
        let label = SourceLabel(site.name)
        let detail = (label.parts.dropFirst() + [site.isBuiltIn ? L10n.text("Built-in") : nil].compactMap { $0 }).joined(separator: " · ")
        HStack(spacing: 12) {
            Text(rank, format: .number).font(caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(rank <= 3 ? Color.primary : Color.secondary)
                .frame(minWidth: rankWidth, alignment: .trailing)
            SourceIcon(site: site, label: label, size: icon)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(label.parts[0]).font(title).lineLimit(1)
                    SourceHealthDot(status: store.health(of: site))
                }
                if !detail.isEmpty { Text(detail).font(caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            #if os(macOS)
            // macOS lists draw no handle of their own; any part of the row drags.
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            #endif
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The viewer's source order as a list to drag into place. tvOS has no dragging: there, choose a
/// source, then where it goes; each move is saved at once.
struct SourceOrderEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [Site]
    /// What Reset goes back to.
    private let automatic: [Site]
    #if os(tvOS)
    @State private var moving: Site?
    #endif

    init(sites: [Site], automatic: [Site]) {
        _sites = State(initialValue: sites)
        self.automatic = automatic
    }

    private var isAutomatic: Bool { sites.map(\.id) == automatic.map(\.id) }

    private func save() {
        if let config = store.subscription { store.sourceOrder.save(sites, origin: config.origin) }
    }

    var body: some View {
        #if os(tvOS)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Choose a source to move it. Sources at the top are searched first, and their results are listed first."))
                        .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
                    ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                        Button { moving = site } label: { SourceOrderRow(site: site, rank: index + 1).frame(maxWidth: .infinity) }
                            .glassRow()
                            .accessibilityIdentifier("sources.order.row." + site.key)
                    }
                    TVSettingsAction(title: L10n.text("Reset"), destructive: true) {
                        withAnimation(.smooth) { sites = automatic }
                        save()
                    }
                    .disabled(isAutomatic)
                    .padding(.top, 16)
                }
                .glassRowInsets()
            }
            .screenTitle(L10n.text("Arrange Sources"))
            .screenBackdrop()
            .confirmationDialog(moving.map { SourceLabel($0.name).parts[0] } ?? "",
                                isPresented: Binding { moving != nil } set: { if !$0 { moving = nil } },
                                titleVisibility: .visible, presenting: moving) { site in
                let index = sites.firstIndex { $0.id == site.id } ?? 0
                if index > 0 {
                    Button(L10n.text("Move to Top")) { move(site, to: 0) }
                    Button(L10n.text("Move Up")) { move(site, to: index - 1) }
                }
                if index < sites.count - 1 {
                    Button(L10n.text("Move Down")) { move(site, to: index + 2) }
                    Button(L10n.text("Move to Bottom")) { move(site, to: sites.count) }
                }
            }
        }
        .frame(width: 1100, height: 800)
        .onExitCommand { dismiss() }
        #else
        NavigationStack {
            List {
                Section {
                    ForEach(Array(sites.enumerated()), id: \.element.id) { index, site in
                        SourceOrderRow(site: site, rank: index + 1)
                            #if os(iOS)
                            .listRowBackground(Surface())
                            #endif
                            .accessibilityIdentifier("sources.order.row." + site.key)
                    }
                    .onMove { sites.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text(L10n.text("Drag sources to reorder them. Sources at the top are searched first, and their results are listed first."))
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(L10n.text("Arrange Sources"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { save(); dismiss() }.fontWeight(.semibold)
                        .accessibilityIdentifier("sources.order.done")
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button(L10n.text("Reset")) { withAnimation(.smooth) { sites = automatic } }.disabled(isAutomatic)
                }
                #else
                ToolbarItem(placement: .destructiveAction) {
                    Button(L10n.text("Reset")) { withAnimation(.smooth) { sites = automatic } }.disabled(isAutomatic)
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
        #endif
    }

    #if os(tvOS)
    private func move(_ site: Site, to offset: Int) {
        guard let index = sites.firstIndex(where: { $0.id == site.id }) else { return }
        withAnimation(.smooth) { sites.move(fromOffsets: [index], toOffset: offset) }
        save()
    }
    #endif
}

struct SiteView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let origin: URL
    let jarURL: URL?
    var initialQuery: String = ""
    /// A drive source's folder: the page lists it in place of the source's home.
    var folder: Video? = nil
    private var canLoad: Bool { site.canBrowse(jarURL: jarURL) }
    private var isIndex: Bool { (site.raw["indexs"]?.int ?? 0) == 1 }
    @State private var browser = CatalogBrowser()
    @State private var query = ""
    /// The Bilibili login this page loaded with; signing in or out reloads it with the account's lists.
    @State private var bilibiliLogin = BilibiliAccount.load().cookie
    private var initialLoading: Bool { browser.videos.isEmpty && browser.error == nil && (browser.busy || !browser.loaded) }
    private var client: CatalogClient { CatalogClient(site: site, origin: origin, jarURL: jarURL) }
    @State private var requestTask: Task<Void, Never>?

    private func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        requestTask?.cancel()
        requestTask = Task {
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    var body: some View {
        Group {
            if !canLoad {
                ContentUnavailableView {
                    Label(site.compatibility, systemImage: "puzzlepiece.extension")
                } description: {
                    if site.type != 3 {
                        Text(L10n.text("This source format is not supported. Choose another source."))
                    } else {
                        Text(site.runtime == .jar ? L10n.text("This source uses a plugin that requires Android DEX and native libraries. This platform does not yet have the required compatibility layer.\n\n%@", site.api)
                             : site.runtime == .python ? L10n.text("This source requires a Python runtime, which is not available on this platform.")
                             : L10n.text("This source requires a JavaScript engine, which is not supported yet."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(tvOS)
                .focusable()
                .onExitCommand { dismiss() }
                #endif
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        #if os(tvOS)
                        // The remote's keyboard has no return key, so typing only edits the query; as in
                        // the Search tab, a focusable button below the keyboard runs the search.
                        let pending = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !pending.isEmpty, pending != browser.query {
                            SearchQueryButton(query: pending) { startRequest { await search() } }
                                .accessibilityIdentifier("site.search.submit")
                        }
                        #endif
                        if site.isBilibili && !BilibiliAccount.load().signedIn { BilibiliSignInBanner() }
                        if !browser.categories.isEmpty { categoryBar } else if initialLoading && folder == nil { ChipSkeletonRow() }
                        if isIndex && !browser.videos.isEmpty {
                            Text(L10n.text("Choose a title to find it across your sources.")).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if browser.busy {
                            LoadingCard { .source(site, origin: origin, title: L10n.text("Loading source content…")) }
                        }
                        if initialLoading { PosterSkeletonGrid().loadingFocus { dismiss() } }
                        if let error = browser.error {
                            ErrorStateCard(
                                title: L10n.text("Unable to load this source"),
                                message: L10n.text("Try again, or choose another source to keep watching."),
                                details: error,
                                retry: { startRequest { await browser.load(browser.request, client: client) } },
                                goBack: { dismiss() },
                                busy: browser.busy
                            )
                            .padding(.vertical, browser.videos.isEmpty ? 24 : 8)
                        }
                        if browser.videos.isEmpty && browser.loaded && !browser.busy && browser.error == nil { EmptyResults(symbol: "film", title: L10n.text("No Videos"), message: L10n.text("Try selecting a category or searching.")) }
                        LazyVGrid(columns: Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                            ForEach(browser.videos) { video in
                                // An index source (a ranking or list site) names titles; other sources play them.
                                if isIndex {
                                    Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                                } else {
                                    RouteLink { CatalogDestination(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                                }
                            }
                        }
                        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
                    }.pageContainer()
                }
                .safeAreaInset(edge: .bottom) { if browser.pageCount > 1 { pager } }
                .catalogSearchable(text: Binding(get: { query }, set: { value in
                    query = value
                    if value.isEmpty && !browser.query.isEmpty { startRequest { await home() } }
                }), prompt: L10n.text("Search videos"))
                .onSubmit(of: .search) { startRequest { await search() } }
            }
        }
        .onDisappear { requestTask?.cancel(); browser.cancel() }
        .toolbar {
            PinSourceButton(site: site, origin: origin)
            HideSourceButton(site: site, origin: origin)
        }
        .screenBackdrop()
        .onAppear {
            guard site.isBilibili, browser.loaded else { return }
            let login = BilibiliAccount.load().cookie
            if login != bilibiliLogin { bilibiliLogin = login; query = ""; startRequest { await home(); await browser.loadCategories(client: client) } }
        }
        .screenTitle(folder?.name ?? site.name).task {
            store.searchModel.suspend()
            if canLoad && !browser.loaded {
                if browser.request != .home {
                    await browser.load(browser.request, client: client)
                } else if initialQuery.isEmpty {
                    await home()
                    #if DEBUG
                    // `-qaCategory <type id>` opens that category, for screenshots.
                    if let category = UserDefaults.standard.string(forKey: "qaCategory") {
                        await browser.load(.list(category: category, query: "", page: 1), client: client)
                    }
                    // `-qaSearchDraft <text>` types a query without running it, for the remote's Search button.
                    if let draft = UserDefaults.standard.string(forKey: "qaSearchDraft") { query = draft }
                    #endif
                }
                else { query = initialQuery; await search(); await browser.loadCategories(client: client) }
            }
        }
    }
    private var categoryBar: some View {
        ChipRow {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Chip(title: L10n.text("Recommendations"), selected: browser.query.isEmpty && browser.category.isEmpty) { query = ""; startRequest { await home() } }
                    ForEach(browser.categories) { item in
                        Chip(title: item.name, selected: browser.query.isEmpty && browser.category == item.id) {
                            query = ""
                            startRequest { await browser.load(.list(category: item.id, query: "", page: 1), client: client) }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
    }
    private var pager: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button { startRequest { await load(page: browser.page - 1) } } label: { Image(systemName: "chevron.left").frame(width: 22) }
                    .controlButton().disabled(browser.page <= 1 || browser.busy).accessibilityLabel(L10n.text("Previous"))
                Text(L10n.text("Page %lld of %lld", browser.page, browser.pageCount)).font(.subheadline.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                Button { startRequest { await load(page: browser.page + 1) } } label: { Image(systemName: "chevron.right").frame(width: 22) }
                    .controlButton().disabled(browser.page >= browser.pageCount || browser.busy).accessibilityLabel(L10n.text("Next"))
            }
        }.controlSize(.large)
        #if os(tvOS)
        .padding(.vertical, 20).frame(maxWidth: .infinity).background(TVStyle.background).focusSection()
        #else
        .padding(.vertical, 8).frame(maxWidth: .infinity).controlBackdrop()
        #endif
    }
    private func home() async { await browser.load(folder.map { .list(category: $0.id, query: "", page: 1) } ?? .home, client: client) }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { await home() }
        else { await browser.load(.list(category: nil, query: text, page: 1), client: client) }
    }
    private func load(page next: Int) async {
        await browser.load(.list(category: browser.category.isEmpty ? nil : browser.category, query: browser.query, page: next), client: client)
    }
}

/// Where a listed title opens: its details, or for a drive source's folder the folder's listing.
struct CatalogDestination: View {
    let video: Video
    let client: CatalogClient
    var body: some View {
        if video.isFolder { SiteView(site: client.site, origin: client.origin, jarURL: client.jarURL, folder: video) }
        else { VideoDetailView(video: video, client: client) }
    }
}

struct VideoDetailView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let video: Video
    let client: CatalogClient
    /// Opened from Continue Watching: on an iPhone the page resumes it at once.
    var resume: PlaybackHistoryEntry? = nil
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var fullScreen = false
    @State private var showsAllEpisodes = false
    @State private var episodeScroll: Episode.ID?
    /// The page's player shows its picture (or an error); until then the page's cover stays over it.
    @State private var playerStarted = false
    /// Back on the cover while it starts: shown for a moment by a tap, as the player's controls are.
    @State private var coverBack = false
    /// The page's player, whose wait the cover tells about.
    @State private var playerSession: PlaybackSession?
    #endif
    @State private var requestTask: Task<Void, Never>?
    @State private var detail: Video?
    @State private var error: String?
    @State private var busy = false
    @State private var pendingPlan: PlaybackPlan?
    @State private var pendingEpisode: Episode?
    @State private var choosingQuality = false
    @State private var synopsisExpanded = false
    @State private var selectedFlag: String?
    /// 倒序: the episode lists show the last episode first. Remembered for every video.
    @AppStorage("episodesReversed") private var reversesEpisodes = false
    /// Play takes over focus from the loading placeholder; otherwise nothing is focused once details load.
    @FocusState private var playFocused: Bool
    @State private var containerWidth: CGFloat = 0
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @State private var artAspect: CGFloat?
    /// The episode whose playback is being prepared; its row and the Play button show progress.
    @State private var loadingEpisode: Episode.ID?
    /// A failed or blocked playback attempt, shown as an inline banner beside the artwork.
    @State private var playbackIssue: PlaybackIssue?
    @State private var signingIn: CloudDrive?
    /// A sign-in the source's CatPawOpen bundle runs itself (UC's TV token).
    @State private var bundleSignIn: BundleSignIn?
    @State private var choosingDownloads = false
    /// How many episodes were just queued, shown briefly under the header.
    @State private var queuedNotice: Int?
    /// TMDB's details for the video (TMDBViews.swift). The page shows the source's own until they are in, then fades them in.
    @State private var tmdb = TMDBLookup()
    private var flags: [String] {
        var seen = Set<String>()
        return (detail?.episodes ?? []).map(\.flag).filter { seen.insert($0).inserted }
    }
    private var activeFlag: String { flags.contains(selectedFlag ?? "\u{0}") ? selectedFlag! : (flags.first ?? "") }
    /// The active line's episodes. `activeFlag` goes through every episode, so it is read once, not once per episode:
    /// in the filter it made each page update quadratic (4 lines of 1,000 episodes took seconds, and iOS killed the app).
    private var activeEpisodes: [Episode] {
        let flag = activeFlag
        return (detail?.episodes ?? []).filter { $0.flag == flag }
    }
    private var wideMinWidth: CGFloat {
        #if os(tvOS)
        1200
        #else
        760
        #endif
    }
    private func startRequest(_ operation: @escaping @MainActor () async -> Void) {
        let previous = requestTask
        previous?.cancel()
        requestTask = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if watchLayout { watchBody } else { pageBody }
            #else
            pageBody
            #endif
        }
        .safeAreaInset(edge: .bottom) { if !isWatchPage { loadingCard } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DetailAurora(poster: video.poster, headers: video.posterHeaders) }
        #else
        .screenBackdrop()
        #endif
        .screenTitle(video.name).task {
            store.searchModel.suspend()
            #if os(iOS)
            // From Continue Watching the watch page resumes at once, resolving its own details.
            let continues = watchLayout && watchChannel == nil && store.resumingHistoryID == nil
            if continues, let resume { store.resume(resume) }
            #endif
            if detail == nil { await loadDetail() }
            #if os(iOS)
            // A video of one episode then plays by itself, from where the viewer stopped if watched before. One of
            // several waits on its cover for the viewer to choose the line and episode (#260).
            if continues, resume == nil, watchChannel == nil, store.resumingHistoryID == nil, activeEpisodes.count <= 1 {
                playWatchCover()
            }
            #endif
            #if DEBUG
            // `-qaDownloadPicker 1` opens the episode picker, for screenshots.
            if UserDefaults.standard.bool(forKey: "qaDownloadPicker") { choosingDownloads = true }
            #endif
        }
        .onDisappear { requestTask?.cancel() }
        .task(id: detail?.id) { await startTMDB() }
        .onChange(of: choosingQuality) { _, open in if !open && !busy { loadingEpisode = nil } }
        // Sign in where playback failed, then resume the episode that needed the account.
        #if !os(tvOS)
        .sheet(item: $bundleSignIn) { pending in
            CatPawSignInView(client: client, provider: pending.provider) {
                if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
            }
        }
        #endif
        #if os(macOS)
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei {
                XunleiSignInView { if let episode = playbackIssue?.episode { startRequest { await play(episode) } } }
            } else {
                CloudLoginView(provider: drive.provider) { cookie, ticket in
                    try await drive.provider.saveLogin(cookie, ticket: ticket)
                    if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
                }
            }
        }
        #elseif os(iOS)
        // The drive's own sign-in page; the code is for signing in with another phone.
        .sheet(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else {
                WebSignInView(service: drive.webSignIn, signedIn: retryAfterSignIn) {
                    CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() }
                }
            }
        }
        #else
        .fullScreenCover(item: $signingIn) { drive in
            if drive == .xunlei { XunleiSignInView(signedIn: retryAfterSignIn) }
            else { CloudQRLoginView(drive: drive.qrDrive) { retryAfterSignIn() } }
        }
        #endif
        .downloadPicker(isPresented: $choosingDownloads) {
            DownloadPicker(video: video, site: client.site, flag: activeFlag,
                           episodes: activeEpisodes) { count in
                guard count > 0 else { return }
                withAnimation(.smooth(duration: 0.2)) { queuedNotice = count }
                Task { try? await Task.sleep(for: .seconds(6)); withAnimation(.smooth(duration: 0.2)) { queuedNotice = nil } }
            }
        }
        .confirmationDialog(L10n.text("Choose quality"), isPresented: $choosingQuality, titleVisibility: .visible) {
            if let plan = pendingPlan, let episode = pendingEpisode {
                ForEach(plan.choices) { choice in
                    Button(choice.name) { startRequest { await resolve(plan, choice: choice, episode: episode) } }
                }
            }
        }
    }

    /// One page on Mac, iPad and Apple TV: the banner, the synopsis, the episodes, then TMDB's cast and facts. An episode
    /// rail beside the banner (once used for long lists, and always on Apple TV) squeezed the banner into a card.
    private var pageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if detail != nil {
                    episodePanel
                    tmdbExtras
                } else if let error {
                    errorCard(error).padding(.top, 12)
                } else {
                    // The Play placeholder in the header holds focus while details load.
                    DetailSkeleton()
                }
            }
            .pageContainer()
        }
    }

    private var isWatchPage: Bool {
        #if os(iOS)
        watchLayout
        #else
        false
        #endif
    }

    @ViewBuilder private var loadingCard: some View {
        if busy {
            // Keyed by the step, so the timer restarts when details turn into resolving a link.
            LoadingCard { .source(client.site, origin: client.origin, title: busyTitle) }
                .id(busyTitle)
                .frame(maxWidth: .infinity).padding(.horizontal, Layout.gutter).padding(.bottom, 24)
        }
    }
    @ViewBuilder private var playbackBanner: some View {
        if let count = queuedNotice {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Brand.accent)
                Text(count == 1 ? L10n.text("1 episode added to Downloads.") : L10n.text("%lld episodes added to Downloads.", count)).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button(L10n.text("Show Downloads")) { store.section = .downloads }.settingsButton()
            }
            .padding(14)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let issue = playbackIssue {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: issue.drive != nil || issue.signIn != nil ? "person.crop.circle.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Brand.amber)
                    .frame(width: 36, height: 36)
                    .background(Brand.amber.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Couldn't play %@", EpisodeRow.title(issue.episode.name)))
                            .font(.headline).lineLimit(2)
                        Text(issue.message).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).selectable()
                    }
                    HStack(spacing: 8) {
                        if let drive = issue.drive {
                            Button(drive.signInTitle) { signingIn = drive }.settingsButton(prominent: true)
                        }
                        #if !os(tvOS)
                        if let provider = issue.signIn {
                            Button(L10n.text("Get UC TV Token")) { bundleSignIn = BundleSignIn(provider: provider) }
                                .settingsButton(prominent: true)
                                .accessibilityIdentifier("playbackIssue.bundleSignIn")
                        }
                        #endif
                        Button(L10n.text(issue.blockedBeforeRequest ? "Try Anyway" : "Retry")) {
                            startRequest { await play(issue.episode, skipAccountCheck: true) }
                        }
                        .settingsButton(prominent: issue.drive == nil && issue.signIn == nil)
                        #if os(tvOS)
                        // A focusable action instead of the small corner close button.
                        Button(L10n.text("Dismiss")) { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } }.settingsButton()
                        #endif
                    }
                }
                Spacer(minLength: 0)
                #if !os(tvOS)
                Button { withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss")).help(L10n.text("Dismiss"))
                #endif
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    private func errorCard(_ error: String) -> some View {
                    ErrorStateCard(
                        title: detail == nil ? L10n.text("Unable to load video details") : L10n.text("Unable to start playback"),
                        message: detail == nil
                            ? L10n.text("Try again, or go back and choose another video.")
                            : L10n.text("Try another episode or playback source."),
                        details: error,
                        retry: detail == nil ? { startRequest { await loadDetail() } } : nil,
                        goBack: { dismiss() },
                        busy: busy,
                        backTitle: L10n.text("Go back")
                    )
    }
    private var busyTitle: String {
        if detail == nil { return L10n.text("Loading video details…") }
        let episode = detail?.episodes.first { $0.id == loadingEpisode }
        return episode.map { L10n.text("Getting the video link for %@…", EpisodeRow.title($0.name)) } ?? L10n.text("Getting the video link…")
    }
    private func loadDetail() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let value = try await client.detail(video.id, cached: client.site.type == 3 || client.site.type == 4)
            try Task.checkCancellation()
            detail = value
            // Start on a line that can play: not one from a drive the viewer has no way to sign in to.
            if selectedFlag == nil { selectedFlag = CloudDrive.preferredFlag(flags) }
            #if os(tvOS)
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.shared.failure("catalog", "detail \(client.reportContext)", error)
            self.error = error.localizedDescription
            #if os(tvOS)
            // The loading placeholder that held focus is gone: Retry in the hero takes it.
            Task { try? await Task.sleep(for: .milliseconds(100)); playFocused = true }
            #endif
        }
    }
    /// What this device knows shows at once; otherwise the lookup starts once the source's details are in (their
    /// synopsis and episodes help tell works of the same name apart).
    private func startTMDB() async {
        guard TMDBLookup.applies(to: client.site) else { return }
        let key = TMDBMatchStore.key(source: client.site.key, video: video.id)
        guard let detail else { _ = await tmdb.prepare(key: key); return }
        let request = TMDBMatch.Request(video: detail.keepingPoster(video.poster), listVideo: video,
                                        source: TMDBMatch.SourceRef(key: client.site.key, name: client.site.name))
        // AI-generated videos and short dramas aren't on TMDB: the page keeps the source's own data.
        guard !TMDBMatch.labeledNotOnTMDB(request) else { tmdb.skip(); return }
        await tmdb.run(key: key, request: request)
    }
    /// TMDB's story when it has one, else the source's synopsis.
    private func synopsisText(_ detail: Video) -> String {
        if let story = tmdb.details?.story, !story.isEmpty { return story }
        return detail.synopsis
    }
    /// The lookup's progress or its question, then TMDB's cast, facts and notice, under the page's own content.
    @ViewBuilder private var tmdbStatus: some View {
        TMDBLookupStatus(lookup: tmdb)
    }
    @ViewBuilder private var tmdbExtras: some View {
        if let details = tmdb.details {
            VStack(alignment: .leading, spacing: 22) {
                if !details.cast.isEmpty { TMDBCastRow(cast: details.cast) }
                TMDBInfoGrid(details: details)
                if let related = details.recommendations, !related.isEmpty {
                    TMDBRelatedRow(titles: related) { store.searchVideos($0) }
                }
                TMDBFooter(lookup: tmdb, title: currentVideo().name)
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
    private var bannerHeight: CGFloat {
        #if os(tvOS)
        // Leaves the synopsis in view under it.
        min(max(containerWidth * 0.38, 480), 680)
        #else
        min(max(containerWidth * 0.42, 280), 540)
        #endif
    }
    /// TMDB's backdrop banner once the details are in, the source's cover and title until then.
    @ViewBuilder private var tmdbHero: some View {
        if let details = tmdb.details, let backdrop = details.backdrop {
            let banner = TMDBBanner(details: details, backdrop: backdrop, unmatched: tmdb.answer?.unmatched ?? "") { playControl }
            banner.frame(height: bannerHeight).transition(.opacity)
        } else {
            hero.transition(.opacity)
        }
    }
    private var headerLayout: AnyLayout {
        #if os(iOS)
        if sizeClass == .compact { return AnyLayout(HStackLayout(alignment: .top, spacing: 16)) }
        #endif
        return AnyLayout(HStackLayout(alignment: .top, spacing: 24))
    }
    private var compactDetail: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    @ViewBuilder private func synopsis(_ detail: Video) -> some View {
        let text = synopsisText(detail)
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).foregroundStyle(.secondary)
                    .lineLimit(synopsisExpanded ? nil : synopsisLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if text.count > 100 {
                    let toggle = Button(L10n.text(synopsisExpanded ? "Show Less" : "Show Full Synopsis")) { synopsisExpanded.toggle() }
                    #if os(tvOS)
                    toggle.controlButton()
                    #else
                    toggle.buttonStyle(.plain).font(.subheadline.weight(.semibold)).frame(minHeight: 44, alignment: .leading)
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full width, so Down from the banner's buttons reaches Show Full Synopsis wherever they sit.
            .tvFocusSection()
        }
    }
    private var synopsisLineLimit: Int {
        #if os(tvOS)
        4
        #else
        3
        #endif
    }
    private var posterWidth: CGFloat {
        #if os(macOS)
        150
        #elseif os(iOS)
        compactDetail ? 104 : 150
        #else
        Layout.detailPoster
        #endif
    }
    private var isWide: Bool { containerWidth >= wideMinWidth }
    /// The details, with the list's poster when the details came without one.
    private func currentVideo() -> Video { (detail ?? video).keepingPoster(video.poster, headers: video.posterHeaders) }

    private func videoFavorite() -> FavoriteItem {
        .video(FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()))
    }

    private func episodeFavorite(_ episode: Episode) -> FavoriteItem {
        .episode(FavoriteEpisode(video: FavoriteVideo(origin: client.origin, site: client.site, video: currentVideo()), episodeFlag: episode.flag, episodeName: episode.name, episodeID: episode.id))
    }

    @ViewBuilder private var playControl: some View {
        if let detail {
            if let first = activeEpisodes.first ?? detail.episodes.first {
                // Beside the poster on a phone there is no room for both labels: Download drops to its icon.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: false); videoFavoriteButton }
                    HStack(spacing: 10) { playButton(first); downloadButton(iconOnly: true); videoFavoriteButton }
                }
            } else {
                #if os(tvOS)
                // No episodes, so no Play: without a button here nothing on the page could take focus, and Back
                // did nothing at all.
                goBackButton(prominent: true).focused($playFocused)
                #endif
            }
        } else if error == nil {
            // On Apple TV the hero fills the screen and the skeleton below it is off-screen: the
            // Play button's placeholder holds focus, so Back leaves the page instead of the app.
            SkeletonBlock(cornerRadius: 10).frame(width: 150, height: 40).loadingFocus(takeFocus: true) { dismiss() }
        } else {
            #if os(tvOS)
            // The details failed. The error card's buttons are below the full-screen hero, out of the remote's reach,
            // so the hero offers them too; they hold focus, and Back leaves the page again.
            HStack(spacing: 10) {
                Button { startRequest { await loadDetail() } } label: { Label(L10n.text("Retry"), systemImage: "arrow.clockwise") }
                    .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
                    .disabled(busy)
                    .focused($playFocused)
                    .accessibilityIdentifier("detail.retry")
                goBackButton(prominent: false)
            }
            #endif
        }
    }
    #if os(tvOS)
    private func goBackButton(prominent: Bool) -> some View {
        Button { dismiss() } label: { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
            .controlButton(prominent: prominent).controlSize(.large)
            .accessibilityIdentifier("detail.goBack")
    }
    #endif
    private func playButton(_ episode: Episode) -> some View {
        Button { startRequest { await play(episode) } } label: {
            HStack(spacing: 8) {
                if loadingEpisode == episode.id { ProgressView().controlSize(.small) } else { Image(systemName: "play.fill") }
                Text(L10n.text("Play"))
            }
            .font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 8)
        }
        .controlButton(prominent: true).tint(Brand.accent).controlSize(.large)
        .focused($playFocused)
    }
    private func downloadButton(iconOnly: Bool) -> some View {
        Button { choosingDownloads = true } label: {
            Label(L10n.text("Download"), systemImage: "arrow.down.circle")
                .labelStyle(DownloadLabelStyle(iconOnly: iconOnly))
                .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large).accessibilityLabel(L10n.text("Download"))
    }
    /// Icon-only, beside Play and Download. An empty heart keeps the control color; a saved one is rose.
    /// Set as text in their font, so the button is as tall as theirs: a bare image made a smaller one on Apple TV.
    private var videoFavoriteButton: some View {
        let saved = store.favorites.contains(videoFavorite())
        let title = saved ? L10n.text("Remove %@ from favorites", currentVideo().name) : L10n.text("Add %@ to favorites", currentVideo().name)
        return Button { store.favorites.toggle(videoFavorite()) } label: {
            Group {
                if saved {
                    Text(Image(systemName: "heart.fill")).foregroundStyle(Brand.rose)
                } else {
                    Text(Image(systemName: "heart"))
                }
            }
            .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().controlSize(.large)
        .accessibilityLabel(title).help(title)
        .accessibilityIdentifier("detail.favorite")
    }
    /// The source's cover in TMDB's banner shape, so the page keeps its layout when TMDB's backdrop fades in, and for
    /// titles TMDB doesn't have.
    private var hero: some View {
        PosterBanner(poster: video.poster, headers: video.posterHeaders, title: video.name, subtitle: video.remarks,
                     aspect: $artAspect) { playControl }
            .frame(height: bannerHeight)
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            // TMDB's banner at any width, so a matched title's page looks the same everywhere.
            if isWide || tmdb.details?.backdrop != nil {
                tmdbHero
                playbackBanner
                tmdbStatus
                if let detail, !synopsisText(detail).isEmpty {
                    synopsis(detail).font(.body).padding(.horizontal, 18).padding(.vertical, 14)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear.aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: posterWidth)
                        .overlay { PosterImage(url: video.poster, headers: video.posterHeaders) }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // As tall as the 2:3 poster, so the buttons line up with its bottom edge.
                    MinHeightLayout(minHeight: posterWidth * 1.5) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(video.name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                            if !video.remarks.isEmpty { Text(video.remarks).font(.subheadline).foregroundStyle(.secondary) }
                            if let facts = tmdb.details?.facts, !facts.isEmpty {
                                Text(facts).font(.subheadline).foregroundStyle(.secondary).transition(.opacity)
                            }
                            Spacer(minLength: 0)
                            playControl
                        }
                    }
                    Spacer(minLength: 0)
                }
                playbackBanner
                tmdbStatus
                if let detail { synopsis(detail) }
            }
        }
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }
    @ViewBuilder private var episodePanel: some View {
        if let detail {
            if detail.episodes.isEmpty {
                Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
            } else {
                let items = activeEpisodes
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        #if os(tvOS)
                        if items.count > 1 {
                            episodeOrderButton(count: items.count)
                        } else {
                            Text(L10n.text("Episodes")).font(.headline)
                        }
                        #else
                        Text(L10n.text("Episodes")).font(.headline)
                        Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                        if items.count > 1 { episodeOrderButton }
                        #endif
                        Spacer(minLength: 8)
                        if flags.count == 1, !activeFlag.isEmpty {
                            Text(SourceLabel(activeFlag).text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    flagPicker
                    episodeList(items)
                }
            }
        }
    }
    @ViewBuilder private var flagPicker: some View {
        if flags.count > 1 {
            #if os(tvOS)
            ChipRow {
                HStack(spacing: 8) {
                    ForEach(flags, id: \.self) { flag in
                        Chip(title: flag.isEmpty ? L10n.text("Play") : flag, selected: flag == activeFlag) { selectedFlag = flag }
                    }
                }
            }.tvFocusSection()
            #else
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { selectedFlag = $0 }
            #endif
        }
    }
    #if os(tvOS)
    /// On Apple TV the heading itself turns the list around (倒序): one glass button whose arrow shows the order,
    /// up for the first episode first, down for the last.
    private func episodeOrderButton(count: Int) -> some View {
        Button { reversesEpisodes.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: reversesEpisodes ? "arrow.down" : "arrow.up").contentTransition(.symbolEffect(.replace))
                Text(L10n.text("Episodes"))
                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .glassPill()
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #else
    /// The small button beside the episode count that turns the lists around (倒序).
    private var episodeOrderButton: some View {
        Button { reversesEpisodes.toggle() } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(reversesEpisodes ? Brand.accent : Color.secondary)
                .frame(minWidth: 32, minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("Reverse Order"))
        .accessibilityLabel(L10n.text("Reverse Order"))
        .accessibilityAddTraits(reversesEpisodes ? .isSelected : [])
        .accessibilityIdentifier("episodes.reverse")
    }
    #endif

    /// The episodes in the order the lists show them. Only the lists: Play and the next episode still follow the source.
    private func shownOrder(_ items: [Episode]) -> [Episode] { reversesEpisodes ? items.reversed() : items }

    private func episodeList(_ items: [Episode]) -> some View {
        // A chip fits about six characters before it truncates (《一…); longer names get rows.
        let longNames = (items.map { $0.name.count }.max() ?? 0) > 6
        // Under a full-width banner, long names fill columns rather than one stretched list.
        let rowColumns = isWide ? [GridItem(.adaptive(minimum: 320), spacing: 8)] : [GridItem(.flexible())]
        // TMDB's stills, when its season lines up with most of the episodes and has pictures for them; without
        // pictures the small chips read better than empty tiles. While TMDB is still looking, tiles with the episode
        // numbers, so its stills fade into the same tiles instead of chips turning into tiles.
        let stills = tmdb.episodes(items)
        let showsStills = items.count > 1
            && (stills.values.filter { $0.still != nil }.count * 2 >= items.count || (tmdbPending && items.count <= 60))
        let columns = showsStills ? [GridItem(.adaptive(minimum: TMDBMetrics.episodeTile), spacing: TMDBMetrics.spacing, alignment: .top)]
            : longNames ? rowColumns : [GridItem(.adaptive(minimum: episodeMin), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: showsStills ? TMDBMetrics.spacing : longNames ? 4 : 8) {
            ForEach(shownOrder(items)) { episode in
                let saved = download(episode)
                Group {
                    if showsStills {
                        Button { startRequest { await play(episode) } } label: {
                            TMDBEpisodeTile(name: EpisodeRow.title(episode.name), info: stills[episode.id], loading: loadingEpisode == episode.id, width: nil)
                        }
                        .tmdbCardButton()
                        .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
                        .accessibilityLabel(episode.name)
                    } else if longNames {
                        EpisodeRow(name: episode.name, loading: loadingEpisode == episode.id, download: saved) { startRequest { await play(episode) } }
                    } else {
                        Chip(title: episode.name, selected: loadingEpisode == episode.id, fill: true) { startRequest { await play(episode) } }
                            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if store.favorites.contains(episodeFavorite(episode)) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: DownloadMetrics.thumb > 60 ? 18 : 12, weight: .semibold))
                            .foregroundStyle(Brand.rose)
                            .padding(4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contextMenu {
                    FavoriteMenuButton(item: episodeFavorite(episode), name: episode.name)
                    if saved == nil || saved?.status == .failed {
                        Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                            DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode),
                                                            title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                        }
                    } else if let saved {
                        Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                            DownloadLibrary.shared.remove([saved.id])
                        }
                    }
                }
            }
        }
        #if os(tvOS)
        // Room for the focused glass row, which grows toward the trailing edge.
        .padding(.trailing, 16).padding(.vertical, 6)
        #endif
        .tvFocusSection()
        .animation(.smooth(duration: 0.4), value: showsStills)
    }
    /// Mac and iPad, under the banner: TMDB hasn't answered yet. Short-drama-length lists stay chips (see episodeList).
    private var tmdbPending: Bool {
        #if os(tvOS)
        false
        #else
        isWide && (tmdb.phase == .looking || (tmdb.phase == .idle && TMDBLookup.applies(to: client.site)))
        #endif
    }
    private var episodeMin: CGFloat {
        #if os(tvOS)
        170
        #else
        // Room for 第 10 集 / 第01集 without an ellipsis.
        100
        #endif
    }
    private func download(_ episode: Episode) -> DownloadItem? {
        DownloadLibrary.shared.item(for: DownloadSource(site: client.site, videoID: video.id, episode: episode))
    }
    private func play(_ episode: Episode, skipAccountCheck: Bool = false) async {
        guard !busy else { return }
        // A downloaded episode plays from the device: no link to fetch, and it works offline.
        if let saved = download(episode), saved.status == .completed {
            store.playing = DownloadLibrary.shared.channel(for: saved)
            return
        }
        // Cloud-drive plugins wait for an in-app login that cannot appear on this platform,
        // which surfaces only as a 60-second timeout. Ask for the account up front instead.
        if !skipAccountCheck, let drive = CloudDrive.missingLogin(forFlag: episode.flag) {
            withAnimation(.smooth(duration: 0.25)) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.loginHint, drive: drive, blockedBeforeRequest: true)
            }
            return
        }
        busy = true; loadingEpisode = episode.id
        withAnimation(.smooth(duration: 0.2)) { playbackIssue = nil }
        defer { busy = false; if !choosingQuality { loadingEpisode = nil } }
        do {
            let plan = try await client.preparePlayback(episode)
            try Task.checkCancellation()
            if plan.choices.count > 1 {
                pendingPlan = plan; pendingEpisode = episode; choosingQuality = true
            } else {
                let playback = store.subscription.map { client.applying($0) } ?? client
                let resolved = try await playback.resolvePlayback(plan, choice: plan.choices[0])
                try Task.checkCancellation()
                store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
            }
        } catch { fail(episode, error) }
    }
    private func resolve(_ plan: PlaybackPlan, choice: PlaybackChoice, episode: Episode) async {
        busy = true; loadingEpisode = episode.id
        defer { busy = false; pendingPlan = nil; pendingEpisode = nil; loadingEpisode = nil }
        do {
            let playback = store.subscription.map { client.applying($0) } ?? client
            let resolved = try await playback.resolvePlayback(plan, choice: choice)
            try Task.checkCancellation()
            store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback)
        } catch { fail(episode, error) }
    }
    #if !os(macOS)
    private func retryAfterSignIn() {
        if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
    }
    #endif
    private func fail(_ episode: Episode, _ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        // A drive that needs signing in is expected, not a failure to report.
        if !(error is CloudDriveLoginRequired) {
            Diagnostics.shared.failure("catalog", "play \(client.reportContext) flag=\(episode.flag)", error)
        }
        withAnimation(.smooth(duration: 0.25)) {
            // Plugins report a missing or expired drive login in their own words ("夸克授权失败，请扫码登录");
            // say what happened and offer the sign-in instead of echoing them.
            if let login = error as? CloudDriveLoginRequired, let drive = CloudDrive(rawValue: login.rawValue) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else if let provider = CatPawSignIn.provider(for: error.localizedDescription) {
                // Signed in, but the bundle wants a token its own code gives; signing in again would change nothing.
                playbackIssue = PlaybackIssue(episode: episode, message: L10n.text("You're signed in to UC, but this source plays UC accounts without premium through UC's TV app, which needs a token of its own. Get it once with the UC Browser app, or choose another line."),
                                              drive: nil, blockedBeforeRequest: false, signIn: provider)
            } else if let drive = CloudDrive(flag: episode.flag), CloudDrive.isLoginFailure(error.localizedDescription) {
                playbackIssue = PlaybackIssue(episode: episode, message: drive.expiredHint, drive: drive, blockedBeforeRequest: false)
            } else {
                playbackIssue = PlaybackIssue(episode: episode, message: error.localizedDescription,
                                              drive: CloudDrive.missingLogin(forFlag: episode.flag), blockedBeforeRequest: false)
            }
        }
    }

    #if os(iOS)
    // MARK: iPhone watch page

    private var watchLayout: Bool { WatchPage.applies(sizeClass, verticalSizeClass) }
    /// This video's playback scopes (`PlaybackHistoryContext.id`); the details may carry another ID than the list's.
    private var watchScopes: Set<String> {
        let origin = client.site.origin(or: client.origin)
        return Set([video.id, detail?.id].compactMap { $0 }.map { EpisodeSkipSettings.scope(origin: origin, source: client.site.sourceKey, video: $0) })
    }
    /// What plays at the top of the page: one of this video's episodes.
    private var watchChannel: Channel? {
        store.playing.flatMap { watchScopes.contains($0.historyContext?.id ?? "") ? $0 : nil }
    }
    /// Where the viewer stopped last time, for Continue.
    private var watchHistory: PlaybackHistoryEntry? {
        store.playbackHistory.entries.first { watchScopes.contains($0.context.id) }
    }
    /// The episode playing, else the one watched last: marked in the list, which scrolls to it.
    private var currentEpisodeID: Episode.ID? {
        guard let episodes = detail?.episodes else { return nil }
        return (watchChannel?.historyContext ?? watchHistory?.context)?.episode(in: episodes)?.id
    }

    /// As in Bilibili's app: the player at the top, under the status bar, and the title, actions, synopsis and
    /// episodes scrolling below it. Full Screen grows the same player over the page, so playback carries on.
    @ViewBuilder private var watchBody: some View {
        let playerHeight = (containerWidth > 0 ? containerWidth : 390) * 9 / 16
        ZStack(alignment: .top) {
            if !fullScreen {
                VStack(spacing: 0) {
                    Color.clear.frame(height: playerHeight)
                    ScrollView { watchDetails.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 24) }
                        .scrollIndicators(.never)
                }
            }
            watchPlayer
                .frame(height: fullScreen ? nil : playerHeight)
                .frame(maxWidth: .infinity, maxHeight: fullScreen ? .infinity : nil, alignment: .top)
        }
        // The status bar's strip above the player is the player's black.
        .background(alignment: .top) { Color.black.frame(height: playerHeight).ignoresSafeArea(edges: .top) }
        .background { if fullScreen { Color.black.ignoresSafeArea() } }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .background { EdgeSwipeBack(enabled: !fullScreen) }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            store.watchPageScopes.formUnion(watchScopes)
            PlayerOrientation.holdPortrait(true)
        }
        .onChange(of: watchScopes) { old, new in
            store.watchPageScopes.subtract(old.subtracting(new)); store.watchPageScopes.formUnion(new)
        }
        .onDisappear {
            // Leaving the page ends its playback, as the full-screen player's Back does.
            if watchChannel != nil { store.playing = nil }
            store.watchPageScopes.subtract(watchScopes)
            if fullScreen { fullScreen = false; PlayerOrientation.set(landscape: false) }
            PlayerOrientation.holdPortrait(false)
        }
        .onChange(of: watchChannel == nil) { _, ended in
            playerStarted = false
            if ended { playerSession = nil }
            if ended && fullScreen { setFullScreen(landscape: false) }
        }
        .sheet(isPresented: $showsAllEpisodes) { allEpisodes }
    }

    @ViewBuilder private var watchPlayer: some View {
        // One cover from opening the page to the first picture: the player's own wait stays under it, so nothing
        // swaps or flickers on the way.
        let covered = watchChannel == nil || (!playerStarted && !fullScreen)
        ZStack {
            if let channel = watchChannel {
                PlaybackView(channel: channel, watch: WatchPlayback(fullScreen: fullScreen, toggleFullScreen: setFullScreen, leave: { dismiss() },
                                                                    started: { playerStarted = $0 }, opened: { playerSession = $0 }))
            }
            if covered { watchCover.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.35), value: covered)
    }

    /// The cover's words while it waits: the source finding the episode's link, then the page's player getting it ready.
    private func coverStatus(_ elapsed: TimeInterval) -> PlaybackWait {
        if let session = playerSession, let channel = watchChannel, loadingEpisode == nil {
            return session.wait(elapsed: elapsed, resume: channel.resumePosition, linesHint: false)
        }
        let progress = LoadingProgress.source(client.site, origin: client.origin, title: busyTitle)
        return PlaybackWait(message: progress.title, detail: progress.detail)
    }

    private func setFullScreen(landscape: Bool) {
        let entering = !fullScreen
        withAnimation(.smooth(duration: 0.3)) { fullScreen = entering }
        // A landscape picture turns the phone; a portrait one fills the screen upright.
        if !entering { PlayerOrientation.set(landscape: false) } else if landscape { PlayerOrientation.set(landscape: true) }
    }

    /// The cover's Play: where the viewer stopped, else the line's first episode.
    private func playWatchCover() {
        if let watchHistory { store.resume(watchHistory); return }
        guard let first = activeEpisodes.first ?? detail?.episodes.first else { return }
        startRequest { await play(first) }
    }

    /// Before the picture: the cover across the top, blurred, while an episode starts. Otherwise (a video of several
    /// episodes waiting for one to be chosen, or an episode that failed, which the banner below explains) the cover
    /// shows clear, as Discover's page does, with Play.
    private var watchCover: some View {
        let starting = (detail == nil && error == nil) || busy || loadingEpisode != nil || store.resumingHistoryID != nil || watchChannel != nil
        let playable = watchHistory != nil || (activeEpisodes.first ?? detail?.episodes.first) != nil
        // The list's poster when there was one, so the picture doesn't change once the details arrive.
        let poster = video.poster != nil ? video : detail ?? video
        return WatchCoverBackdrop(poster: poster.poster, headers: poster.posterHeaders, loading: starting, clear: !starting) { coverStatus($0) }
            .contentShape(Rectangle())
            .onTapGesture { if starting { withAnimation(.smooth(duration: 0.25)) { coverBack.toggle() } } }
            .task(id: coverBack) {
                guard coverBack else { return }
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { withAnimation(.smooth(duration: 0.3)) { coverBack = false } }
            }
            .overlay {
                if !starting, playable {
                    Button { playWatchCover() } label: {
                        Image(systemName: "play.fill").font(.system(size: 22, weight: .semibold))
                            .frame(width: 58, height: 58)
                            .glassSurface(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("Play"))
                    .accessibilityIdentifier("watch.play")
                }
            }
            .overlay(alignment: .topLeading) {
                // While it starts by itself nothing sits on the cover until it's tapped.
                if !starting || coverBack {
                    Button { dismiss() } label: { Image(systemName: "chevron.backward").font(.headline).frame(width: 22, height: 22) }
                        .chromeButton()
                        .accessibilityLabel(L10n.text("Back"))
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
    }

    private var watchDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(currentVideo().name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if let facts = tmdb.details?.facts, !facts.isEmpty {
                    Text(facts).font(.subheadline.weight(.medium)).lineLimit(2).transition(.opacity)
                }
                let meta = [currentVideo().remarks, currentVideo().year ?? "", SourceLabel(client.site.name).text].filter { !$0.isEmpty }
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if detail?.episodes.isEmpty == false {
                HStack(spacing: 10) { downloadButton(iconOnly: false); videoFavoriteButton }
            }
            playbackBanner
            tmdbStatus
            if let detail { synopsis(detail) }
            if detail != nil {
                watchEpisodes
                tmdbExtras.padding(.top, 6)
            } else if let error {
                errorCard(error)
            } else {
                DetailSkeleton()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }

    /// As in Bilibili's 选集: one row of episodes that scrolls sideways to the one playing, and All for the full list.
    /// A video with one episode has no row (its only episode is the video); several lines still show to choose from.
    @ViewBuilder private var watchEpisodes: some View {
        if let detail {
            if detail.episodes.isEmpty {
                Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
            } else {
                let items = activeEpisodes
                let compact = items.allSatisfy { EpisodeRow.title($0.name).count <= 5 }
                let stills = watchStills(items)
                VStack(alignment: .leading, spacing: 12) {
                    if items.count > 1 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            episodeOrderButton
                            Spacer(minLength: 8)
                            if items.count > (compact ? 5 : 2) {
                                Button { showsAllEpisodes = true } label: {
                                    HStack(spacing: 3) { Text(L10n.text("All")); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .frame(minHeight: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("watch.allEpisodes")
                            }
                        }
                    } else if flags.count > 1 {
                        Text(L10n.text("Lines")).font(.headline)
                    }
                    watchLines
                    if items.count > 1 {
                        // scrollPosition rather than ScrollViewReader: scrollTo also scrolls the page's vertical
                        // scroll view, which pushed the title under the player.
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: stills.isEmpty ? 8 : 12) { ForEach(shownOrder(items)) { watchEpisodeCard($0, compact: compact, info: stills[$0.id]) } }
                                .scrollTargetLayout()
                                .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.never)
                        .scrollPosition(id: $episodeScroll, anchor: .center)
                        .padding(.horizontal, -16)
                        .onAppear { episodeScroll = currentEpisodeID }
                        .onChange(of: currentEpisodeID) { _, id in if let id { withAnimation { episodeScroll = id } } }
                    }
                }
            }
        }
    }

    /// The lines, when there are several. Choosing one while an episode plays switches to it on that line.
    @ViewBuilder private var watchLines: some View {
        if flags.count > 1 {
            SourceStrip(items: flags.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Play") : $0) }, selection: activeFlag) { flag in
                selectedFlag = flag
                guard watchChannel != nil, let episodes = detail?.episodes else { return }
                let playing = episodes.first { $0.id == currentEpisodeID }
                let same = episodes.first { $0.flag == flag && $0.name == playing?.name } ?? episodes.first { $0.flag == flag }
                if let same, same.id != currentEpisodeID { startRequest { await play(same) } }
            }
        }
    }

    /// TMDB's stills for the line's episodes, when its season lines up with most of them and has pictures for them;
    /// otherwise none, and the episodes keep their small cards.
    private func watchStills(_ items: [Episode]) -> [Episode.ID: TMDBMatch.EpisodeInfo] {
        let stills = tmdb.episodes(items)
        return items.count > 1 && stills.values.filter { $0.still != nil }.count * 2 >= items.count ? stills : [:]
    }

    /// An episode: a small tile for short names (第1集, 01), a two-line card for long ones, TMDB's still above the name
    /// when there is one. The one playing is tinted in the accent. There is no per-episode favorite on this page.
    private func watchEpisodeCard(_ episode: Episode, compact: Bool, fill: Bool = false, info: TMDBMatch.EpisodeInfo? = nil,
                                  chosen: (() -> Void)? = nil) -> some View {
        let current = episode.id == currentEpisodeID
        let saved = download(episode)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            chosen?()
            // The episode already playing keeps playing.
            guard !(current && watchChannel != nil) else { return }
            startRequest { await play(episode) }
        } label: {
            if let info {
                TMDBEpisodeTile(name: EpisodeRow.title(episode.name), info: info, current: current, loading: loadingEpisode == episode.id,
                                width: fill ? nil : 168)
                    .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
            } else {
            HStack(spacing: 6) {
                if loadingEpisode == episode.id { ProgressView().controlSize(.small) }
                Text(EpisodeRow.title(episode.name)).lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(compact ? .center : .leading)
            }
            .font(.subheadline.weight(current ? .semibold : .regular))
            .foregroundStyle(current ? Brand.accent : Color.primary)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(width: fill ? nil : compact ? 64 : 150, height: compact ? 44 : 54, alignment: compact ? .center : .leading)
            .frame(maxWidth: fill ? .infinity : nil, alignment: compact ? .center : .leading)
            .background(current ? Brand.accent.opacity(0.14) : Color.primary.opacity(0.06), in: shape)
            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
            .contentShape(shape)
            }
        }
        .buttonStyle(.plain)
        .id(episode.id)
        .accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu {
            if saved == nil || saved?.status == .failed {
                Button(L10n.text("Download"), systemImage: "arrow.down.circle") {
                    DownloadLibrary.shared.download(DownloadSource(site: client.site, videoID: video.id, episode: episode),
                                                    title: video.name, poster: video.poster, posterHeaders: video.posterHeaders)
                }
            } else if let saved {
                Button(L10n.text(saved.status == .completed ? "Delete Download" : "Cancel Download"), systemImage: "trash", role: .destructive) {
                    DownloadLibrary.shared.remove([saved.id])
                }
            }
        }
    }

    private var allEpisodes: some View {
        let items = activeEpisodes
        let compact = items.allSatisfy { EpisodeRow.title($0.name).count <= 5 }
        let stills = watchStills(items)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    watchLines
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: stills.isEmpty ? (compact ? 64 : 150) : 160), spacing: stills.isEmpty ? 8 : 12, alignment: .top)],
                              spacing: stills.isEmpty ? 8 : 14) {
                        ForEach(shownOrder(items)) { watchEpisodeCard($0, compact: compact, fill: true, info: stills[$0.id]) { showsAllEpisodes = false } }
                    }
                }
                .padding(16)
            }
            .navigationTitle(L10n.text("Episodes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { episodeOrderButton }
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { showsAllEpisodes = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }
    #endif
}

#if os(iOS)
/// iPhone: a video's page is a watch page, its player at the top (`VideoDetailView`). Not on iPhone Duo's inner
/// display (regular both ways), which has an iPad's room.
enum WatchPage {
    @MainActor static func applies(_ horizontal: UserInterfaceSizeClass?, _ vertical: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !(horizontal == .regular && vertical == .regular)
    }
}

/// A swipe from the left edge goes back, as on any pushed page: hiding the navigation bar turns that gesture off.
/// It also comes before the picture's slide-to-seek and the episode row's scrolling, which would otherwise take a
/// swipe that starts at the edge.
struct EdgeSwipeBack: UIViewControllerRepresentable {
    /// Off in Full Screen, where the swipe would leave the page.
    var enabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.enabled = enabled }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var enabled = true
        private weak var recognizer: UIGestureRecognizer?
        private weak var previous: UIGestureRecognizerDelegate?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // Pushed from a search field still active (after Search was pressed), the bar the page hides stayed, and
            // its Back showed over the page's own.
            if navigationController?.isNavigationBarHidden == false { navigationController?.setNavigationBarHidden(true, animated: animated) }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // Again after a swipe that was let go halfway, which brings the page back.
            guard let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate !== self else { return }
            recognizer = pop; previous = pop.delegate
            pop.delegate = self; pop.isEnabled = true
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // The swipe already under way goes on; other pages get the system's own rules back.
            if let recognizer, recognizer.delegate === self { recognizer.delegate = previous }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            enabled && (navigationController?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            enabled && other is UIPanGestureRecognizer
        }
    }
}
#endif

extension PlaybackHistoryEntry {
    /// The watched title as a list card, to open its page with.
    var listVideo: Video {
        Video(id: context.videoID, name: context.videoName, poster: context.poster, posterHeaders: context.posterHeaders ?? [:], year: context.year)
    }
}

private struct PlaybackIssue {
    let episode: Episode
    let message: String
    let drive: CloudDrive?
    /// True when playback was not attempted because a required account is missing.
    let blockedBeforeRequest: Bool
    /// A sign-in the source's CatPawOpen bundle runs itself (`CatPawSignIn.provider(for:)`).
    var signIn: String? = nil
}

private struct BundleSignIn: Identifiable {
    let provider: String
    var id: String { provider }
}

/// Cloud drives whose plugins need a saved login before they can return a stream.
private enum CloudDrive: String, Identifiable {
    /// Xunlei's sign-in is only for CatPawOpen bundles, which say when it is missing; other sources play their Xunlei
    /// lines without it, so those lines are never held back for it.
    case quark, uc, xunlei
    var id: String { rawValue }
    /// FTY names its lines after drive nicknames: 夸父 is Quark, 优汐 is UC.
    init?(flag: String) {
        let text = flag.lowercased()
        if text.contains("夸克") || text.contains("夸父") || text.contains("quark") { self = .quark }
        else if text.hasPrefix("uc") || text.contains("uc网盘") || text.contains("优汐") { self = .uc }
        else if text.contains("迅雷") || text.contains("xunlei") { self = .xunlei }
        else { return nil }
    }
    /// Lines from drives that sign in through the plugin's own QR code (FTY's 嘟嘟 is Baidu, 阿狸 is
    /// Aliyun). They ask for a scan the first time, so they never start a title on their own.
    static func withoutSignIn(_ flag: String) -> Bool {
        let text = flag.lowercased()
        return ["嘟嘟", "百度", "度盘", "baidu", "阿狸", "阿里", "aliyun"].contains { text.contains($0) }
    }
    /// The first line that can play now: not from a drive without a sign-in, nor one whose sign-in is missing.
    static func preferredFlag(_ flags: [String]) -> String? {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        return flags.first { flag in
            if withoutSignIn(flag) { return false }
            guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return true }
            let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
            return !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var name: String {
        switch self {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .xunlei: L10n.text("Xunlei")
        }
    }
    var signInTitle: String {
        switch self {
        case .quark: L10n.text("Sign In to Quark")
        case .uc: L10n.text("Sign In to UC")
        case .xunlei: L10n.text("Sign In to %@", name)
        }
    }
    #if os(macOS)
    var provider: CloudProvider { self == .quark ? .quark : .uc }
    #else
    var qrDrive: CloudDriveQRLogin.Drive { self == .quark ? .quark : .uc }
    var webSignIn: WebSignIn { self == .quark ? .quark : .uc }
    #endif
    var loginHint: String { L10n.text("This source plays from %@ and needs you to sign in first.", name) }
    var expiredHint: String { L10n.text("Your %@ sign-in is missing or has expired. Sign in again to play this episode.", name) }
    static func missingLogin(forFlag flag: String) -> CloudDrive? {
        guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return nil }
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
        return cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? drive : nil
    }
    static func isLoginFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["授权", "登录", "扫码", "cookie", "login", "unauthorized"].contains { text.contains($0) }
    }
}

/// Episode names often lead with a size tag ("[1.18GB] S01E41.mkv"); show it as trailing detail.
private struct EpisodeRow: View {
    let name: String
    let loading: Bool
    var download: DownloadItem? = nil
    let action: () -> Void
    @State private var hovering = false
    static func split(_ name: String) -> (title: String, detail: String?) {
        if let match = name.firstMatch(of: /^\s*\[([^\]]+)\]\s*(.+)$/) { return (String(match.2), String(match.1)) }
        return (name, nil)
    }
    static func title(_ name: String) -> String { split(name).title }
    /// Row type and height per platform: a Mac list size is unreadable from a sofa.
    private static var metrics: (text: CGFloat, icon: CGFloat, height: CGFloat, inset: CGFloat) {
        #if os(tvOS)
        (28, 18, 42, 0) // GlassRowStyle adds its own padding and focus glass
        #elseif os(iOS)
        (15, 11, 44, 14)
        #else
        (13, 10, 36, 12)
        #endif
    }
    private var parts: (title: String, detail: String?) { Self.split(name) }
    var body: some View {
        let parts = parts
        let button = Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "play.fill").font(.system(size: Self.metrics.icon)).foregroundStyle(hovering ? .primary : .tertiary) }
                }
                .frame(width: Self.metrics.icon + 6)
                Text(parts.title).font(.system(size: Self.metrics.text, weight: loading ? .semibold : .medium))
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let detail = parts.detail {
                    Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
                if let download { DownloadState(item: download) }
            }
            .padding(.horizontal, Self.metrics.inset).frame(minHeight: Self.metrics.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if !os(tvOS)
            .background(Color.primary.opacity(loading ? 0.12 : (hovering ? 0.08 : 0.04)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            #endif
            .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        #if os(tvOS)
        button.glassRow()
        #else
        button.buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.15), value: hovering)
        #endif
    }
}

private struct DownloadLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 6) { configuration.icon; configuration.title } }
    }
}

/// Gives its one subview at least `minHeight`, even in a scroll view, where `frame(minHeight:)`
/// leaves the content at its ideal height and spacers inside it never grow.
private struct MinHeightLayout: SwiftUI.Layout {
    var minHeight: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: max(size.height, minHeight))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
