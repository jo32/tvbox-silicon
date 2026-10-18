#if os(iOS)
import SwiftUI
import TVCore

/// The phone's tab bar: up to four sections in the user's order, then More with the rest.
/// Stored as "bar|more", each half a comma-separated list of `AppSection` raw values.
struct PhoneTabs: Equatable {
    static let storageKey = "phoneTabOrder"
    static let barSlots = 4
    static let standard = PhoneTabs(bar: [.home, .live, .music, .search], more: [.sites, .history, .favorites, .downloads, .settings])
    var bar: [AppSection]
    var more: [AppSection]

    init(bar: [AppSection], more: [AppSection]) { self.bar = bar; self.more = more }

    init(stored: String) {
        let halves = stored.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.split(separator: ",").compactMap { AppSection(rawValue: String($0)) }.filter { $0 != .more }
        }
        guard halves.count == 2, !halves[0].isEmpty else { self = .standard; return }
        var bar: [AppSection] = [], more: [AppSection] = []
        for section in halves[0] where !bar.contains(section) && bar.count < Self.barSlots { bar.append(section) }
        // Overflow, then sections a newer version added, land in More.
        for section in halves[0] + halves[1] + Self.standard.more + Self.standard.bar where !bar.contains(section) && !more.contains(section) {
            more.append(section)
        }
        self.init(bar: bar, more: more)
    }

    var stored: String { bar.map(\.rawValue).joined(separator: ",") + "|" + more.map(\.rawValue).joined(separator: ",") }
}

extension AppSection {
    /// Decoration only: the colour of the section's icon tile.
    var glyphTint: Color {
        switch self {
        case .home: Brand.cyan
        case .live: Color(red: 1.0, green: 0.45, blue: 0.32)
        case .music, .nowPlaying: Color(red: 1.0, green: 0.34, blue: 0.56)
        case .search: Color(red: 0.36, green: 0.60, blue: 1.0)
        case .sites: Color(red: 0.60, green: 0.46, blue: 1.0)
        case .history: Brand.amber
        case .favorites: Brand.rose
        case .downloads: Brand.teal
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

/// The phone's More tab: the sections that are not in the tab bar as tiles, and the tab bar editor.
struct MoreView: View {
    @Environment(Store.self) private var store
    @Environment(Updates.self) private var updates
    @AppStorage(PhoneTabs.storageKey) private var storedTabs = ""
    @State private var editing = false

    var body: some View {
        let tabs = PhoneTabs(stored: storedTabs)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 12) {
                    // Pairs; an odd last tile spans the row instead of leaving a hole.
                    ForEach(Array(stride(from: 0, to: tabs.more.count, by: 2)), id: \.self) { start in
                        HStack(spacing: 12) {
                            let row = tabs.more[start..<min(start + 2, tabs.more.count)]
                            ForEach(row) { section in
                                MoreTile(section: section, count: count(section),
                                         badge: section == .settings && !updates.available.isEmpty, wide: row.count == 1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                tabBarCard(tabs)
            }
            .pageContainer()
        }
        .scrollIndicators(.hidden)
        .screenBackdrop()
        .screenTitle(L10n.text("More"))
        .sheet(isPresented: $editing) {
            TabBarEditor(tabs: tabs) { storedTabs = $0.stored }
        }
        #if DEBUG
        // `-qaEditTabs 1` opens the editor for screenshots.
        .onAppear { if UserDefaults.standard.bool(forKey: "qaEditTabs") { editing = true } }
        #endif
    }

    private func count(_ section: AppSection) -> Int? {
        switch section {
        case .sites: store.subscription.map { store.orderedSites($0).count }
        case .history: store.playbackHistory.entries.count
        case .favorites: store.favorites.count
        case .downloads: DownloadLibrary.shared.items.count
        default: nil
        }
    }

    private func tabBarCard(_ tabs: PhoneTabs) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Tab Bar"))
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Button { editing = true } label: {
                VStack(spacing: 14) {
                    TabBarPreview(bar: tabs.bar)
                    HStack(spacing: 12) {
                        Text(L10n.text("Choose your tabs and their order."))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Text(L10n.text("Edit"))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.onAccent)
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Brand.accent, in: Capsule())
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .contentPanel(cornerRadius: 22)
                .contentShape(.rect(cornerRadius: 22))
            }
            .buttonStyle(LiftButtonStyle())
            .accessibilityLabel(L10n.text("Edit Tab Bar"))
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

/// One draggable list: the tab bar's sections, an "In More" divider, then More's. Dragging a section
/// above the divider puts it in the tab bar; a fifth pushes the bar's last section down into More.
private struct TabBarEditor: View {
    private enum Row: Hashable, Identifiable {
        case section(AppSection), divider
        var id: Self { self }
        static func rows(_ tabs: PhoneTabs) -> [Row] { tabs.bar.map(Row.section) + [.divider] + tabs.more.map(Row.section) }
        static func tabs(_ rows: [Row]) -> PhoneTabs {
            let split = rows.firstIndex(of: .divider) ?? rows.count
            let sections: (ArraySlice<Row>) -> [AppSection] = { $0.compactMap { if case .section(let s) = $0 { s } else { nil } } }
            let above = sections(rows[..<split]), below = sections(rows[split...])
            return PhoneTabs(bar: Array(above.prefix(PhoneTabs.barSlots)), more: Array(above.dropFirst(PhoneTabs.barSlots)) + below)
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    private let save: (PhoneTabs) -> Void

    init(tabs: PhoneTabs, save: @escaping (PhoneTabs) -> Void) {
        _rows = State(initialValue: Row.rows(tabs))
        self.save = save
    }

    private var tabs: PhoneTabs { Row.tabs(rows) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TabBarPreview(bar: tabs.bar)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
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
                    Text(L10n.text("Drag to reorder. Up to four sections fit in the tab bar; the rest stay in More."))
                }
            }
            .listRowSpacing(8)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background { Backdrop() }
            .navigationTitle(L10n.text("Edit Tab Bar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Done")) { save(tabs); dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(L10n.text("Reset")) { withAnimation(.smooth) { rows = Row.rows(.standard) } }
                        .disabled(tabs == .standard)
                }
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
        let tabs = Row.tabs(next)
        guard !tabs.bar.isEmpty else { return } // The tab bar keeps at least one section besides More.
        withAnimation(.smooth) { rows = Row.rows(tabs) }
    }
}
#endif
