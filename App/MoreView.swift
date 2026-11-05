#if os(iOS)
import SwiftUI
import TVCore

/// The phone's tab bar: up to four sections in the user's order, then More with the rest.
/// Stored as "bar|more", each half a comma-separated list of `AppSection` raw values.
struct PhoneTabs: Equatable {
    static let storageKey = "phoneTabOrder"
    /// Off: the bar along the bottom shows only the icons.
    static let labelsKey = "phoneTabLabels"
    static let barSlots = 4
    /// iPhone Duo's inner display (regular both ways): its side tab bar has room for seven before More.
    static let wideBarSlots = 7
    /// Whether this screen uses the phone's tab bar (and so More and the tab bar editor). Every iPhone screen
    /// does, not only compact ones: iPhone Duo's inner display is regular both ways, and there the full set of
    /// sections overflowed the side tab bar into the system's own More list, without the editor. iPads on iOS 17
    /// use it too. Their classic tab bar shows seven tabs and moves the rest into UIKit's More list, which wraps
    /// each tab's NavigationStack in its own navigation controller: opening a section there and then another tab
    /// crashed with "Layout requested for visible navigation bar ... nest wrapped navigation controllers" (#301).
    /// Seven sections and the app's own More fit that bar without the system list.
    @MainActor static func inUse(horizontal: UserInterfaceSizeClass?) -> Bool {
        if #unavailable(iOS 18) { return true }
        return horizontal == .compact || UIDevice.current.userInterfaceIdiom == .phone
    }
    /// The bar's places on a screen with these size classes.
    static func slots(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Int {
        horizontal == .regular && vertical == .regular ? wideBarSlots : barSlots
    }
    static let standard = PhoneTabs(bar: [.home, .discover, .live, .search], more: [.music, .manga, .sites, .files, .history, .favorites, .downloads, .messages, .settings])
    /// The iPad sidebar's order until the viewer arranges it. Messages is left out: only the phone lists it.
    static let sidebarStandard: [AppSection] = [.home, .discover, .live, .music, .manga, .search, .sites, .files, .history, .favorites, .downloads, .settings]
    var bar: [AppSection]
    var more: [AppSection]

    init(bar: [AppSection], more: [AppSection]) { self.bar = bar; self.more = more }

    /// One list, as the iPad's sidebar has it: the bar takes as many as it can hold and More the rest, so a narrow
    /// Split View window's tab bar keeps the same order.
    init(order: [AppSection]) { self.init(bar: Array(order.prefix(Self.wideBarSlots)), more: Array(order.dropFirst(Self.wideBarSlots))) }

    /// The sections of the iPad's sidebar (iOS 18 and later, full width), in the tab bar editor's order (#427).
    static func sidebar(stored: String, hiding hidden: [AppSection] = []) -> [AppSection] {
        let order = stored.isEmpty ? sidebarStandard : { let tabs = PhoneTabs(stored: stored); return tabs.bar + tabs.more }()
        return order.filter { $0 != .messages && !hidden.contains($0) }
    }

    init(stored: String) {
        let halves = stored.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }.filter { $0 != .more }
        }
        guard halves.count == 2, !halves[0].isEmpty else { self = .standard; return }
        var bar: [AppSection] = [], more: [AppSection] = []
        for section in halves[0] where !bar.contains(section) && bar.count < Self.wideBarSlots { bar.append(section) }
        // Add Discover once to an existing installation's visible tabs. Preserve their relative
        // order; arranged(slots:) carries the last tab into More when the bar is full.
        if !(halves[0] + halves[1]).contains(.discover) { bar.insert(.discover, at: min(1, bar.count)) }
        // Overflow, then sections a newer version added, land in More.
        for section in halves[0] + halves[1] + Self.standard.more + Self.standard.bar where !bar.contains(section) && !more.contains(section) {
            more.append(section)
        }
        self.init(bar: bar, more: more)
    }

    var stored: String { bar.map(\.rawValue).joined(separator: ",") + "|" + more.map(\.rawValue).joined(separator: ",") }

    /// For a bar with `slots` places and without the sections `hidden`: the sections keep their order, the bar
    /// takes the first and More the rest. A bar the viewer trimmed below four in the editor keeps that many
    /// places (#449; a hidden one is still refilled from More). A full bar fills every place: opening iPhone Duo
    /// moves the top of More into its wider side bar, and closing it moves them back.
    func arranged(slots: Int, hiding hidden: [AppSection] = []) -> PhoneTabs {
        let all = (bar + more).filter { !hidden.contains($0) }
        let places = bar.count < Self.barSlots ? min(bar.count, slots) : slots
        return PhoneTabs(bar: Array(all.prefix(places)), more: Array(all.dropFirst(places)))
    }
}

extension AppSection {
    /// Decoration only: the colour of the section's icon tile.
    var glyphTint: Color {
        switch self {
        case .home: Brand.cyan
        case .discover: Color(red: 0.43, green: 0.48, blue: 1.0)
        case .live: Color(red: 1.0, green: 0.45, blue: 0.32)
        case .music, .nowPlaying: Color(red: 1.0, green: 0.34, blue: 0.56)
        case .manga: Color(red: 1.0, green: 0.58, blue: 0.0)
        case .search: Color(red: 0.36, green: 0.60, blue: 1.0)
        case .sites: Color(red: 0.60, green: 0.46, blue: 1.0)
        case .history: Brand.amber
        case .favorites: Brand.rose
        case .downloads: Brand.teal
        case .messages: Color(red: 1.0, green: 0.60, blue: 0.20)
        case .files: Color(red: 0.25, green: 0.62, blue: 0.98)
        case .settings, .more: Color(white: 0.56)
        }
    }
}

/// A section's symbol on a gradient squircle in its own colour.
struct SectionGlyph: View {
    let section: AppSection
    var size: CGFloat = 36
    var body: some View {
        let tint = section.glyphTint
        Image(systemName: section.icon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint.blend(with: .white, by: 0.12), tint.blend(with: .black, by: 0.2)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A miniature of the tab bar, so the order being edited is visible at a glance.
struct TabBarPreview: View {
    let bar: [AppSection]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(bar + [.more]) { item in
                VStack(spacing: 3) {
                    Image(systemName: item.icon).font(.system(size: 17, weight: .medium)).frame(height: 22)
                    Text(item.title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(item == bar.first ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
        .glassSurface(.regular, in: Capsule())
        .animation(.smooth(duration: 0.3), value: bar)
        .accessibilityElement(children: .combine)
    }
}

/// The phone's More tab: the sections that are not in the tab bar, as tiles. The tab bar editor is in Settings
/// (`EditTabBarRow`): a miniature tab bar here sat right above the real one and was easy to tap by mistake (#326).
struct MoreView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @Environment(Announcements.self) private var announcements
    @AppStorage(PhoneTabs.storageKey) private var storedTabs = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var slots: Int { PhoneTabs.slots(horizontal: horizontalSizeClass, vertical: verticalSizeClass) }

    var body: some View {
        let tabs = PhoneTabs(stored: storedTabs).arranged(slots: slots, hiding: store.hiddenSections)
        ScrollView {
            VStack(spacing: 12) {
                // Pairs; an odd last tile spans the row instead of leaving a hole.
                ForEach(Array(stride(from: 0, to: tabs.more.count, by: 2)), id: \.self) { start in
                    HStack(spacing: 12) {
                        let row = tabs.more[start..<min(start + 2, tabs.more.count)]
                        ForEach(row) { section in
                            MoreTile(section: section, count: count(section),
                                     badge: badge(section), wide: row.count == 1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .pageContainer()
        }
        .scrollIndicators(.hidden)
        .screenBackdrop()
        .screenTitle(L10n.text("More"))
    }

    private func badge(_ section: AppSection) -> Bool {
        switch section {
        case .settings: !updates.available.isEmpty
        case .messages: !announcements.unread.isEmpty
        default: false
        }
    }

    private func count(_ section: AppSection) -> Int? {
        switch section {
        case .messages: announcements.all.count
        case .sites: store.subscription.map { store.orderedSites($0).count }
        case .history: store.playbackHistory.entries.count
        case .favorites: store.favorites.items.count
        case .downloads: DownloadLibrary.shared.items.count
        default: nil
        }
    }
}

/// Reminders-style tile: icon and count on top, name below, washed in the section's colour.
private struct MoreTile: View {
    let section: AppSection
    let count: Int?
    let badge: Bool
    /// Alone on its row; only then is there room for Settings' version.
    let wide: Bool
    private var version: String? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { L10n.text("Version %@", $0) }
    }
    var body: some View {
        NavigationLink(value: section) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    SectionGlyph(section: section, size: 38)
                    Spacer(minLength: 0)
                    if badge {
                        NewBadge()
                    } else if section == .settings, wide, let version {
                        Text(version).font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.secondary).lineLimit(1)
                    } else if let count {
                        Text(count, format: .number)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit().lineLimit(1)
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer(minLength: 0)
                Text(section.title)
                    .font(.body.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, maxHeight: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [section.glyphTint.opacity(0.24), section.glyphTint.opacity(0.03)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .contentPanel(cornerRadius: 22)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(LiftButtonStyle())
    }
}

/// Settings' row for the tab bar editor. On an iPad's sidebar, which has no More, the editor is one list.
struct EditTabBarRow: View {
    @Environment(Store.self) private var store
    @AppStorage(PhoneTabs.storageKey) private var storedTabs = ""
    @State private var editing = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var slots: Int { PhoneTabs.slots(horizontal: horizontalSizeClass, vertical: verticalSizeClass) }

    var body: some View {
        Group {
            Button { editing = true } label: {
                HStack(spacing: 8) {
                    FormLabel(symbol: "arrow.up.arrow.down", title: L10n.text("Edit Tab Bar"),
                              subtitle: L10n.text("Choose your tabs and their order."))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            // A button in a list draws its title in the tint; this one reads like the rows around it.
            .tint(.primary)
            // Pushed like the Settings rows around it, so it comes in from the side as they do (#355).
            .navigationDestination(isPresented: $editing) {
                if PhoneTabs.inUse(horizontal: horizontalSizeClass) {
                    TabBarEditor(tabs: PhoneTabs(stored: storedTabs).arranged(slots: slots, hiding: store.hiddenSections),
                                 slots: slots) { storedTabs = $0.stored }
                } else {
                    TabBarEditor(sidebar: PhoneTabs.sidebar(stored: storedTabs, hiding: store.hiddenSections)) { storedTabs = $0.stored }
                }
            }
            #if DEBUG
            // `-qaEditTabs 1` opens the editor for screenshots once Settings is shown.
            .onAppear { if UserDefaults.standard.bool(forKey: "qaEditTabs") { editing = true } }
            #endif
        }
    }
}

/// One draggable list: the tab bar's sections, an "In More" divider, then More's. Dragging a section
/// above the divider puts it in the tab bar; a fifth pushes the bar's last section down into More.
/// Dragging one below it leaves the bar shorter, down to one section besides More.
/// For the iPad's sidebar there is no divider: every section is listed, in order.
private struct TabBarEditor: View {
    private enum Row: Hashable, Identifiable {
        case section(AppSection), divider
        var id: Self { self }
        static func rows(_ tabs: PhoneTabs, sidebar: Bool) -> [Row] {
            sidebar ? (tabs.bar + tabs.more).map(Row.section) : tabs.bar.map(Row.section) + [.divider] + tabs.more.map(Row.section)
        }
        static func tabs(_ rows: [Row], slots: Int) -> PhoneTabs {
            let split = rows.firstIndex(of: .divider) ?? rows.count
            let sections: (ArraySlice<Row>) -> [AppSection] = { $0.compactMap { if case .section(let s) = $0 { s } else { nil } } }
            let above = sections(rows[..<split]), below = sections(rows[split...])
            return PhoneTabs(bar: Array(above.prefix(slots)), more: Array(above.dropFirst(slots)) + below)
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    private let slots: Int
    private let sidebar: Bool
    private let standard: PhoneTabs
    private let save: (PhoneTabs) -> Void

    init(tabs: PhoneTabs, slots: Int, save: @escaping (PhoneTabs) -> Void) {
        _rows = State(initialValue: Row.rows(tabs, sidebar: false))
        self.slots = slots
        sidebar = false
        standard = PhoneTabs.standard.arranged(slots: slots)
        self.save = save
    }

    /// The iPad sidebar's sections in their order.
    init(sidebar order: [AppSection], save: @escaping (PhoneTabs) -> Void) {
        _rows = State(initialValue: Row.rows(PhoneTabs(order: order), sidebar: true))
        slots = PhoneTabs.wideBarSlots
        sidebar = true
        standard = PhoneTabs(order: PhoneTabs.sidebarStandard.filter(order.contains))
        self.save = save
    }

    private var tabs: PhoneTabs { Row.tabs(rows, slots: slots) }

    var body: some View {
        List {
            if !sidebar {
                Section {
                    TabBarPreview(bar: tabs.bar)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
            Section {
                ForEach(rows) { row in
                    switch row {
                    case .section(let section):
                        HStack(spacing: 12) {
                            SectionGlyph(section: section, size: 30)
                            Text(section.title).font(.body.weight(.medium)).lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        .listRowBackground(Surface().clipShape(.rect(cornerRadius: 16, style: .continuous)))
                    case .divider:
                        heading(L10n.text("In More"), symbol: AppSection.more.icon)
                            .padding(.top, 10)
                            .listRowBackground(Color.clear)
                            .moveDisabled(true)
                    }
                }
                .onMove(perform: move)
            } header: {
                heading(L10n.text("Tab Bar"), symbol: "dock.rectangle")
            } footer: {
                Text(L10n.text(sidebar ? "Drag to reorder. The tab bar and the sidebar show sections in this order."
                               : slots > PhoneTabs.barSlots
                               ? "Drag to reorder. Up to seven sections fit in the tab bar here, and four when the phone is closed; the rest stay in More."
                               : "Drag to reorder. Up to four sections fit in the tab bar; the rest stay in More."))
            }
        }
        .listRowSpacing(8)
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background { Backdrop() }
        .navigationTitle(L10n.text("Edit Tab Bar"))
        .navigationBarTitleDisplayMode(.inline)
        // A push would otherwise offer Back, which would drop the drags made here as silently as Done keeps
        // them: Cancel names that, as it did in the sheet this page replaces (#355).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text("Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("Done")) { save(tabs); dismiss() }.fontWeight(.semibold)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(L10n.text("Reset")) { withAnimation(.smooth) { rows = Row.rows(standard, sidebar: sidebar) } }
                    .disabled(tabs == standard)
            }
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func move(from source: IndexSet, to destination: Int) {
        var next = rows
        next.move(fromOffsets: source, toOffset: destination)
        let tabs = Row.tabs(next, slots: slots)
        guard !tabs.bar.isEmpty else { return } // The tab bar keeps at least one section besides More.
        withAnimation(.smooth) { rows = Row.rows(tabs, sidebar: sidebar) }
    }
}
#endif
