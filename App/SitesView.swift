import CoreImage
import SwiftUI
import TVCore

struct SitesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Choosing a source for something else (Watch Now's recommendations): only `pickable` sources are listed, the
    /// `picked` one is checked, and Select hands the source back and returns instead of opening it.
    var pick: ((Site) -> Void)? = nil
    var pickable: [Site] = []
    var picked: String? = nil
    @FocusState private var focusedSite: String?
    @State private var query = ""
    /// Groups the viewer folded. Every group starts open, subscriptions and hidden sources included,
    /// so nothing on the page needs finding, and stays as the viewer left it: a fold is saved and comes
    /// back on the next visit and launch (#517). Picking a source always starts open, so the current
    /// choice can be shown. `prepared` keeps the reload to once per visit, not per pushed source.
    @State private var collapsed: Set<String>
    @State private var prepared = false
    /// The fold as it was when a search began; restored when the search is cleared.
    @State private var foldBeforeSearch: Set<String>?
    @State private var arranging = false
    @State private var choosingHidden = false
    init(pick: ((Site) -> Void)? = nil, pickable: [Site] = [], picked: String? = nil) {
        self.pick = pick
        self.pickable = pickable
        self.picked = picked
        _collapsed = State(initialValue: pick == nil ? Self.savedFold : [])
    }
    private static let foldKey = "sources.foldedGroups"
    private static var savedFold: Set<String> { Set(UserDefaults.standard.stringArray(forKey: foldKey) ?? []) }
    var body: some View {
        Group {
            if let config = store.subscription {
                let groups = store.sourceGroups(includeHidden: false).filtered(by: query).limited(to: pick == nil ? nil : Set(pickable.map(\.key)))
                let sites = store.orderedSites(config)
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.cardSpacing) {
                        if pick == nil, query.isEmpty && sites.count > 1 {
                            VStack(alignment: .leading, spacing: Layout.cardSpacing) {
                                SourceOrderCard(sites: sites) { arranging = true }
                                HideSourcesCard(hidden: groups.first { $0.kind == .hidden }?.sites.count ?? 0) { choosingHidden = true }
                            }.tvFocusSection()
                        }
                        ForEach(groups) { group in
                            groupHeader(group)
                            if !collapsed.contains(group.id) {
                                LazyVGrid(columns: Layout.cardColumns, spacing: Layout.cardSpacing) {
                                    ForEach(group.sites) { site in
                                        if let pick {
                                            Button { pick(site); dismiss() } label: { SiteCard(site: site, chosen: site.key == picked) }.tileButton()
                                                .accessibilityAddTraits(site.key == picked ? .isSelected : [])
                                                .focused($focusedSite, equals: site.key)
                                                .id(site.key)
                                        } else {
                                        RouteLink { SiteView(site: site, origin: config.origin, jarURL: config.spiderURL) } label: { SiteCard(site: site, dimmed: group.kind == .hidden) }.tileButton()
                                            .contextMenu {
                                                PinSourceButton(site: site, origin: config.origin)
                                                HideSourceButton(site: site, origin: config.origin)
                                                if store.sourceOrder.enabled { MoveSourceButtons(site: site, sites: sites) }
                                            }
                                        }
                                    }
                                }
                                // Unfolds from under its header; folding only fades, as the groups below slide up.
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -16)), removal: .opacity))
                            }
                        }
                    }.pageContainer()
                }
                // Picking opens on the current choice rather than the top of a long page.
                .defaultFocus($focusedSite, picked)
                .onAppear { if pick != nil, let picked { proxy.scrollTo(picked, anchor: .center) } }
                }
                .sheet(isPresented: $arranging) { SourceOrderEditor(sites: sites, automatic: store.automaticSites(config)) }
                .sheet(isPresented: $choosingHidden) { HiddenSourcesEditor() }
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
        .catalogSearchable(text: $query, prompt: L10n.text("Find a source"))
        .modifier(SitesTitle(picking: pick != nil))
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
            // A search opens every group for the moment; only the page's own fold is kept.
            if pick == nil && query.isEmpty { UserDefaults.standard.set(collapsed.sorted(), forKey: Self.foldKey) }
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

    /// The page as the viewer last left it: every group open unless they folded it.
    private func applyDefaultFold() {
        collapsed = pick == nil ? Self.savedFold : []
        foldBeforeSearch = nil
    }
}

/// The Sources tab names itself in the sidebar; a page pushed to pick a source says what is being chosen.
private struct SitesTitle: ViewModifier {
    let picking: Bool
    func body(content: Content) -> some View {
        if picking { content.screenTitle(L10n.text("Recommendation Source")) } else { content.tabTitle(L10n.text("Sources")) }
    }
}

private extension Array where Element == SourceGroup {
    /// Only these sources, when given; groups left empty drop out.
    func limited(to keys: Set<String>?) -> [SourceGroup] {
        guard let keys else { return self }
        return compactMap { group in
            var kept = group
            kept.sites = group.sites.filter { keys.contains($0.key) }
            return kept.sites.isEmpty ? nil : kept
        }
    }

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
    /// Whether this is the source currently chosen, when picking one (`SitesView.pick`); nil when not picking.
    var chosen: Bool? = nil
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
            if chosen == true {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(focused ? Color.black : Brand.accent)
                    .accessibilityHidden(true)
            }
            #if !os(tvOS)
            if chosen == nil { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
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
            MonogramIcon(seed: site.name, label: label, size: size, systemImage: site.symbol)
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

/// Opens `HiddenSourcesEditor`, under the search order on the sources page.
struct HideSourcesCard: View {
    let hidden: Int
    let open: () -> Void
    private var value: String { hidden > 0 ? L10n.text("%lld hidden", hidden) : "" }
    var body: some View {
        #if os(tvOS)
        Button(action: open) { TVSettingsRowLabel(title: L10n.text("Hide or Show Sources"), value: value, chevron: true) }
            .glassRow()
            .accessibilityIdentifier("sources.hidden.open")
        #else
        Button(action: open) {
            HStack(spacing: 14) {
                IconTile(symbol: "eye.slash", tint: Brand.teal, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Hide or Show Sources")).font(.headline).foregroundStyle(.primary)
                    Text(L10n.text("Choose many sources at once, or a whole subscription.")).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !value.isEmpty { Text(value).font(.subheadline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentPanel(cornerRadius: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sources.hidden.open")
        #endif
    }
}

/// Hiding or showing many sources at once: a ticked source is shown; Show All and Hide All take a whole group.
/// Sources stay in their own group here, hidden or not, and each change is saved at once.
struct HiddenSourcesEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    private func isHidden(_ site: Site) -> Bool {
        store.subscription.map { store.hiddenSources.contains(site, origin: $0.origin) } ?? false
    }
    private func setHidden(_ sites: [Site], _ hidden: Bool) {
        guard let config = store.subscription else { return }
        store.hiddenSources.setHidden(sites, origin: config.origin, hidden: hidden)
    }

    var body: some View {
        let groups = store.sourceGroups(includeHidden: true)
        let hiddenCount = groups.flatMap(\.sites).filter(isHidden).count
        #if os(tvOS)
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Ticked sources are shown. Hidden sources stay out of Watch Now and search."))
                        .font(.system(size: 24)).foregroundStyle(.secondary).padding(.bottom, 12)
                    if hiddenCount > 0 {
                        TVSettingsAction(title: L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }
                            .padding(.bottom, 16)
                    }
                    ForEach(groups) { group in
                        let hidden = group.sites.filter(isHidden)
                        Text(L10n.text(group.title)).font(.system(size: 31, weight: .semibold)).lineLimit(1)
                            .padding(.top, 20).padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        HStack(spacing: 16) {
                            TVSettingsAction(title: L10n.text("Show All")) { setHidden(group.sites, false) }.disabled(hidden.isEmpty)
                            TVSettingsAction(title: L10n.text("Hide All")) { setHidden(group.sites, true) }.disabled(hidden.count == group.sites.count)
                        }
                        .focusSection()
                        ForEach(group.sites) { site in
                            let shown = !isHidden(site)
                            Button { setHidden([site], shown) } label: {
                                TVSettingsRowLabel(title: SourceLabel(site.name).parts[0], value: shown ? nil : L10n.text("Hidden")) {
                                    Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.system(size: 30))
                                }
                            }
                            .glassRow()
                            .accessibilityAddTraits(shown ? [.isSelected] : [])
                            .accessibilityIdentifier("sources.hidden.row." + site.key)
                        }
                    }
                }
                .glassRowInsets()
            }
            .screenTitle(L10n.text("Hide or Show Sources"))
            .screenBackdrop()
        }
        .frame(width: 1100, height: 800)
        .onExitCommand { dismiss() }
        #else
        NavigationStack {
            List {
                Section {
                    Text(L10n.text("Ticked sources are shown. Hidden sources stay out of Watch Now and search."))
                        .font(.subheadline).foregroundStyle(.secondary)
                        #if os(iOS)
                        .listRowBackground(Surface())
                        #endif
                }
                ForEach(groups) { group in
                    let hidden = group.sites.filter(isHidden)
                    Section {
                        ForEach(group.sites) { site in
                            let shown = !isHidden(site)
                            Button { setHidden([site], shown) } label: { HiddenSourceRow(site: site, shown: shown) }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(shown ? [.isSelected] : [])
                                .accessibilityIdentifier("sources.hidden.row." + site.key)
                                #if os(iOS)
                                .listRowBackground(Surface())
                                #endif
                        }
                    } header: {
                        HStack(spacing: 12) {
                            Text(L10n.text(group.title)).lineLimit(1)
                            Spacer(minLength: 8)
                            Button(L10n.text("Show All")) { setHidden(group.sites, false) }.disabled(hidden.isEmpty)
                            Button(L10n.text("Hide All")) { setHidden(group.sites, true) }.disabled(hidden.count == group.sites.count)
                        }
                        .buttonStyle(.borderless)
                        .textCase(nil)
                    }
                }
            }
            #if os(iOS)
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(L10n.text("Hide or Show Sources"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { dismiss() }.fontWeight(.semibold)
                        .accessibilityIdentifier("sources.hidden.done")
                }
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Button(L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }.disabled(hiddenCount == 0)
                }
                #else
                ToolbarItem(placement: .destructiveAction) {
                    Button(L10n.text("Show All Sources")) { setHidden(groups.flatMap(\.sites), false) }.disabled(hiddenCount == 0)
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 600)
        #endif
        #endif
    }
}

#if !os(tvOS)
/// One source in `HiddenSourcesEditor`: a tick while it is shown, its icon and name.
private struct HiddenSourceRow: View {
    let site: Site
    let shown: Bool
    var body: some View {
        let label = SourceLabel(site.name)
        HStack(spacing: 12) {
            Image(systemName: shown ? "checkmark.circle.fill" : "circle").font(.title3)
                .foregroundStyle(shown ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
            SourceIcon(site: site, label: label, size: 32).opacity(shown ? 1 : 0.45)
            Text(label.parts[0]).font(.body.weight(.medium)).lineLimit(1)
                .foregroundStyle(shown ? Color.primary : Color.secondary)
            Spacer(minLength: 8)
            if !shown { Text(L10n.text("Hidden")).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
#endif

struct SiteView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let origin: URL
    let jarURL: URL?
    var initialQuery: String = ""
    /// A drive source's folder: the page lists it in place of the source's home.
    var folder: Video? = nil
    /// The source's home as another page already has it (Watch Now's recommendations): shown at once, then refreshed.
    var preview: (videos: [Video], categories: [TVCore.Category])? = nil
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
            } else if showsBilibiliTVSpace {
                bilibiliTVSpace
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
                        if site.isBilibili && !isBilibiliSpace && !BilibiliAccount.load().signedIn { BilibiliSignInBanner() }
                        // An UP主's space (#256): who they are, Follow, and their uploads by order or their collections.
                        if site.isBilibili, let folder, let mid = BilibiliAPI.creator(category: folder.id) {
                            BilibiliSpaceHeader(mid: mid, name: folder.name, client: client,
                                                category: browser.category.isEmpty ? folder.id : browser.category) { id in
                                startRequest { await browser.load(.list(category: id, query: "", page: 1), client: client) }
                            }
                        }
                        if !browser.categories.isEmpty { categoryBar } else if initialLoading && folder == nil { ChipSkeletonRow() }
                        if browser.query.isEmpty, let current = browser.categories.first(where: { $0.id == browser.category }), !current.filters.isEmpty {
                            CategoryFilterBar(filters: current.filters, choices: browser.filters) { choices in
                                startRequest { await browser.load(.list(category: current.id, query: "", page: 1, filters: choices), client: client) }
                            }
                        }
                        // The Bilibili source's home (#256): rows of the account's lists, live rooms and popular videos above
                        // the recommendations.
                        if site.isBilibili, folder == nil, browser.query.isEmpty, browser.category.isEmpty {
                            BilibiliShelves(client: client, ready: browser.loaded && !browser.videos.isEmpty) { id in
                                startRequest { await browser.load(.list(category: id, query: "", page: 1), client: client) }
                            }
                        }
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
                        let landscape = showsBilibiliTiles
                        LazyVGrid(columns: landscape ? Self.bilibiliColumns : Layout.posterColumns, spacing: Layout.gridRowSpacing) {
                            ForEach(browser.videos) { video in
                                Group {
                                    // An index source (a ranking or list site) names titles; other sources play them.
                                    if isIndex {
                                        Button { store.searchVideos(video.name) } label: { PosterCard(video: video) }.cardButton()
                                    } else if landscape {
                                        RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video, width: nil) }.cardButton()
                                    } else {
                                        RouteLink { CatalogDestination(video: video, client: client) } label: { PosterCard(video: video) }.cardButton()
                                    }
                                }
                                .onAppear {
                                    // The last cover coming on screen appends the next page, so scrolling never stops
                                    // at a page boundary. A failed page waits for the footer's Retry instead.
                                    guard browser.moreError == nil, video.id == browser.videos.last?.id else { return }
                                    Task { await loadMore() }
                                }
                            }
                        }
                        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
                        if !browser.videos.isEmpty && (browser.hasMore || browser.loadingMore || browser.moreError != nil) {
                            // A focus section, so moving down from a cover in any column reaches Load More or Try Again.
                            loadMoreFooter.tvFocusSection()
                        }
                    }.pageContainer()
                }
                .catalogSearchable(text: Binding(get: { query }, set: { value in
                    query = value
                    if value.isEmpty && !browser.query.isEmpty { startRequest { await home() } }
                }), prompt: L10n.text("Search videos"))
                .onSubmit(of: .search) { startRequest { await search() } }
            }
        }
        .onDisappear { requestTask?.cancel(); browser.cancel() }
        .toolbar {
            // Handed the store: UIKit can size a bar item before SwiftUI gives it the page's environment, and these
            // buttons read Store first thing (a TestFlight crash on iPhone).
            if !showsBilibiliTVSpace {
                Group {
                    PinSourceButton(site: site, origin: origin)
                    HideSourceButton(site: site, origin: origin)
                }
                .environment(store)
            }
        }
        .screenBackdrop()
        .onAppear {
            guard site.isBilibili, browser.loaded else { return }
            let login = BilibiliAccount.load().cookie
            if login != bilibiliLogin { bilibiliLogin = login; query = ""; startRequest { await home(); await browser.loadCategories(client: client) } }
        }
        // An UP主's space names them in its hero; a title over it only repeated it.
        .screenTitle(isBilibiliSpace ? "" : folder?.name ?? site.name, shown: !showsBilibiliTVSpace).task {
            store.searchModel.suspend()
            if let preview, folder == nil, initialQuery.isEmpty { browser.seed(videos: preview.videos, categories: preview.categories) }
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
                            let filters = CategoryFilter.initialChoices(item.filters)
                            startRequest { await browser.load(.list(category: item.id, query: "", page: 1, filters: filters), client: client) }
                        }
                    }
                }
            }.padding(.vertical, 4)
        }
    }
    @ViewBuilder private var loadMoreFooter: some View {
        if let message = browser.moreError {
            VStack(spacing: 12) {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(L10n.text("Try Again")) { startRequest { await loadMore() } }
                    .controlButton()
                    .accessibilityIdentifier("site.loadMore.retry")
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
        } else if browser.loadingMore {
            ProgressView().appControlSize(.large)
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .accessibilityLabel(L10n.text("Loading…"))
        } else if browser.hasMore {
            Button(L10n.text("Load More")) { startRequest { await loadMore() } }
                .controlButton()
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .accessibilityIdentifier("site.loadMore")
        }
    }
    private func home() async { await browser.load(folder.map { .list(category: $0.id, query: "", page: 1) } ?? .home, client: client) }
    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { await home() }
        else { await browser.load(.list(category: nil, query: text, page: 1), client: client) }
    }
    private func loadMore() async { await browser.loadMore(client: client) }
}

/// A category's filters (TVBox `filters`: 类型, 地区, 年份…) drawn as Discover's catalog search draws its own: one
/// "地区：全部 ⌄" chip per filter. On the Mac a chip opens a popover of choices, on iPhone, iPad and Apple TV a
/// menu. Each choice reloads the category from its first page.
struct CategoryFilterBar: View {
    let filters: [CategoryFilter]
    let choices: [String: String]
    let choose: ([String: String]) -> Void
    #if os(macOS)
    @State private var open: String?
    #endif

    private func value(_ filter: CategoryFilter) -> String { choices[filter.key] ?? filter.initial }
    private func changed(_ filter: CategoryFilter) -> Bool { value(filter) != filter.initial }
    private var anyChanged: Bool { filters.contains(where: changed) }
    private func title(_ filter: CategoryFilter) -> String {
        let current = value(filter)
        let choice = filter.options.first { $0.value == current }?.name ?? current
        return filter.name.isEmpty ? choice : filter.name + "：" + choice
    }
    private func pick(_ filter: CategoryFilter, _ option: String) {
        guard value(filter) != option else { return }
        var next = choices
        next[filter.key] = option
        choose(next)
    }
    private func reset() { choose(CategoryFilter.initialChoices(filters)) }

    var body: some View {
        #if os(macOS)
        DiscoverChipFlow(spacing: 8) {
            ForEach(filters) { filter in
                Button { open = open == filter.key ? nil : filter.key } label: { FilterChipLabel(title: title(filter), open: open == filter.key) }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(get: { open == filter.key }, set: { if !$0, open == filter.key { open = nil } }), arrowEdge: .bottom) {
                        panel(filter)
                    }
                    .accessibilityIdentifier("site.filter.\(filter.key)")
            }
            if anyChanged {
                Button(action: reset) {
                    Label(L10n.text("Reset Filters"), systemImage: "xmark").font(.system(size: 13)).padding(.horizontal, 12).frame(height: 30)
                        .contentShape(Capsule())
                }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityIdentifier("site.filters.reset")
            }
        }
        .accessibilityIdentifier("site.filters")
        #if DEBUG
        // `-qaOpenFilter <key>` opens that filter's choices, for screenshots.
        .task { if let key = UserDefaults.standard.string(forKey: "qaOpenFilter") { try? await Task.sleep(for: .seconds(1)); open = key } }
        #endif
        #elseif os(tvOS)
        ScrollView(.horizontal) {
            HStack(spacing: 18) {
                ForEach(filters) { filter in
                    Menu { picker(filter) } label: { Text(title(filter)) }
                        .menuStyle(.button)
                        .buttonStyle(DiscoverTVChipStyle(active: changed(filter)))
                        .accessibilityIdentifier("site.filter.\(filter.key)")
                }
                if anyChanged {
                    Button(action: reset) { Label(L10n.text("Reset Filters"), systemImage: "xmark") }
                        .buttonStyle(DiscoverTVChipStyle(active: false))
                        .accessibilityIdentifier("site.filters.reset")
                }
            }.padding(.vertical, 16)
        }
        .scrollIndicators(.hidden).scrollClipDisabled().focusSection()
        .accessibilityIdentifier("site.filters")
        #else
        ScrollView(.horizontal) {
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(filters) { filter in
                        Menu { picker(filter) } label: { FilterChipLabel(title: title(filter)) }
                            .accessibilityIdentifier("site.filter.\(filter.key)")
                    }
                    if anyChanged {
                        Button(action: reset) { Image(systemName: "xmark").frame(width: 38, height: 38).glassSurface(.regular, in: Circle()) }
                            .accessibilityLabel(L10n.text("Reset Filters")).accessibilityIdentifier("site.filters.reset")
                    }
                }
            }
        }
        .scrollIndicators(.hidden).scrollClipDisabled().frame(height: 38)
        .tint(.primary)
        .accessibilityIdentifier("site.filters")
        #endif
    }

    #if os(macOS)
    /// The filter's choices as Discover's filter popovers lay them out; a long list (years) scrolls.
    private func panel(_ filter: CategoryFilter) -> some View {
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(filter.options, id: \.value) { option in
                FilterChoiceButton(title: option.name, selected: value(filter) == option.value) {
                    pick(filter, option.value)
                    open = nil
                }
            }
        }.padding(14)
        return Group {
            if filter.options.count > 30 { ScrollView { grid }.frame(height: 340) } else { grid }
        }
        .frame(width: 360)
    }
    #else
    private func picker(_ filter: CategoryFilter) -> some View {
        Picker(filter.name, selection: Binding(get: { value(filter) }, set: { pick(filter, $0) })) {
            ForEach(filter.options, id: \.value) { Text($0.name).tag($0.value) }
        }
    }
    #endif
}

/// Where a listed title opens: its details, for a drive source's folder the folder's listing, and for a plugin
/// setting listed among titles (`Video.action`) that setting.
struct CatalogDestination: View {
    let video: Video
    let client: CatalogClient
    var body: some View {
        if let action = video.action { PluginActionPage(video: video, client: client, action: action) }
        else if video.isFolder { SiteView(site: client.site, origin: client.origin, jarURL: client.jarURL, folder: video) }
        else { VideoDetailView(video: video, client: client) }
    }
}

/// A plugin setting listed among a source's titles (aowu's 配置中心, FTY's 我的云盘┃配置). It runs in the plugin, as
/// in TVBox; the window the plugin opens for it is drawn here (`PluginScreen`), and the viewer's taps and typing go
/// back to the plugin's own code.
struct PluginActionPage: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let video: Video
    let client: CatalogClient
    let action: String
    private enum Phase: Equatable { case running, showing, finished(String?), failed(String) }
    @State private var phase = Phase.running
    @State private var screen = PluginScreen()
    /// What the viewer typed, by field, until it goes to the plugin with the next tap.
    @State private var typed: [Int: String] = [:]
    @State private var sending = false
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            switch phase {
            case .running:
                ProgressView().padding(.vertical, 80).frame(maxWidth: .infinity)
            case .showing:
                if let window = screen.windows.last {
                    PluginWindowView(window: window, typed: $typed, layers: screen.windows.count, send: send)
                        .id(window.id)
                        .disabled(sending)
                }
            case .finished(let message):
                // Back is focusable, so the remote has somewhere to land on Apple TV.
                EmptyResults(symbol: message == nil ? "checkmark.circle" : "info.circle", title: video.name,
                             message: message ?? L10n.text("The plugin finished without a message."),
                             action: L10n.text("Back"), actionSymbol: "chevron.backward") { dismiss() }
                // Each tap runs the setting once more, as a tap on its row does in TVBox: settings that ask for a
                // double tap to confirm (a reset) take two quick taps here. Never disabled, so the second tap counts.
                Button { runAgain() } label: { Label(L10n.text("Run Again"), systemImage: "hand.tap").padding(.horizontal, 8) }
                    .controlButton()
                    .accessibilityIdentifier("pluginSetting.runAgain")
            case .failed(let message):
                EmptyResults(symbol: "exclamationmark.triangle", title: video.name, message: message,
                             action: L10n.text("Try Again")) { Task { await run() } }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassPanel(cornerRadius: 22)
                    .padding(.bottom, 24).padding(.horizontal, 24)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: notice)
        .navigationTitle(video.name)
        .task { await run() }
        .task(id: phase == .showing) {
            // Plugins change their windows on their own (a QR code arriving, a sign-in confirmed): look again.
            guard phase == .showing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, !sending, let window = screen.windows.last else { continue }
                await deliver(PluginEvent(window: window.id, kind: .poll), quietly: true)
            }
        }
        .onDisappear {
            noticeTask?.cancel()
            guard let window = screen.windows.last else { return }
            let client = client
            Task { _ = try? await client.pluginWindow(PluginEvent(window: window.id, kind: .closeAll)) }
        }
    }

    private func run() async {
        phase = .running
        typed = [:]
        do { show(try await client.runAction(action), first: true) }
        catch is CancellationError { }
        catch { phase = .failed(error.localizedDescription) }
    }

    private func runAgain() {
        Task {
            do { show(try await client.runAction(action), first: true) }
            catch is CancellationError { }
            catch { phase = .failed(error.localizedDescription) }
        }
    }

    /// A page the plugin opens. A sign-in page that only works in its service's app (Bilibili's confirmation page)
    /// goes there when the app is on this device; anything else, or no app, opens as it is.
    private func open(_ link: URL) {
        #if os(iOS)
        let tries = (DriveAppLink.app(opening: link)?.urls ?? []) + [link]
        #else
        let tries = [link]
        #endif
        func attempt(_ index: Int) {
            guard index < tries.count else { return }
            openURL(tries[index]) { opened in if !opened { attempt(index + 1) } }
        }
        attempt(0)
    }

    #if DEBUG
    private static func find(_ text: String, in node: PluginNode) -> PluginNode? {
        if node.tappable, node.spokenText.contains(text) { return node.children.lazy.compactMap { find(text, in: $0) }.first ?? node }
        return node.children.lazy.compactMap { find(text, in: $0) }.first
    }
    #endif

    private func send(_ event: PluginEvent) {
        var event = event
        // Typed text reaches the plugin's fields before the tap runs, as on Android.
        for (field, text) in typed where event.values[field] == nil { event.values[field] = .text(text) }
        Task { await deliver(event, quietly: false) }
    }

    private func deliver(_ event: PluginEvent, quietly: Bool) async {
        if !quietly { sending = true }
        defer { if !quietly { sending = false } }
        do { show(try await client.pluginWindow(event), first: false) }
        catch is CancellationError { }
        catch { if !quietly { phase = .failed(error.localizedDescription) } }
    }

    private func show(_ next: PluginScreen, first: Bool) {
        if screen.windows.last?.id != next.windows.last?.id { typed = [:] }
        screen = next
        for link in next.links { open(link) }
        var said = next.notices.joined(separator: "\n")
        if let copied = next.clipboard {
            // What the plugin copied goes on the pasteboard (Apple TV has none, so it is shown instead).
            #if os(iOS)
            UIPasteboard.general.string = copied
            if said.isEmpty { said = L10n.text("Copied to the clipboard.") }
            #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(copied, forType: .string)
            if said.isEmpty { said = L10n.text("Copied to the clipboard.") }
            #else
            said = said.isEmpty ? copied : said + "\n" + copied
            #endif
        }
        if next.windows.isEmpty {
            // The setting is done: what it said stays on the page; with nothing to say the page goes.
            let failure = next.error.map { L10n.text("The plugin stopped with an error: %@", $0) }
            let message = [first ? next.message : nil, said.isEmpty ? nil : said, failure].compactMap { $0 }.joined(separator: "\n")
            if message.isEmpty && !first { dismiss() } else { phase = .finished(message.isEmpty ? nil : message) }
            return
        }
        phase = .showing
        #if DEBUG
        // `-qaPluginTap <text>` taps the first view showing that text in the plugin's first window, for screenshots.
        if first, let wanted = UserDefaults.standard.string(forKey: "qaPluginTap"), let window = next.windows.last,
           let target = window.root.flatMap({ Self.find(wanted, in: $0) }) {
            Task { try? await Task.sleep(for: .seconds(1)); send(PluginEvent(window: window.id, kind: .click, view: target.id)) }
        }
        #endif
        guard !said.isEmpty else { return }
        notice = said
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { notice = nil }
        }
    }
}

/// A QR code in a plugin window (a sign-in page, TVBox's "remote input" page) can't be scanned by the device showing
/// it, so its link opens here. A page the plugin serves from this device (its network address) opens in the app, which
/// has to keep running to answer it; other links open as links do. Apple TV has no browser: its codes are scanned.
private struct PluginCodeLink: View {
    let image: Data
    @State private var link: URL?
    @State private var showsPage = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        #if os(tvOS)
        EmptyView()
        #else
        Group {
            if let link {
                Button { open(link) } label: { Label(L10n.text("Open Link"), systemImage: "link").padding(.horizontal, 8) }
                    .controlButton()
                    .accessibilityIdentifier("pluginSetting.openCode")
            }
        }
        .task(id: image) { link = await Self.decode(image) }
        #if os(iOS)
        .sheet(isPresented: $showsPage) {
            if let link { ConfigCenterView { ConfigCenter.local(link) ?? link } }
        }
        #endif
        #endif
    }

    private func open(_ url: URL) {
        #if os(iOS)
        if ConfigCenter.local(url) != nil { showsPage = true } else { openURL(url) }
        #else
        openURL(ConfigCenter.local(url) ?? url)
        #endif
    }

    /// The web address a QR code in the picture holds, if any.
    nonisolated static func decode(_ data: Data) async -> URL? {
        guard let picture = CIImage(data: data),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        else { return nil }
        for case let code as CIQRCodeFeature in detector.features(in: picture) {
            guard let text = code.messageString?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            return url
        }
        return nil
    }
}

/// One plugin window, drawn from the plugin's own views. When the plugin paints its window (most do: white
/// cards), its colors are kept on that surface; a plain Android alert takes the app's look instead.
private struct PluginWindowView: View {
    let window: PluginWindow
    @Binding var typed: [Int: String]
    /// Windows open, this one included: under another one, Back returns to it.
    let layers: Int
    let send: (PluginEvent) -> Void
    #if os(tvOS)
    static let scale = 1.7
    private let width: CGFloat = 1100
    #else
    static let scale = 1.0
    private let width: CGFloat = 620
    #endif

    var body: some View {
        let painted = window.surface.map { $0.alpha > 0.5 } ?? false
        VStack(alignment: .leading, spacing: 14 * Self.scale) {
            if layers > 1 {
                Button { send(PluginEvent(window: window.id, kind: .back)) } label: {
                    Label(L10n.text("Back"), systemImage: "chevron.backward")
                }
                .buttonStyle(.bordered)
            }
            if let title = window.title { Text(title).font(.headline) }
            if let message = window.message { Text(message).font(.body).fixedSize(horizontal: false, vertical: true) }
            if let header = window.header { PluginNodeView(node: header, context: context(painted)) }
            if let root = window.root { PluginNodeView(node: root, context: context(painted)) }
            if !window.items.isEmpty { items }
            if let progress = window.progress { PluginNodeView(node: progress, context: context(painted)) }
            if !window.buttons.isEmpty { buttons }
        }
        .padding(painted ? 0 : 20 * Self.scale)
        .frame(maxWidth: width, alignment: .leading)
        .background {
            if let surface = window.surface, painted {
                RoundedRectangle(cornerRadius: 18 * Self.scale, style: .continuous).fill(surface.color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18 * Self.scale, style: .continuous))
        .environment(\.colorScheme, painted ? ((window.surface?.luminance ?? 0) > 0.5 ? .light : .dark) : colorSchemeFallback)
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    @Environment(\.colorScheme) private var colorSchemeFallback

    private func context(_ painted: Bool) -> PluginNodeView.Context {
        PluginNodeView.Context(window: window.id, painted: painted, typed: $typed, send: send)
    }

    private var items: some View {
        VStack(spacing: 8) {
            ForEach(Array(window.items.enumerated()), id: \.offset) { index, item in
                Button { send(PluginEvent(window: window.id, kind: .item, index: index)) } label: {
                    HStack {
                        Text(item.text).frame(maxWidth: .infinity, alignment: .leading)
                        if window.choice == .multi {
                            Image(systemName: item.checked == true ? "checkmark.square.fill" : "square").foregroundStyle(.tint)
                        } else if item.checked == true {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PluginTapStyle())
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            ForEach(window.buttons.sorted { order($0.role) < order($1.role) }) { button in
                if button.role == .positive {
                    Button(button.text) { send(PluginEvent(window: window.id, kind: .click, view: button.id)) }
                        .buttonStyle(.borderedProminent).disabled(!button.enabled)
                } else {
                    Button(button.text) { send(PluginEvent(window: window.id, kind: .click, view: button.id)) }
                        .buttonStyle(.bordered).disabled(!button.enabled)
                }
            }
        }
    }

    /// Android's order: neutral first, then negative, positive last.
    private func order(_ role: PluginWindow.Button.Role) -> Int {
        switch role { case .neutral: 0; case .negative: 1; case .positive: 2 }
    }
}

private struct PluginNodeView: View {
    struct Context {
        let window: Int
        /// The window has the plugin's own background, so its colors are kept.
        let painted: Bool
        let typed: Binding<[Int: String]>
        let send: (PluginEvent) -> Void
        func tap(_ node: PluginNode) { send(PluginEvent(window: window, kind: .click, view: node.id)) }
        func change(_ node: PluginNode, _ value: PluginEvent.Value) { send(PluginEvent(window: window, kind: .change, values: [node.id: value])) }
    }
    let node: PluginNode
    let context: Context
    private var scale: Double { PluginWindowView.scale }

    var body: some View {
        content
            .opacity(node.enabled ? (node.alpha ?? 1) : 0.45)
    }

    @ViewBuilder private var content: some View {
        switch node.kind {
        case .stack, .scroll, .radios: tappable(container)
        case .text: tappable(label(node))
        case .button:
            Button { context.tap(node) } label: { label(node).frame(maxWidth: node.fillWidth ? .infinity : nil) }
                .buttonStyle(.bordered).disabled(!node.enabled)
        case .input: field
        case .check, .switch:
            Toggle(isOn: Binding(get: { node.checked }, set: { context.change(node, .on($0)) })) { label(node) }
                .disabled(!node.enabled)
        case .radio:
            Button { if !node.checked { context.change(node, .on(true)) } } label: {
                HStack(spacing: 10) {
                    Image(systemName: node.checked ? "largecircle.fill.circle" : "circle").foregroundStyle(.tint)
                    label(node)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PluginTapStyle())
        case .progress:
            if node.indeterminate { ProgressView().frame(maxWidth: .infinity) }
            else { ProgressView(value: Double(node.progress - node.minimum), total: Double(max(1, node.maximum - node.minimum))) }
        case .slider: slider
        case .image: tappable(picture)
        case .view: spacer
        }
    }

    // Containers: Android's LinearLayout and FrameLayout, each child with its share of the line.
    @ViewBuilder private var container: some View {
        let spacing = 8 * scale
        switch node.axis {
        case .h:
            let row = HStack(alignment: .center, spacing: spacing) { children }
            if node.kind == .scroll { ScrollView(.horizontal, showsIndicators: false) { row } }
            else { ViewThatFits(in: .horizontal) { row; ScrollView(.horizontal, showsIndicators: false) { row } } }
        case .z:
            ZStack(alignment: .topLeading) { children }
        case .v:
            VStack(alignment: node.centered ? .center : .leading, spacing: spacing) { children }
        }
    }

    @ViewBuilder private var children: some View {
        ForEach(node.children) { child in
            let view = PluginNodeView(node: child, context: context)
            if node.axis == .h, child.weight != nil { view.frame(maxWidth: .infinity, alignment: child.trailing ? .trailing : .leading) }
            else if node.axis == .v, child.fillWidth { view.frame(maxWidth: .infinity, alignment: child.centered ? .center : child.trailing ? .trailing : .leading) }
            else { view }
        }
    }

    /// A view with a listener is a button; one the plugin paints gets its color and rounded plate.
    @ViewBuilder private func tappable(_ inner: some View) -> some View {
        let plated = inner
            .padding(insets)
            .background { if let plate { RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(plate) } }
        if node.tappable {
            Button { context.tap(node) } label: { plated.contentShape(Rectangle()) }
                .buttonStyle(PluginTapStyle())
                .disabled(!node.enabled)
                .accessibilityLabel(node.spokenText)
        } else {
            plated
        }
    }

    /// The plugin's own padding; a painted plate without one still gets room around its content.
    private var insets: EdgeInsets {
        if let p = node.padding { return EdgeInsets(top: p[1] * scale, leading: p[0] * scale, bottom: p[3] * scale, trailing: p[2] * scale) }
        let room = plate == nil ? 0 : 10 * scale
        return EdgeInsets(top: room, leading: room, bottom: room, trailing: room)
    }

    private var plate: Color? {
        guard let background = node.background, background.alpha > 0.05 else { return nil }
        if context.painted { return background.color }
        return node.selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15)
    }

    private func label(_ node: PluginNode) -> some View {
        Text(node.text ?? "")
            .font(.system(size: (node.size ?? 15) * scale, weight: node.bold ? .semibold : .regular))
            .foregroundStyle(textColor(node))
            .lineLimit(node.lines)
            .multilineTextAlignment(node.centered ? .center : node.trailing ? .trailing : .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func textColor(_ node: PluginNode) -> Color {
        guard context.painted, let color = node.color else { return node.selected ? .accentColor : .primary }
        return color.color
    }

    @ViewBuilder private var field: some View {
        let text = Binding(get: { context.typed.wrappedValue[node.id] ?? node.text ?? "" },
                           set: { context.typed.wrappedValue[node.id] = $0 })
        let prompt = Text(node.hint ?? "")
        Group {
            if node.secure { SecureField(node.hint ?? "", text: text, prompt: prompt) }
            else if node.multiline { TextField(node.hint ?? "", text: text, prompt: prompt, axis: .vertical).lineLimit(3...8) }
            else { TextField(node.hint ?? "", text: text, prompt: prompt) }
        }
        #if !os(tvOS)
        .textFieldStyle(.roundedBorder)
        #endif
        #if os(iOS)
        .keyboardType(node.keyboard == "number" ? .numberPad : node.keyboard == "url" ? .URL : node.keyboard == "email" ? .emailAddress : .default)
        .textInputAutocapitalization(.never)
        #endif
        .autocorrectionDisabled()
        .onSubmit { context.send(PluginEvent(window: context.window, kind: .submit, view: node.id, values: [node.id: .text(text.wrappedValue)])) }
        .disabled(!node.enabled)
    }

    @ViewBuilder private var slider: some View {
        #if os(tvOS)
        HStack(spacing: 20) {
            Button { context.change(node, .number(max(node.minimum, node.progress - node.step))) } label: { Image(systemName: "minus") }
            Text("\(node.progress)").monospacedDigit().frame(minWidth: 80)
            Button { context.change(node, .number(min(node.maximum, node.progress + node.step))) } label: { Image(systemName: "plus") }
        }
        #else
        PluginSlider(node: node) { context.change(node, .number($0)) }
        #endif
    }

    @ViewBuilder private var picture: some View {
        if let data = node.image, let image = PlatformImage(data: data) {
            let width = (node.width ?? Double(image.size.width) / 2) * scale, height = (node.height ?? Double(image.size.height) / 2) * scale
            #if os(macOS)
            let drawn = Image(nsImage: image)
            #else
            let drawn = Image(uiImage: image)
            #endif
            // Plugins' pictures are mostly QR codes: keep their pixels sharp.
            VStack(spacing: 10 * scale) {
                drawn.resizable().interpolation(.none)
                    .aspectRatio(contentMode: node.fill ? .fill : .fit)
                    .overlay { touchArea }
                    .frame(maxWidth: width, maxHeight: height)
                    .clipped()
                if !node.touch { PluginCodeLink(image: data) }
            }
            .frame(maxWidth: .infinity)
        } else {
            spacer
        }
    }

    /// On a picture the plugin reads touches on (a color wheel), a tap or the end of a drag sends where it landed.
    @ViewBuilder private var touchArea: some View {
        #if os(tvOS)
        EmptyView()
        #else
        if node.touch, node.enabled {
            GeometryReader { frame in
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                        guard frame.size.width > 0, frame.size.height > 0 else { return }
                        context.send(PluginEvent(window: context.window, kind: .touch, view: node.id,
                                                 x: drag.location.x / frame.size.width, y: drag.location.y / frame.size.height))
                    })
            }
        }
        #endif
    }

    /// An empty view: a gap, or a line or block when the plugin colors it.
    @ViewBuilder private var spacer: some View {
        if let plate, let height = node.height {
            Rectangle().fill(plate).frame(height: CGFloat(height * scale))
                .frame(maxWidth: node.fillWidth ? .infinity : node.width.map { CGFloat($0 * scale) } ?? .infinity)
        } else if node.weight != nil {
            Spacer(minLength: 0)
        } else if let height = node.height {
            Color.clear.frame(height: CGFloat(height * scale))
        }
    }
}

#if !os(tvOS)
/// A plugin's SeekBar: the plugin hears the value once the drag ends, as Android's onStopTrackingTouch.
private struct PluginSlider: View {
    let node: PluginNode
    let commit: (Int) -> Void
    @State private var value: Double?
    var body: some View {
        HStack {
            Slider(value: Binding(get: { value ?? Double(node.progress) }, set: { value = $0 }),
                   in: Double(node.minimum)...Double(max(node.minimum + 1, node.maximum)), step: Double(node.step)) { editing in
                if !editing, let value { commit(Int(value)); self.value = nil }
            }
            Text("\(Int(value ?? Double(node.progress)))").monospacedDigit().frame(minWidth: 40)
        }
    }
}
#endif

/// Taps on a plugin's own rows: no extra chrome (the plugin paints them), a lift on Apple TV focus.
private struct PluginTapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        PluginFocusLift(label: configuration.label, pressed: configuration.isPressed)
        #else
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
        #endif
    }
}

#if os(tvOS)
private struct PluginFocusLift<Label: View>: View {
    @Environment(\.isFocused) private var focused
    let label: Label
    let pressed: Bool
    var body: some View {
        label
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: focused ? 4 : 0) }
            .scaleEffect(pressed ? 0.98 : focused ? 1.03 : 1)
            .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
#endif

private extension PluginColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

#if os(macOS)
private typealias PlatformImage = NSImage
#else
private typealias PlatformImage = UIImage
#endif

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
    /// Full Screen came from turning the phone sideways, so turning it upright again returns to the page.
    @State private var turnedFullScreen = false
    @State private var showsAllEpisodes = false
    @State private var episodeScroll: Episode.ID?
    /// The page's player shows its picture (or an error); until then the page's cover stays over it.
    @State private var playerStarted = false
    /// Back on the cover while it starts: shown for a moment by a tap, as the player's controls are.
    @State private var coverBack = false
    /// The page's player, whose wait the cover tells about.
    @State private var playerSession: PlaybackSession?
    /// The source's config center, open in the app (`ConfigCenterView`).
    @State private var showsConfigCenter = false
    #endif
    @State private var requestTask: Task<Void, Never>?
    @State private var detail: Video?
    /// Short labels (第1集) for lines whose episode names are file names, by episode id (#318). Display only.
    @State private var episodeLabels: [Episode.ID: String] = [:]
    /// Resolution and size read from file names (4K · 5.2G, #620), under the episodes' names.
    @State private var episodeDetails: [Episode.ID: String] = [:]
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
    #if os(tvOS)
    /// Apple TV's page: scrolled past the hero (the backdrop frosts), the hero's other buttons, the full synopsis.
    @State private var tvScrolled = false
    @FocusState private var tvHeroFocus: TVHeroItem?
    @State private var showsTVSynopsis = false
    #endif
    #if os(macOS)
    /// Scrolled past the hero, so the toolbar shows the title the hero showed.
    @State private var macPastHero = false
    #endif
    @State private var containerWidth: CGFloat = 0
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @State private var artAspect: CGFloat?
    /// TMDB's backdrop once its picture has loaded. The source's cover stays until then, and when it never does
    /// (image.tmdb.org is blocked on some networks, #237).
    @State private var loadedBackdrop: URL?
    /// The episode whose playback is being prepared; its row and the Play button show progress.
    @State private var loadingEpisode: Episode.ID?
    /// A failed or blocked playback attempt, shown as an inline banner beside the artwork.
    @State private var playbackIssue: PlaybackIssue?
    /// A drive sign-in the source's CatPawOpen bundle runs itself, with its own code (`CatPawSignIn`).
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
            #elseif os(tvOS)
            if showsBilibiliTVPage { bilibiliTVPage } else if showsTVLoadingHero { tvLoadingHero } else { tvDetailPage }
            #else
            macPage
            #endif
        }
        .safeAreaInset(edge: .bottom) { if !isWatchPage && !showsTVLoadingHero { loadingCard } }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        #if os(macOS)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { DetailAurora(poster: video.poster, headers: video.posterHeaders) }
        // As Apple TV's page: the picture behind the title reads best, and the same, on a dark page.
        .environment(\.colorScheme, .dark)
        #else
        .screenBackdrop()
        #endif
        // Apple TV's Bilibili video page sets its title in its hero; a bar over it only repeated it.
        // Apple TV's pages set their title in their hero; a bar over it only repeated it.
        .screenTitle(video.name, shown: false).task {
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
        #if os(iOS)
        .sheet(isPresented: $showsConfigCenter) { ConfigCenterView { await configCenterAddress() } }
        #endif
        // The source's own sign-in where playback failed, then the episode that needed the account plays. Plugins that
        // sign in by themselves show their code while the request runs (PluginSignIn); the app's sign-ins stay in
        // Settings, whose accounts every source gets.
        #if os(tvOS)
        .fullScreenCover(item: $bundleSignIn) { pending in
            CatPawSignInView(client: client, provider: pending.provider) { retryAfterSignIn() }
        }
        #else
        .sheet(item: $bundleSignIn) { pending in
            CatPawSignInView(client: client, provider: pending.provider) { retryAfterSignIn() }
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
                    sourceExtras
                    episodePanel
                    sourceRelated
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

    /// Apple TV until the details are in (loading, or they failed): the cover across the screen with the title, as the
    /// Bilibili page's hero.
    private var showsTVLoadingHero: Bool {
        #if os(tvOS)
        detail == nil && !showsBilibiliTVPage
        #else
        false
        #endif
    }

    #if os(tvOS)
    /// The Bilibili page's hero while the details load: the title, then skeletons where the facts, Play, the four
    /// actions and the synopsis will be; if they fail, what went wrong with Try Again where Play would be.
    private var tvLoadingHero: some View {
        let subtitle = video.remarks.isEmpty ? video.year ?? "" : video.remarks
        return ZStack(alignment: .bottomLeading) {
            TVCoverBackdrop(url: video.poster, headers: video.posterHeaders, frosted: false)
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(video.name).font(.system(size: 64, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
                        .frame(maxWidth: 1300, alignment: .leading)
                        .shadow(color: .black.opacity(0.45), radius: 12)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 28, weight: .medium)).lineLimit(1).opacity(0.7)
                    } else if error == nil || busy {
                        SkeletonBlock(cornerRadius: 8).frame(width: 420, height: 30)
                    }
                }
                if let error, !busy {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Unable to load video details")).font(.system(size: 30, weight: .semibold))
                        Text(error).font(.system(size: 24)).lineLimit(2).opacity(0.6).frame(maxWidth: 1100, alignment: .leading)
                    }
                    .padding(.top, 8)
                    HStack(spacing: 18) {
                        Button { startRequest { await loadDetail() } } label: { Label(L10n.text("Try Again"), systemImage: "arrow.clockwise") }
                            .buttonStyle(DiscoverTVActionStyle(height: 82, font: 28))
                            .focused($playFocused)
                            .accessibilityIdentifier("detail.retry")
                        Button { dismiss() } label: { Label(L10n.text("Go back"), systemImage: "chevron.backward") }
                            .buttonStyle(DiscoverTVActionStyle(height: 82, font: 28))
                            .accessibilityIdentifier("detail.goBack")
                    }
                    .padding(.top, 16)
                    .focusSection()
                    // The error can arrive before the page has finished appearing, too early for the focus request in
                    // loadDetail: Try Again takes it once it is on screen.
                    .task(id: error) { try? await Task.sleep(for: .milliseconds(400)); playFocused = true }
                } else {
                    HStack(alignment: .top, spacing: 72) {
                        VStack(alignment: .leading, spacing: 22) {
                            // Holds focus while it loads, so Back leaves the page.
                            SkeletonBlock(cornerRadius: 41).frame(height: 82)
                                .loadingFocus(takeFocus: true) { dismiss() }
                                .accessibilityLabel(L10n.text("Loading video details…"))
                                .accessibilityIdentifier("detail.loading")
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(0..<4, id: \.self) { _ in
                                    VStack(spacing: 12) {
                                        SkeletonBlock(cornerRadius: 24).frame(height: 76)
                                        SkeletonBlock(cornerRadius: 6).frame(width: 64, height: 20)
                                    }
                                }
                            }
                        }
                        .frame(width: 540)
                        VStack(alignment: .leading, spacing: 16) {
                            SkeletonBlock(cornerRadius: 8).frame(height: 28)
                            SkeletonBlock(cornerRadius: 8).frame(height: 28)
                            SkeletonBlock(cornerRadius: 8).frame(width: 560, height: 28)
                        }
                        .frame(maxWidth: 1000, alignment: .leading)
                        .padding(.top, 8)
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, 96).padding(.bottom, 140)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .transition(.opacity)
        .animation(.smooth(duration: 0.3), value: error)
    }
    #endif

    /// A Bilibili video on Apple TV gets its own page (BilibiliTVVideoPage).
    private var showsBilibiliTVPage: Bool {
        #if os(tvOS)
        client.site.isBilibili && BilibiliAPI.isVideo(video.id)
        #else
        false
        #endif
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
                Image(systemName: issue.signIn != nil ? "person.crop.circle.badge.exclamationmark.fill" : "exclamationmark.triangle.fill")
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
                        if let provider = issue.signIn {
                            Button(provider == "ucToken" ? L10n.text("Get UC TV Token") : L10n.text("Sign In to %@", CatPawSignIn.driveName(provider))) {
                                bundleSignIn = BundleSignIn(provider: provider)
                            }
                            .settingsButton(prominent: true)
                            .accessibilityIdentifier("playbackIssue.bundleSignIn")
                        }
                        Button(L10n.text("Retry")) { startRequest { await play(issue.episode) } }
                            .settingsButton(prominent: issue.signIn == nil)
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
            #if DEBUG
            // `-qaDetailDelay <seconds>`: holds the details back, to see the page while they load.
            let delay = UserDefaults.standard.double(forKey: "qaDetailDelay")
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            #endif
            let value = try await client.detail(video.id, cached: client.site.type == 3 || client.site.type == 4)
            try Task.checkCancellation()
            // Worked out once, off the main thread: a line can hold thousands of episodes.
            let episodes = value.episodes
            (episodeLabels, episodeDetails) = await Task.detached(priority: .userInitiated) {
                let labels = EpisodeLabels.labels(episodes)
                return (labels, EpisodeFileInfo.details(episodes, labels: labels))
            }.value
            detail = value
            // Start on the line watched last (#362), else on one that can play: not one from a drive the viewer has no
            // way to sign in to.
            if selectedFlag == nil { selectedFlag = watchedFlag ?? CloudDrive.preferredFlag(flags) }
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
    /// A video without episodes. A config center entry (a CatPawOpen bundle's, #311, or a Wex plugin's, #360) opens its page in the app.
    @ViewBuilder private func noEpisodes(_ detail: Video) -> some View {
        #if os(iOS)
        if ConfigCenter.page(of: detail, site: client.site) != nil {
            Button { showsConfigCenter = true } label: { Label(L10n.text("Open Config Center"), systemImage: "gearshape") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("detail.configCenter")
        } else {
            Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        }
        #else
        // Apple TV and the Mac don't open a config center (#651): the app's drive sign-ins reach the source instead.
        if ConfigCenter.page(of: detail, site: client.site) != nil {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.text("This source's settings page can't open on this device. Sign in to your drives in Cloud Drive Accounts, and the source uses those sign-ins."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                RouteLink { CloudDriveView() } label: { Text(L10n.text("Cloud Drive Accounts")) }
                    .controlButton(prominent: true)
                    .accessibilityIdentifier("detail.cloudDriveAccounts")
            }
        } else {
            Text(L10n.text("No playable sources were found for this video.")).foregroundStyle(.secondary)
        }
        #endif
    }
    #if os(iOS)
    /// The config center's address now. Asking the bundle again gives its current port, which changes when iOS took
    /// back its socket while the app was suspended; the page's details can be older than that, or cached.
    private func configCenterAddress() async -> URL? {
        let fresh = try? await client.detail(video.id)
        return (fresh ?? detail).flatMap { ConfigCenter.page(of: $0, site: client.site) }
    }
    #endif
    /// TMDB's story when it has one, else the source's synopsis.
    private func synopsisText(_ detail: Video) -> String {
        if let story = tmdb.details?.story, !story.isEmpty { return story }
        // The Bilibili source adds a video's hot comments to its synopsis; the page lists its comments itself.
        if client.site.isBilibili, BilibiliAPI.isVideo(detail.id), let range = detail.synopsis.range(of: "—— 热门评论 ——") {
            return String(detail.synopsis[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return detail.synopsis
    }
    /// The Bilibili source's UP主: the director it links to their space (`up_<mid>`).
    private var bilibiliCreator: (mid: Int, name: String)? {
        guard client.site.isBilibili, let credits = detail?.credits else { return nil }
        for credit in credits { if let mid = credit.category.flatMap(BilibiliAPI.creator(category:)) { return (mid, credit.name) } }
        return nil
    }
    /// Under the title: on Bilibili the UP主, Follow, and the account's like, coins and favourite (#256); on other
    /// sources the people they credit, when they link any to a listing of their works.
    @ViewBuilder private var sourceExtras: some View {
        if let detail {
            if client.site.isBilibili {
                VStack(alignment: .leading, spacing: 14) {
                    if let creator = bilibiliCreator { BilibiliCreatorRow(mid: creator.mid, name: creator.name, client: client) }
                    if BilibiliAPI.isVideo(detail.id) { BilibiliActionBar(bvid: detail.id) }
                }
            } else if let credits = detail.credits, credits.contains(where: { $0.category != nil }) {
                SourceCreditsRow(credits: credits, client: client)
            }
        }
    }
    /// Bilibili's related videos, after the episodes.
    @ViewBuilder private var sourceRelated: some View {
        if client.site.isBilibili, let detail, BilibiliAPI.isVideo(detail.id) { BilibiliRelatedRow(bvid: detail.id, client: client) }
    }
    /// The lookup's progress or its question, then TMDB's cast, facts and notice, under the page's own content.
    @ViewBuilder private var tmdbStatus: some View {
        TMDBLookupStatus(lookup: tmdb)
    }
    @ViewBuilder private var tmdbExtras: some View {
        if let details = tmdb.details {
            VStack(alignment: .leading, spacing: 22) {
                // As Discover's title page (#505): people, studios and genres open their own pages.
                if !details.cast.isEmpty { TMDBPeopleRow(title: L10n.text("Cast"), people: details.cast) }
                if details.crew.contains(where: { $0.profile != nil }) { TMDBPeopleRow(title: L10n.text("Crew"), people: details.crew) }
                #if os(tvOS)
                let studiosShown = false
                #else
                let studiosShown = details.studios?.isEmpty == false
                if studiosShown, let studios = details.studios { TMDBStudioRow(studios: studios) }
                #endif
                if !details.genres.isEmpty { TMDBGenreRow(details: details) }
                TMDBInfoGrid(details: details, studiosShown: studiosShown)
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
    /// TMDB's backdrop banner once its picture is in, the source's cover and title until then.
    @ViewBuilder private var tmdbHero: some View {
        if let details = tmdb.details, let backdrop = details.backdrop, backdrop == loadedBackdrop {
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
            // The episode watched last, or the next one once it is finished, so Play continues the video instead of
            // starting the line again (#593).
            let continuation = watchHistory?.continuation(in: detail.episodes)
            if let first = continuation ?? activeEpisodes.first ?? detail.episodes.first {
                let continues = first.id == continuation?.id
                // Beside the poster on a phone there is no room for both labels: Download drops to its icon.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { playButton(first, continuation: continues); downloadButton(iconOnly: false); videoFavoriteButton }
                    HStack(spacing: 10) { playButton(first, continuation: continues); downloadButton(iconOnly: true); videoFavoriteButton }
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
                    .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
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
            .controlButton(prominent: prominent).appControlSize(.large)
            .accessibilityIdentifier("detail.goBack")
    }
    #endif
    private func playButton(_ episode: Episode, continuation: Bool = false) -> some View {
        Button { startRequest { await play(episode) } } label: {
            HStack(spacing: 8) {
                if loadingEpisode == episode.id { ProgressView().appControlSize(.small) } else { Image(systemName: "play.fill") }
                Text(L10n.text(continuation ? "Continue" : "Play"))
            }
            .font(.headline).lineLimit(1).fixedSize().padding(.horizontal, 8)
        }
        .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
        .focused($playFocused)
    }
    private func downloadButton(iconOnly: Bool) -> some View {
        Button { choosingDownloads = true } label: {
            Label(L10n.text("Download"), systemImage: "arrow.down.circle")
                .labelStyle(DownloadLabelStyle(iconOnly: iconOnly))
                .font(.headline).lineLimit(1).fixedSize()
        }
        .controlButton().appControlSize(.large).accessibilityLabel(L10n.text("Download"))
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
        .controlButton().appControlSize(.large)
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
            if isWide || hasBackdrop {
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
        .animation(.smooth(duration: 0.45), value: loadedBackdrop)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
        .task(id: tmdb.details?.backdrop) {
            // Into TMDBArtwork's cache, so the banner shows it at once.
            guard let backdrop = tmdb.details?.backdrop,
                  await TMDBArtwork.load(backdrop, maxPixels: TMDBBannerMetrics.backdropPixels) != nil,
                  !Task.isCancelled else { return }
            loadedBackdrop = backdrop
        }
    }
    private var hasBackdrop: Bool {
        tmdb.details?.backdrop != nil && tmdb.details?.backdrop == loadedBackdrop
    }
    @ViewBuilder private var episodePanel: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
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

    /// What the pickers show for an episode: its short label when its line has them, else its name without the size tag.
    private func episodeTitle(_ episode: Episode) -> String { episodeLabels[episode.id] ?? EpisodeRow.title(episode.name) }

    /// The episodes in the order the lists show them. Only the lists: Play and the next episode still follow the source.
    private func shownOrder(_ items: [Episode]) -> [Episode] { reversesEpisodes ? items.reversed() : items }

    private func episodeList(_ items: [Episode]) -> some View {
        // A chip fits about six characters before it truncates (《一…); longer names get rows.
        let longNames = (items.map { (episodeLabels[$0.id] ?? $0.name).count }.max() ?? 0) > 6
        // Under a full-width banner, long names fill columns rather than one stretched list.
        let rowColumns = isWide ? [GridItem(.adaptive(minimum: 320), spacing: 8)] : [GridItem(.flexible())]
        // TMDB's stills, when its season lines up with most of the episodes and it has pictures (`episodeTiles`);
        // without pictures the small chips read better than empty tiles. While TMDB is still looking, tiles with the
        // episode numbers, so its stills fade into the same tiles instead of chips turning into tiles.
        let stills = tmdb.episodes(items)
        let showsStills = items.count > 1 && (!tmdb.episodeTiles(items).isEmpty || (tmdbPending && items.count <= 60))
        let columns = showsStills ? [GridItem(.adaptive(minimum: TMDBMetrics.episodeTile), spacing: TMDBMetrics.spacing, alignment: .top)]
            : longNames ? rowColumns : [GridItem(.adaptive(minimum: episodeMin), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: showsStills ? TMDBMetrics.spacing : longNames ? 4 : 8) {
            ForEach(shownOrder(items)) { episode in
                let saved = download(episode)
                Group {
                    if showsStills {
                        Button { startRequest { await play(episode) } } label: {
                            TMDBEpisodeTile(name: episodeTitle(episode), info: stills[episode.id], detail: episodeDetails[episode.id],
                                            loading: loadingEpisode == episode.id, width: nil, backdrops: tmdb.episodeBackdrops)
                        }
                        .tmdbCardButton()
                        .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
                        .accessibilityLabel(episode.name)
                    } else if longNames {
                        EpisodeRow(name: episode.name, label: episodeLabels[episode.id], file: episodeDetails[episode.id],
                                   loading: loadingEpisode == episode.id, download: saved) {
                            startRequest { await play(episode) }
                        }
                    } else {
                        Chip(title: episodeLabels[episode.id] ?? episode.name, selected: loadingEpisode == episode.id, fill: true,
                             subtitle: episodeDetails[episode.id]) { startRequest { await play(episode) } }
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
                    // The file name a label stands for: its resolution and codec can matter on a netdisk line.
                    if episodeLabels[episode.id] != nil { Text(episode.name) }
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
    private func play(_ episode: Episode) async {
        guard !busy else { return }
        // Picking the episode watched last picks it up where it stopped; any other starts at 0 (#593).
        let resume = resumePosition(for: episode)
        // A downloaded episode plays from the device: no link to fetch, and it works offline.
        if let saved = download(episode), saved.status == .completed {
            store.playing = DownloadLibrary.shared.channel(for: saved)
            return
        }
        // A drive line goes to the plugin even without an app sign-in: the plugin asks for its account itself, with
        // its own code, which the app shows (PluginSignIn, or the bundle's sign-in below).
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
                store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback, resumePosition: resume)
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
            store.playing = store.catalogChannel(resolved, video: currentVideo(), episode: episode, client: playback,
                                                 resumePosition: resumePosition(for: episode))
        } catch { fail(episode, error) }
    }
    private func retryAfterSignIn() {
        if let episode = playbackIssue?.episode { startRequest { await play(episode) } }
    }
    private func fail(_ episode: Episode, _ error: Error) {
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        // A CatPawOpen bundle without a drive's sign-in sends the viewer to its config center ("请先去配置中心登录夸克"):
        // its own sign-in for that drive runs here instead.
        let provider = client.site.isCatPawOpen ? CatPawSignIn.provider(for: error.localizedDescription) : nil
        // A drive that needs signing in is expected, not a failure to report.
        if provider == nil && !(error is CloudDriveLoginRequired) {
            Diagnostics.shared.failure("catalog", "play \(client.reportContext) flag=\(episode.flag)", error)
        }
        withAnimation(.smooth(duration: 0.25)) {
            if let provider {
                let message = provider == "ucToken"
                    // Signed in, but the bundle wants a token its own code gives; signing in again would change nothing.
                    ? L10n.text("You're signed in to UC, but this source plays UC accounts without premium through UC's TV app, which needs a token of its own. Get it once with the UC Browser app, or choose another line.")
                    : L10n.text("This source needs your %@ account for this line. Sign in with its code, and the episode plays.", CatPawSignIn.driveName(provider))
                playbackIssue = PlaybackIssue(episode: episode, message: message, signIn: provider)
            } else {
                // Other plugins say in their own words what their sign-in needs.
                playbackIssue = PlaybackIssue(episode: episode, message: error.localizedDescription)
            }
        }
    }

    /// This video's playback scopes (`PlaybackHistoryContext.id`); the details may carry another ID than the list's.
    private var watchScopes: Set<String> {
        let origin = client.site.origin(or: client.origin)
        return Set([video.id, detail?.id].compactMap { $0 }.map { EpisodeSkipSettings.scope(origin: origin, source: client.site.sourceKey, video: $0) })
    }
    /// Where the viewer stopped last time, for Continue.
    private var watchHistory: PlaybackHistoryEntry? {
        store.playbackHistory.entries.first { watchScopes.contains($0.context.id) }
    }
    /// Where an episode stopped last time, when it is the one watched last; any other starts at 0.
    private func resumePosition(for episode: Episode) -> Double? {
        watchHistory?.resumePosition(for: episode)
    }
    /// The line of the episode playing, else of the one watched last, while the details still have it: the page opens
    /// on that line so the episode shows in its list, not on the first line (#362).
    private var watchedFlag: String? {
        guard let episodes = detail?.episodes else { return nil }
        #if os(iOS)
        let context = watchChannel?.historyContext ?? watchHistory?.context
        #else
        let context = watchHistory?.context
        #endif
        return context?.episode(in: episodes)?.flag
    }

    #if os(iOS)
    // MARK: iPhone watch page

    private var watchLayout: Bool { WatchPage.applies(sizeClass, verticalSizeClass) }
    /// What plays at the top of the page: one of this video's episodes.
    private var watchChannel: Channel? {
        store.playing.flatMap { watchScopes.contains($0.historyContext?.id ?? "") ? $0 : nil }
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
                        #if DEBUG
                        .modifier(QAScrollToFoot())
                        #endif
                }
            }
            watchPlayer
                .frame(height: fullScreen ? nil : playerHeight)
                .frame(maxWidth: .infinity, maxHeight: fullScreen ? .infinity : nil, alignment: .top)
        }
        // The status bar's strip above the player is the player's black.
        .background(alignment: .top) { Color.black.frame(height: playerHeight).ignoresSafeArea(edges: .top) }
        .background { if fullScreen { Color.black.ignoresSafeArea() } }
        // The clock and battery stay above the player, light on its black as iOS picks in either appearance;
        // only Full Screen hides them (#514).
        .statusBarHidden(fullScreen)
        .toolbar(.hidden, for: .navigationBar)
        .background { EdgeSwipeBack(enabled: !fullScreen) }
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            store.watchPageScopes.formUnion(watchScopes)
            PlayerOrientation.holdPortrait(true)
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        .onChange(of: watchScopes) { old, new in
            store.watchPageScopes.subtract(old.subtracting(new)); store.watchPageScopes.formUnion(new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            phoneTurned()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            // Leaving the page ends its playback, as the full-screen player's Back does.
            if watchChannel != nil { store.playing = nil }
            store.watchPageScopes.subtract(watchScopes)
            if fullScreen { fullScreen = false; PlayerOrientation.set(landscape: false) }
            turnedFullScreen = false
            PlayerOrientation.holdPortrait(false)
        }
        .onChange(of: watchChannel == nil) { _, ended in
            playerStarted = false
            if ended { playerSession = nil }
            if ended && fullScreen { setFullScreen(landscape: false) }
            // Started with the phone already sideways: Full Screen at once, as turning it would.
            if !ended { phoneTurned() }
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
        // A button's Full Screen stays until the viewer leaves it; turning the phone back upright ends only a
        // Full Screen the turning opened.
        if !entering { turnedFullScreen = false }
        withAnimation(.smooth(duration: 0.3)) { fullScreen = entering }
        // A landscape picture turns the phone; a portrait one fills the screen upright.
        if !entering { PlayerOrientation.set(landscape: false) } else if landscape { PlayerOrientation.set(landscape: true) }
    }

    /// Turning the phone sideways while its video plays opens Full Screen, as the player's button does, and turning
    /// it upright again returns to the page. The watch page holds the interface upright (`PlayerOrientation`), so it
    /// doesn't turn by itself: this listens to the phone's own turning instead.
    private func phoneTurned() {
        guard watchChannel != nil, PlayerOrientation.available else { return }
        switch UIDevice.current.orientation {
        case .landscapeLeft, .landscapeRight:
            guard !fullScreen else { return }
            turnedFullScreen = true
            setFullScreen(landscape: true)
        case .portrait:
            guard fullScreen, turnedFullScreen else { return }
            setFullScreen(landscape: false)
        default:
            break
        }
    }

    /// The cover's Play: where the viewer stopped (the next episode once that one is finished), else the line's
    /// first episode.
    private func playWatchCover() {
        if let watchHistory, watchHistory.completed, let next = detail.flatMap({ watchHistory.continuation(in: $0.episodes) }) {
            startRequest { await play(next) }; return
        }
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

    /// Under the player, as the Apple TV page: the title once and one quiet line of facts, the actions as a row of glass
    /// plates, the synopsis, then the episodes and TMDB's rows. A Bilibili video has its own page in the same manner,
    /// with the UP主, the account's actions, comments and related videos.
    private var watchDetails: some View {
        VStack(alignment: .leading, spacing: 20) {
            if client.site.isBilibili, BilibiliAPI.isVideo(video.id) {
                let saved = store.favorites.contains(videoFavorite())
                BilibiliPhoneVideoPage(bvid: video.id, title: currentVideo().name, synopsis: detail.map(synopsisText) ?? "",
                                       creator: bilibiliCreator, client: client, saved: saved,
                                       toggleSaved: { store.favorites.toggle(videoFavorite()) },
                                       download: detail?.episodes.isEmpty == false ? { choosingDownloads = true } : nil) {
                    playbackBanner
                    if detail == nil, let error { errorCard(error) }
                } parts: {
                    watchEpisodes
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentVideo().name).font(.title3.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                    if !watchFacts.isEmpty {
                        Text(watchFacts).font(.footnote).foregroundStyle(.secondary).lineLimit(2).contentTransition(.opacity)
                    }
                }
                sourceExtras
                if detail?.episodes.isEmpty == false { watchPlates }
                playbackBanner
                tmdbStatus
                if let detail { watchSynopsis(detail) }
                if detail != nil {
                    watchEpisodes
                    tmdbExtras.padding(.top, 6)
                } else if let error {
                    errorCard(error)
                } else {
                    DetailSkeleton()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Its buttons are Liquid Glass, like the player's above them (#293).
        .environment(\.glassControls, true)
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }

    #if DEBUG
    /// `-qaScrollAnchor bottom`: the page opens scrolled to its foot, for screenshots. Only then: any default anchor,
    /// even `.top`, made the page follow its growing content down.
    private struct QAScrollToFoot: ViewModifier {
        func body(content: Content) -> some View {
            if UserDefaults.standard.string(forKey: "qaScrollAnchor") == "bottom" { content.defaultScrollAnchor(.bottom) } else { content }
        }
    }
    #endif

    /// TMDB's facts (2026 · Drama · ★ 7.0) once they are in, else the source's remarks and year; then the source.
    private var watchFacts: String {
        let video = currentVideo()
        let facts = tmdb.details?.facts ?? ""
        let lead = facts.isEmpty ? [video.remarks, video.year ?? ""] : [facts]
        return (lead + [SourceLabel(client.site.name).text]).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Three lines of the synopsis, as the Bilibili page's description: a tap shows the rest.
    @ViewBuilder private func watchSynopsis(_ detail: Video) -> some View {
        let text = synopsisText(detail)
        if !text.isEmpty {
            Button { withAnimation(.smooth(duration: 0.3)) { synopsisExpanded.toggle() } } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        .lineLimit(synopsisExpanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if text.count > 60 {
                        Text(L10n.text(synopsisExpanded ? "Show Less" : "More")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.synopsis")
        }
    }

    /// Download and the heart, as glass plates with their words under them.
    private var watchPlates: some View {
        let saved = store.favorites.contains(videoFavorite())
        let title = saved ? L10n.text("Remove %@ from favorites", currentVideo().name) : L10n.text("Add %@ to favorites", currentVideo().name)
        return HStack(alignment: .top, spacing: 14) {
            Button { choosingDownloads = true } label: { WatchPlateLabel(symbol: "arrow.down.circle", caption: L10n.text("Download")) }
                .accessibilityLabel(L10n.text("Download")).accessibilityIdentifier("detail.download")
            Button { store.favorites.toggle(videoFavorite()) } label: {
                WatchPlateLabel(symbol: "heart", caption: saved ? L10n.text("Saved") : L10n.text("Favorite"), on: saved)
            }
            .accessibilityLabel(title).accessibilityIdentifier("detail.favorite")
        }
        .buttonStyle(.plain)
        .padding(.leading, -7)
    }

    /// As in Bilibili's 选集: one row of episodes that scrolls sideways to the one playing, and All for the full list.
    /// A video with one episode has no row (its only episode is the video); several lines still show to choose from.
    @ViewBuilder private var watchEpisodes: some View {
        if let detail {
            if detail.episodes.isEmpty {
                noEpisodes(detail)
            } else {
                let items = activeEpisodes
                let tile = compactTileWidth(items)
                let compact = tile != nil
                let stills = watchStills(items)
                VStack(alignment: .leading, spacing: 12) {
                    if items.count > 1 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text("Episodes")).font(.headline)
                            Text("\(items.count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            episodeOrderButton.glassOrFill(.regular.interactive(), Color.clear, in: Circle())
                            Spacer(minLength: 8)
                            if items.count > (compact ? 5 : 2) {
                                Button { showsAllEpisodes = true } label: {
                                    HStack(spacing: 3) { Text(L10n.text("All")); Image(systemName: "chevron.right").font(.caption.weight(.semibold)) }
                                        .font(.subheadline).foregroundStyle(.secondary)
                                        .padding(.horizontal, 12).frame(minHeight: 32)
                                        .glassOrFill(.regular.interactive(), Color.clear, in: Capsule())
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
                            LazyHStack(alignment: .top, spacing: stills.isEmpty ? 8 : 12) { ForEach(shownOrder(items)) { watchEpisodeCard($0, tile: tile, info: stills[$0.id]) } }
                                .scrollTargetLayout()
                                .padding(.horizontal, 16)
                        }
                        .scrollIndicators(.never)
                        .scrollPosition(id: $episodeScroll, anchor: .center)
                        // Edge to edge, unclipped: the tiles' glass shadow ran past the row and was cut off in a band (#293).
                        .scrollClipDisabled()
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
            // Edge to edge and unclipped, like the episodes, so the strip doesn't cut the chips' glass shadow (#293).
            .contentMargins(.horizontal, 16, for: .scrollContent).scrollClipDisabled()
            .padding(.horizontal, -16)
        }
    }

    /// TMDB's episodes for picture tiles (`TMDBLookup.episodeTiles`); otherwise none, and the episodes keep their small
    /// cards.
    private func watchStills(_ items: [Episode]) -> [Episode.ID: TMDBMatch.EpisodeInfo] {
        tmdb.episodeTiles(items)
    }

    /// The width of the small tiles when every name is short (第1集, 01, 4K国语), or nil for two-line cards. The tiles
    /// are as wide as the widest name, at least 64 points: a fixed 64 cut off names of four or five characters such as
    /// 4K国语 or 第100集 (#290). Measures one name, in the same pass that checks their lengths.
    private func compactTileWidth(_ items: [Episode]) -> CGFloat? {
        var widest = "", widestUnits = 0, widestDetail = ""
        for item in items {
            let title = episodeTitle(item)
            guard title.count <= 5 else { return nil }
            if let detail = episodeDetails[item.id], detail.count > widestDetail.count { widestDetail = detail }
            // Chinese and other wide characters take about twice the room of digits and Latin letters.
            let units = title.unicodeScalars.reduce(0) { $0 + ($1.isASCII ? 1 : 2) }
            if units > widestUnits { widest = title; widestUnits = units }
        }
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        let small = UIFont.monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .regular)
        let text = max((widest as NSString).size(withAttributes: [.font: font]).width,
                       (widestDetail as NSString).size(withAttributes: [.font: small]).width)
        // 8 points of padding on each side, and a little room for the bold of the episode playing.
        return max(64, (text + 20).rounded(.up))
    }

    /// An episode: a small tile for short names (第1集, 01), a two-line card for long ones, TMDB's still above the name
    /// when there is one. The one playing is filled with the accent, like the chosen line above it (#290). There is no
    /// per-episode favorite on this page.
    private func watchEpisodeCard(_ episode: Episode, tile: CGFloat?, fill: Bool = false, info: TMDBMatch.EpisodeInfo? = nil,
                                  chosen: (() -> Void)? = nil) -> some View {
        let compact = tile != nil
        let current = episode.id == currentEpisodeID
        let saved = download(episode)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let detail = episodeDetails[episode.id]
        return Button {
            chosen?()
            // The episode already playing keeps playing.
            guard !(current && watchChannel != nil) else { return }
            startRequest { await play(episode) }
        } label: {
            if let info {
                TMDBEpisodeTile(name: episodeTitle(episode), info: info, detail: detail, current: current, loading: loadingEpisode == episode.id,
                                width: fill ? nil : 168, backdrops: tmdb.episodeBackdrops)
                    .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge().padding(4) } }
            } else {
            HStack(spacing: 6) {
                if loadingEpisode == episode.id { ProgressView().appControlSize(.small) }
                VStack(alignment: compact ? .center : .leading, spacing: 1) {
                    // With the small line under it, a long name keeps to one line so the card keeps its height.
                    Text(episodeTitle(episode)).lineLimit(compact || detail != nil ? 1 : 2)
                        .multilineTextAlignment(compact ? .center : .leading)
                    if let detail { EpisodeFileDetail(text: detail) }
                }
            }
            .font(.subheadline.weight(current ? .semibold : .regular))
            .foregroundStyle(current ? Brand.onAccent : Color.primary)
            .tint(current ? Brand.onAccent : nil)
            .padding(.horizontal, compact ? 8 : 12)
            .frame(width: fill ? nil : tile ?? 150, height: compact ? 44 : 54, alignment: compact ? .center : .leading)
            .frame(maxWidth: fill ? .infinity : nil, alignment: compact ? .center : .leading)
            .glassOrFill(current ? GlassStyle.regular.tint(Brand.accent).interactive() : .regular.interactive(),
                         current ? Brand.accent : Color.primary.opacity(0.06), in: shape)
            .overlay(alignment: .topTrailing) { if saved?.status == .completed { DownloadedBadge() } }
            .contentShape(shape)
            }
        }
        .buttonStyle(.plain)
        .id(episode.id)
        .accessibilityAddTraits(current ? .isSelected : [])
        .contextMenu {
            if episodeLabels[episode.id] != nil { Text(episode.name) }
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
        let tile = compactTileWidth(items)
        let stills = watchStills(items)
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    watchLines
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: stills.isEmpty ? tile ?? 150 : 160), spacing: stills.isEmpty ? 8 : 12, alignment: .top)],
                              spacing: stills.isEmpty ? 8 : 14) {
                        ForEach(shownOrder(items)) { watchEpisodeCard($0, tile: tile, fill: true, info: stills[$0.id]) { showsAllEpisodes = false } }
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
        .environment(\.glassControls, true)
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
    /// A sign-in the source's CatPawOpen bundle runs itself (`CatPawSignIn.provider(for:)`).
    var signIn: String? = nil
}

private struct BundleSignIn: Identifiable {
    let provider: String
    var id: String { provider }
}

/// Cloud drives a line plays from, to start a video on a line that can play now.
private enum CloudDrive {
    /// Xunlei's sign-in is only for CatPawOpen bundles, which say when it is missing; other sources play their Xunlei
    /// lines without it, so those lines are never held back for it.
    case quark, uc, xunlei
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
    /// The first line that can play now: not from a drive without a sign-in, nor one without the app's sign-in.
    /// Those lines still play when chosen: their plugin asks for the account with its own code.
    static func preferredFlag(_ flags: [String]) -> String? {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        return flags.first { flag in
            if withoutSignIn(flag) { return false }
            guard let drive = CloudDrive(flag: flag), drive != .xunlei else { return true }
            let cookie = drive == .quark ? accounts.quarkCookie : accounts.ucCookie
            return !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Episode names often lead with a size tag ("[1.18GB] S01E41.mkv"); show it as trailing detail.
struct EpisodeRow: View {
    let name: String
    /// The episode's short label (第1集), shown in place of the name; the size tag stays as detail.
    var label: String? = nil
    /// Resolution and size from the file name (4K · 5.2G), shown in place of the size tag.
    var file: String? = nil
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
    private var parts: (title: String, detail: String?) {
        let parts = Self.split(name)
        return (label ?? parts.title, file ?? parts.detail)
    }
    var body: some View {
        let parts = parts
        let button = Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if loading { ProgressView().appControlSize(.mini) }
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

extension View {
    /// The page's title bar, or none where the page sets its title itself.
    @ViewBuilder func screenTitle(_ title: String, shown: Bool) -> some View {
        #if os(tvOS)
        if shown { screenTitle(title) } else { toolbar(.hidden, for: .navigationBar) }
        #elseif os(macOS)
        // The Mac's pages that set their own title name the window themselves (the video page once past its hero).
        if shown { screenTitle(title) } else { self }
        #else
        screenTitle(title)
        #endif
    }
}

#if os(tvOS)
extension VideoDetailView {
    /// Apple TV's page for a Bilibili video (#256): the page's own Play, parts and notices inside BilibiliTVVideoPage.
    var bilibiliTVPage: some View {
        let current = currentVideo()
        return BilibiliTVVideoPage(
            bvid: video.id, title: detail?.name ?? video.name, cover: current.poster, coverHeaders: current.posterHeaders,
            synopsis: detail.map(synopsisText) ?? "", creator: bilibiliCreator, client: client,
            saved: store.favorites.contains(videoFavorite()), toggleSaved: { store.favorites.toggle(videoFavorite()) },
            download: { choosingDownloads = true }, hasParts: activeEpisodes.count > 1
        ) {
            bilibiliTVPlay
        } parts: {
            episodePanel
        } status: {
            playbackBanner
        }
    }

    /// Apple TV's page for every other video, in the Bilibili page's language (Discover's title page): TMDB's backdrop, or
    /// the cover, across the whole screen; over it the logo or title, the facts, Play with Download and Favorite under it
    /// and the synopsis beside them; then the episodes, the people, facts and related titles over the frosted picture.
    var tvDetailPage: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 60) {
                    tvDetailHero.id("hero")
                    VStack(alignment: .leading, spacing: 44) {
                        sourceExtras
                        episodePanel
                        sourceRelated
                        tmdbExtras
                    }
                    .padding(.horizontal, TVDetailMetrics.gutter)
                }
                .padding(.bottom, 90)
            }
            .scrollClipDisabled()
            .modifier(DiscoverTVScrolled(scrolled: $tvScrolled))
            .background {
                if let backdrop = tmdb.details?.backdrop {
                    TVCoverBackdrop(url: backdrop, headers: [:], frosted: tvScrolled)
                } else {
                    TVCoverBackdrop(url: video.poster, headers: video.posterHeaders, frosted: tvScrolled)
                }
            }
            .ignoresSafeArea()
            .foregroundStyle(.white).preferredColorScheme(.dark)
            .animation(.smooth(duration: 0.45), value: tmdb.details)
            .animation(.smooth(duration: 0.3), value: tmdb.phase)
            // Coming back up from the rows, the hero comes back whole, not just as far as the focused button.
            .onChange(of: playFocused || tvHeroFocus != nil) { _, inHero in
                if inHero { withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo("hero", anchor: .top) } }
            }
            .fullScreenCover(isPresented: $showsTVSynopsis) { tvSynopsisScreen }
        }
    }

    private var tvDetailHero: some View {
        let text = detail.map(synopsisText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                playbackBanner
                tmdbStatus
            }
            .frame(maxWidth: 1200, alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                HeroTitleArt(logo: tmdb.details?.logo, name: tmdb.details?.name ?? currentVideo().name)
                Text(heroFacts.isEmpty ? " " : heroFacts).font(.system(size: 28, weight: .medium)).lineLimit(1).opacity(0.7)
                if let tagline = tmdb.details?.tagline, !tagline.isEmpty {
                    Text(tagline).font(.system(size: 26).italic()).lineLimit(1).opacity(0.6)
                }
            }
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 22) {
                    bilibiliTVPlay
                    HStack(alignment: .top, spacing: 16) {
                        tvPlate("arrow.down.circle", caption: L10n.text("Download"), id: "detail.download", focus: .download) {
                            choosingDownloads = true
                        }
                        let saved = store.favorites.contains(videoFavorite())
                        tvPlate(saved ? "heart.fill" : "heart", tint: saved ? Brand.rose : nil, caption: L10n.text(saved ? "Saved" : "Favorite"),
                                id: "detail.favorite", focus: .favorite) {
                            store.favorites.toggle(videoFavorite())
                        }
                    }
                    .disabled(detail?.episodes.isEmpty ?? true)
                }
                .frame(width: TVDetailMetrics.actionsWidth)
                .focusSection()
                if !text.isEmpty {
                    Button { showsTVSynopsis = true } label: {
                        Text(text).font(.system(size: 26)).lineSpacing(4).lineLimit(4).multilineTextAlignment(.leading)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                    .buttonStyle(BilibiliTVPlateStyle())
                    .focused($tvHeroFocus, equals: .synopsis)
                    // The plate's padding outside the column, so the text lines up with Play's top.
                    .padding(.leading, -BilibiliTVPlateStyle.inset).padding(.top, -BilibiliTVPlateStyle.inset)
                    .accessibilityIdentifier("detail.synopsis")
                    .focusSection()
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, TVDetailMetrics.gutter)
        .frame(maxWidth: .infinity, minHeight: 940, alignment: .bottomLeading)
    }

    /// One of the hero's square glass plates under Play, with its caption under it.
    private func tvPlate(_ symbol: String, tint: Color? = nil, caption: String, id: String, focus: TVHeroItem,
                         action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Button(action: action) { Image(systemName: symbol).foregroundStyle(tint ?? .primary).frame(maxWidth: .infinity) }
                .buttonStyle(DiscoverTVActionStyle(height: 76, font: 30, corner: 24))
                .focused($tvHeroFocus, equals: focus)
                .accessibilityLabel(caption).accessibilityIdentifier(id)
            Text(caption).font(.system(size: 22, weight: .medium)).lineLimit(1).opacity(0.6)
        }
        .frame(width: TVDetailMetrics.plateWidth)
    }

    /// The whole synopsis over the frosted picture: the hero shows four lines of it.
    private var tvSynopsisScreen: some View {
        ZStack(alignment: .bottomLeading) {
            TVCoverBackdrop(url: tmdb.details?.backdrop ?? video.poster, headers: tmdb.details?.backdrop == nil ? video.posterHeaders : [:],
                            frosted: true)
            VStack(alignment: .leading, spacing: 24) {
                Text(tmdb.details?.name ?? currentVideo().name).font(.system(size: 52, weight: .bold)).lineLimit(2)
                if !heroFacts.isEmpty { Text(heroFacts).font(.system(size: 26)).opacity(0.6) }
                Text(detail.map(synopsisText) ?? "").font(.system(size: 30)).lineSpacing(6).lineLimit(16)
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(TVDetailMetrics.gutter)
            // Something must hold focus for Menu to close the page.
            .focusable()
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
    }

    /// Play, or Continue the part watched last, as wide as the actions under it.
    @ViewBuilder private var bilibiliTVPlay: some View {
        let continuation = detail.flatMap { watchHistory?.continuation(in: $0.episodes) }
        if let detail, let first = continuation ?? activeEpisodes.first ?? detail.episodes.first {
            Button { startRequest { await play(first) } } label: {
                HStack(spacing: 12) {
                    if loadingEpisode == first.id { ProgressView() } else { Image(systemName: "play.fill") }
                    Text(L10n.text(first.id == continuation?.id ? "Continue" : "Play"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DiscoverTVActionStyle(height: 82, font: 30))
            .focused($playFocused)
            .accessibilityIdentifier("detail.play")
        } else if detail == nil, error == nil {
            // Holds focus while the details load, so Back leaves the page.
            SkeletonBlock(cornerRadius: 41).frame(height: 82).loadingFocus(takeFocus: true) { dismiss() }
        } else {
            playControl
        }
    }
}
#endif

extension SiteView {
    /// An UP主's space (`up_<mid>` and its other listings).
    var isBilibiliSpace: Bool { site.isBilibili && folder.flatMap { BilibiliAPI.creator(category: $0.id) } != nil }

    /// Bilibili's videos as its own apps show them on iPhone, iPad and the Mac: 16:9 covers, two or more across, rather
    /// than cropped into posters. Anime and films (whose covers are posters) keep the posters.
    var showsBilibiliTiles: Bool {
        #if os(tvOS)
        false
        #else
        site.isBilibili && browser.videos.first.map { BilibiliAPI.isVideo($0.id) } == true
        #endif
    }

    static var bilibiliColumns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 220), spacing: 18, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 160), spacing: DiscoverLayout.spacing, alignment: .top)]
        #endif
    }

    /// An UP主's space on Apple TV: its own page (`BilibiliTVSpacePage`), without the source's search field and banner.
    var showsBilibiliTVSpace: Bool {
        #if os(tvOS)
        site.isBilibili && folder.flatMap { BilibiliAPI.creator(category: $0.id) } != nil
        #else
        false
        #endif
    }
}

#if os(tvOS)
extension SiteView {
    @ViewBuilder var bilibiliTVSpace: some View {
        if let folder, let mid = BilibiliAPI.creator(category: folder.id) {
            BilibiliTVSpacePage(mid: mid, name: folder.name, tabs: BilibiliSpaceHeader.tabs(mid),
                                category: browser.category.isEmpty ? folder.id : browser.category, latest: browser.videos.first,
                                open: { id in startRequest { await browser.load(.list(category: id, query: "", page: 1), client: client) } }) {
                spaceGrid
            }
        }
    }

    /// The space's listing as Bilibili's 16:9 tiles, four across, with the page's loading, error and Load More states.
    @ViewBuilder private var spaceGrid: some View {
        if let error = browser.error {
            ErrorStateCard(
                title: L10n.text("Unable to load this source"),
                message: L10n.text("Try again, or choose another source to keep watching."),
                details: error,
                retry: { startRequest { await browser.load(browser.request, client: client) } },
                goBack: { dismiss() },
                busy: browser.busy
            )
        } else if browser.videos.isEmpty && browser.loaded && !browser.busy {
            EmptyResults(symbol: "film", title: L10n.text("No Videos"))
        }
        LazyVGrid(columns: BilibiliTVSpacePage<EmptyView>.columns, alignment: .leading, spacing: 56) {
            if browser.videos.isEmpty && browser.error == nil && (browser.busy || !browser.loaded) {
                ForEach(0..<8, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.08)).aspectRatio(16.0 / 9.0, contentMode: .fit)
                }
            }
            ForEach(browser.videos) { video in
                RouteLink { CatalogDestination(video: video, client: client) } label: { BilibiliVideoTile(video: video) }
                    .cardButton()
                    .onAppear {
                        guard browser.moreError == nil, video.id == browser.videos.last?.id else { return }
                        Task { await loadMore() }
                    }
            }
        }
        .opacity(browser.busy && !browser.videos.isEmpty ? 0.55 : 1).animation(.smooth, value: browser.busy)
        if !browser.videos.isEmpty && (browser.hasMore || browser.loadingMore || browser.moreError != nil) {
            loadMoreFooter.tvFocusSection()
        }
    }
}
#else
extension SiteView {
    var bilibiliTVSpace: some View { EmptyView() }
}
#endif

#if os(tvOS) || os(macOS)
/// The title as TMDB's logo when it has one (the name until the logo is in, and instead of one that fails), else the
/// name. Apple TV's size by default; the Mac's hero passes its own.
struct HeroTitleArt: View {
    let logo: URL?
    let name: String
    var fontSize: CGFloat = 64
    var logoHeight: CGFloat = 170
    var logoMaxWidth: CGFloat = 720
    var textMaxWidth: CGFloat = 1300
    @State private var aspect: CGFloat?
    private var nameText: some View {
        Text(name).font(.system(size: fontSize, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
            .frame(maxWidth: textMaxWidth, alignment: .leading)
            .shadow(color: .black.opacity(0.45), radius: fontSize / 5)
    }
    var body: some View {
        if let logo {
            // Wide logos get a width limit, tall ones a height limit.
            let ratio = max(aspect ?? 3, 0.5)
            let width = min(logoMaxWidth, logoHeight * ratio)
            TMDBArtwork(url: logo, maxPixels: 1000, fill: false, aspect: $aspect)
                .frame(width: aspect == nil ? nil : width, height: aspect == nil ? nil : width / ratio, alignment: .leading)
                .shadow(color: .black.opacity(0.35), radius: 16)
                .overlay(alignment: .leading) { if aspect == nil { nameText } }
                .accessibilityLabel(name)
        } else {
            nameText
        }
    }
}
#endif

#if os(tvOS)
/// The cover behind Apple TV's loading page, as the Bilibili page's: a landscape cover across the screen, sharp; a
/// poster, which would crop to a few enlarged pixels, as a soft blur of its colours. Darker toward the text.
enum TVHeroItem: Hashable { case download, favorite, synopsis }

private enum TVDetailMetrics {
    static let gutter: CGFloat = 96
    /// Play, and the plates under it.
    static let actionsWidth: CGFloat = 540
    static let plateWidth: CGFloat = 123
}

private struct TVCoverBackdrop: View {
    let url: URL?
    let headers: [String: String]
    /// Past the hero: frosted, so the rows read over it.
    var frosted = false
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.black
            if let image {
                let landscape = CGFloat(image.width) / CGFloat(max(1, image.height)) >= 1.3
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                    .blur(radius: landscape ? 0 : 60, opaque: true)
                    .saturation(landscape ? 1 : 1.25)
                    .transition(.opacity)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.55), location: 0.5),
                                   .init(color: .clear, location: 0.85)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: .black.opacity(0.92), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.regularMaterial).opacity(frosted ? 1 : 0)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: frosted)
        .animation(.easeInOut(duration: 0.4), value: image != nil)
        .task(id: url) { if let url { image = await TMDBArtwork.load(url, maxPixels: 1600, headers: headers) } }
    }
}
#endif

extension VideoDetailView {
    /// TMDB's facts (2026 · Drama · ★ 7.0), else the source's note, year and name: the line under the hero's title.
    private var heroFacts: String {
        if let facts = tmdb.details?.facts, !facts.isEmpty { return facts }
        let current = currentVideo()
        return [current.remarks, current.year ?? "", client.site.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

#if os(macOS)
// MARK: The Mac's video page

/// The Mac's video page in Apple TV's language: the backdrop across the window, under the toolbar and the sidebar; over
/// its foot the title once, one line of facts, Play with the actions as glass plates under it, and the synopsis (for
/// Bilibili, the UP主 and the description) beside them; then the episodes and the rest on the page. The toolbar takes
/// the title once the hero has scrolled away.
extension VideoDetailView {
    var macPage: some View {
        Group {
            if client.site.isBilibili && BilibiliAPI.isVideo(video.id) { bilibiliMacPage } else { macDetailPage }
        }
        .navigationTitle(macPastHero ? (detail?.name ?? video.name) : "")
        .artUnderToolbar()
    }

    private var bilibiliMacPage: some View {
        let current = currentVideo()
        return BilibiliMacVideoPage(
            bvid: video.id, title: detail?.name ?? video.name, cover: current.poster, coverHeaders: current.posterHeaders,
            synopsis: detail.map(synopsisText) ?? "", creator: bilibiliCreator, client: client,
            saved: store.favorites.contains(videoFavorite()), toggleSaved: { store.favorites.toggle(videoFavorite()) },
            download: { choosingDownloads = true }, hasParts: activeEpisodes.count > 1, pastHero: $macPastHero
        ) {
            macPlay
        } parts: {
            episodePanel
        } status: {
            playbackBanner
            if detail == nil, let error { errorCard(error) }
        }
    }

    private var macDetailPage: some View {
        GeometryReader { geometry in
            let height = MacHeroMetrics.height(for: geometry.size)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    macHero(height: height, width: geometry.size.width)
                    VStack(alignment: .leading, spacing: 26) {
                        playbackBanner
                        tmdbStatus
                        if detail != nil {
                            sourceExtras
                            episodePanel
                            sourceRelated
                            tmdbExtras
                        } else if let error {
                            errorCard(error)
                        }
                    }
                    .padding(.horizontal, MacHeroMetrics.gutter)
                }
                .padding(.bottom, 40)
            }
            // From the window's top edge: the picture runs on under the toolbar, as Discover's title page.
            .ignoresSafeArea(edges: .top)
            .macHeroScroll(heroHeight: height, past: $macPastHero)
        }
        .animation(.smooth(duration: 0.45), value: tmdb.details)
        .animation(.smooth(duration: 0.3), value: tmdb.phase)
    }

    private func macHero(height: CGFloat, width: CGFloat) -> some View {
        let text = detail.map(synopsisText)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let backdrop = tmdb.details?.backdrop
        return MacVideoHero(height: height, width: width, backdrop: backdrop ?? video.poster,
                            backdropHeaders: backdrop == nil ? video.posterHeaders : [:]) {
            VStack(alignment: .leading, spacing: 8) {
                HeroTitleArt(logo: tmdb.details?.logo, name: tmdb.details?.name ?? currentVideo().name,
                             fontSize: 40, logoHeight: 96, logoMaxWidth: 420, textMaxWidth: 760)
                // A line kept while the facts load, so the hero doesn't move when they come in.
                Text(heroFacts.isEmpty ? " " : heroFacts).font(.system(size: 14, weight: .medium)).lineLimit(1).opacity(0.75)
                if let tagline = tmdb.details?.tagline, !tagline.isEmpty {
                    Text(tagline).font(.system(size: 14).italic()).lineLimit(1).opacity(0.6)
                }
            }
        } actions: {
            VStack(alignment: .leading, spacing: 18) {
                macPlay
                HStack(alignment: .top, spacing: 6) {
                    MacPlate(symbol: "arrow.down.circle", caption: L10n.text("Download"), id: "detail.download") { choosingDownloads = true }
                    let saved = store.favorites.contains(videoFavorite())
                    MacPlate(symbol: "heart", caption: L10n.text(saved ? "Saved" : "Favorite"), on: saved, id: "detail.favorite") {
                        store.favorites.toggle(videoFavorite())
                    }
                }
                .disabled(detail?.episodes.isEmpty ?? true)
            }
        } side: {
            if !text.isEmpty { MacHeroSynopsis(text: text) }
        }
    }

    /// Play, or Continue the episode watched last, as wide as the plates under it; Retry when the details failed.
    @ViewBuilder private var macPlay: some View {
        let continuation = detail.flatMap { watchHistory?.continuation(in: $0.episodes) }
        if let detail, let first = continuation ?? activeEpisodes.first ?? detail.episodes.first {
            Button { startRequest { await play(first) } } label: {
                HStack(spacing: 8) {
                    if loadingEpisode == first.id { ProgressView().appControlSize(.small) } else { Image(systemName: "play.fill") }
                    Text(L10n.text(first.id == continuation?.id ? "Continue" : "Play"))
                }
                .font(.headline).lineLimit(1).frame(maxWidth: .infinity)
            }
            .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
            .accessibilityIdentifier("detail.play")
        } else if detail == nil, error == nil {
            SkeletonBlock(cornerRadius: 20).frame(height: 40)
        } else if detail == nil {
            Button { startRequest { await loadDetail() } } label: {
                Label(L10n.text("Retry"), systemImage: "arrow.clockwise").font(.headline).frame(maxWidth: .infinity)
            }
            .controlButton(prominent: true).tint(Brand.accent).appControlSize(.large)
            .disabled(busy)
            .accessibilityIdentifier("detail.retry")
        }
    }
}

enum MacHeroMetrics {
    static let gutter: CGFloat = 40
    /// Play, and the plates under it: room for five.
    static let actionsWidth: CGFloat = 344
    /// Below this width the synopsis goes under the actions.
    static let compactWidth: CGFloat = 820
    /// Most of the window, as Apple TV's hero fills the screen, with the first row peeking in under it.
    static func height(for size: CGSize) -> CGFloat { max(420, min(size.height * 0.8, size.width * 0.6, 760)) }
}

/// The hero of the Mac's video pages: the backdrop behind it all, and at its foot the heading, then the actions with the
/// side column (the synopsis, the UP主) beside them, or under them in a narrow window.
struct MacVideoHero<Heading: View, Actions: View, Side: View>: View {
    let height: CGFloat
    let width: CGFloat
    let backdrop: URL?
    var backdropHeaders: [String: String] = [:]
    @ViewBuilder let heading: Heading
    @ViewBuilder let actions: Actions
    @ViewBuilder let side: Side

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading
            if width < MacHeroMetrics.compactWidth {
                VStack(alignment: .leading, spacing: 22) {
                    actions.frame(width: MacHeroMetrics.actionsWidth, alignment: .leading)
                    side.frame(maxWidth: 560, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 48) {
                    actions.frame(width: MacHeroMetrics.actionsWidth, alignment: .leading)
                    side.frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, MacHeroMetrics.gutter).padding(.bottom, 44)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottomLeading)
        .background { MacHeroBackdrop(url: backdrop, headers: backdropHeaders).discoverFullBleed() }
        .foregroundStyle(.white)
    }
}

/// The picture behind the Mac's hero, as Apple TV's: a landscape cover sharp across it; a poster, which would crop to a
/// few enlarged pixels, as a soft blur of its colours. Darker toward the text, and its foot fades into the page.
struct MacHeroBackdrop: View {
    let url: URL?
    let headers: [String: String]
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Color.black
            if let image {
                let landscape = CGFloat(image.width) / CGFloat(max(1, image.height)) >= 1.3
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                    .blur(radius: landscape ? 0 : 50, opaque: true)
                    .saturation(landscape ? 1 : 1.25)
                    .transition(.opacity)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.8), location: 0), .init(color: .black.opacity(0.45), location: 0.45),
                                   .init(color: .clear, location: 0.8)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.93), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
        .animation(.easeInOut(duration: 0.4), value: image != nil)
        // A new picture (TMDB's backdrop after the cover) replaces the old one once it is in.
        .task(id: url) { if let url, let loaded = await TMDBArtwork.load(url, maxPixels: 2000, headers: headers) { image = loaded } }
    }
}

/// One of the hero's round glass plates with its word or count under it.
struct MacPlate: View {
    let symbol: String
    let caption: String
    var on = false
    var tint: Color = Brand.rose
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { WatchPlateLabel(symbol: symbol, caption: caption, on: on, tint: tint) }
            .buttonStyle(.plain)
            .accessibilityLabel(caption).accessibilityIdentifier(id).help(caption)
    }
}

/// A plate that opens a menu (Bilibili's coins, More).
struct MacPlateMenu<Content: View>: View {
    let symbol: String
    let caption: String
    var on = false
    var tint: Color = Brand.rose
    let title: String
    let id: String
    @ViewBuilder let content: Content
    var body: some View {
        Menu { content } label: { WatchPlateLabel(symbol: symbol, caption: caption, on: on, tint: tint) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(title).accessibilityIdentifier(id).help(title)
    }
}

/// A few lines of the synopsis beside the actions; a click shows all of it.
struct MacHeroSynopsis: View {
    let text: String
    var lines = 4
    @State private var shown = false
    var body: some View {
        Button { shown = true } label: {
            Text(text).font(.system(size: 14)).lineSpacing(3).lineLimit(lines).multilineTextAlignment(.leading)
                .opacity(0.85).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("detail.synopsis")
        .popover(isPresented: $shown, arrowEdge: .top) {
            let full = Text(text).font(.body).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            if text.count > 500 {
                ScrollView { full }.frame(width: 460, height: 440)
            } else {
                full.frame(width: 460)
            }
        }
    }
}

extension View {
    /// Tells the page when its hero has scrolled away, so the toolbar can take the title.
    func macHeroScroll(heroHeight: CGFloat, past: Binding<Bool>) -> some View {
        onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > heroHeight - 140 } action: { _, value in
            past.wrappedValue = value
        }
    }
}
#endif
