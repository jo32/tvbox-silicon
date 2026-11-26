#if os(iOS)
import SwiftUI
import TVCore
import UIKit

/// The phone's tab bar: up to four sections in the user's order, then More with the rest.
/// Stored as "bar|more", each half a comma-separated list of `AppSection` raw values.
struct PhoneTabs: Equatable {
    static let storageKey = "phoneTabOrder"
    /// Off: the bar along the bottom shows only the icons.
    static let labelsKey = "phoneTabLabels"
    /// Whether the tab bar shrinks to the current tab while scrolling down (iOS 26). On unless switched off (#1098).
    static let collapsesKey = "phoneTabBarCollapses"
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
    static let standard = PhoneTabs(bar: [.home, .discover, .live, .search], more: [.music, .manga, .novels, .sites, .files, .history, .favorites, .downloads, .messages, .settings])
    /// The iPad sidebar's order until the viewer arranges it. Messages is left out: only the phone lists it.
    static let sidebarStandard: [AppSection] = [.home, .discover, .live, .music, .manga, .novels, .search, .sites, .files, .history, .favorites, .downloads, .settings]
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
        case .novels: Color(red: 0.20, green: 0.70, blue: 0.48)
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
        case .history: store.visibleHistory.count
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #if DEBUG
    @Environment(\.openRoute) private var openRoute
    @State private var qaOpened = false
    #endif
    private var slots: Int { PhoneTabs.slots(horizontal: horizontalSizeClass, vertical: verticalSizeClass) }

    var body: some View {
        // Pushed onto Settings' path like the rows around it, so it comes in from the side as they do (#355). Not
        // `navigationDestination(isPresented:)`: on a row of Settings' lazy Form that modifier isn't reliably seen,
        // and its page isn't on the path, so picking another sidebar section left it on top (see `Route`).
        SettingsLinkRow(symbol: "arrow.up.arrow.down", title: L10n.text("Edit Tab Bar"),
                        subtitle: L10n.text("Choose your tabs and their order.")) { editor }
            #if DEBUG
            // `-qaEditTabs 1` opens the editor for screenshots once Settings is shown; once, since coming back to
            // Settings shows the row again.
            .onAppear {
                guard UserDefaults.standard.bool(forKey: "qaEditTabs"), !qaOpened else { return }
                qaOpened = true
                openRoute?(Route { AnyView(editor) })
            }
            #endif
    }

    @ViewBuilder private var editor: some View {
        if PhoneTabs.inUse(horizontal: horizontalSizeClass) {
            TabBarEditor(tabs: PhoneTabs(stored: storedTabs).arranged(slots: slots, hiding: store.hiddenSections),
                         slots: slots) { storedTabs = $0.stored }
        } else {
            TabBarEditor(sidebar: PhoneTabs.sidebar(stored: storedTabs, hiding: store.hiddenSections)) { storedTabs = $0.stored }
        }
    }
}

/// Two draggable sections (Tab Bar and In More) on phone / compact screens, backed by a real two-section
/// `UICollectionView` list so sections can be dragged across the boundary into any position—including the
/// bar's last slot and More's first slot—without SwiftUI's `.moveDisabled` divider rejecting adjacent drops
/// (#2208). Dragging a section into a full bar pushes the bar's previous last section down into More; dragging
/// one into More leaves the bar shorter, down to one section besides More.
/// For the iPad's sidebar there is no More section: every section is listed in one SwiftUI list.
private struct TabBarEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tabs: PhoneTabs
    @State private var done = false
    private let slots: Int
    private let sidebar: Bool
    private let standard: PhoneTabs
    private let save: (PhoneTabs) -> Void

    init(tabs: PhoneTabs, slots: Int, save: @escaping (PhoneTabs) -> Void) {
        _tabs = State(initialValue: tabs)
        self.slots = slots
        sidebar = false
        standard = PhoneTabs.standard.arranged(slots: slots)
        self.save = save
    }

    /// The iPad sidebar's sections in their order.
    init(sidebar order: [AppSection], save: @escaping (PhoneTabs) -> Void) {
        _tabs = State(initialValue: PhoneTabs(order: order))
        slots = PhoneTabs.wideBarSlots
        sidebar = true
        standard = PhoneTabs(order: PhoneTabs.sidebarStandard.filter(order.contains))
        self.save = save
    }

    private var footerText: String {
        L10n.text(sidebar ? "Drag to reorder. The tab bar and the sidebar show sections in this order."
                  : slots > PhoneTabs.barSlots
                  ? "Drag to reorder. Up to seven sections fit in the tab bar here, and four when the phone is closed; the rest stay in More."
                  : "Drag to reorder. Up to four sections fit in the tab bar; the rest stay in More.")
    }

    var body: some View {
        Group {
            if sidebar {
                List {
                    Section {
                        ForEach(tabs.bar + tabs.more) { section in
                            HStack(spacing: 12) {
                                SectionGlyph(section: section, size: 30)
                                Text(section.title).font(.body.weight(.medium)).lineLimit(1)
                            }
                            .padding(.vertical, 3)
                            .listRowBackground(Surface().clipShape(.rect(cornerRadius: 16, style: .continuous)))
                        }
                        .onMove(perform: moveSidebar)
                    } header: {
                        heading(L10n.text("Tab Bar"), symbol: "dock.rectangle")
                    } footer: {
                        Text(footerText)
                    }
                }
                .listRowSpacing(8)
                .environment(\.editMode, .constant(.active))
                .scrollContentBackground(.hidden)
            } else {
                TabBarCollectionView(tabs: $tabs, slots: slots, footerText: footerText)
                    .ignoresSafeArea()
            }
        }
        .background { Backdrop() }
        .navigationTitle(L10n.text("Edit Tab Bar"))
        .navigationBarTitleDisplayMode(.inline)
        // A push would otherwise offer Back, which would drop the drags made here as silently as Done keeps
        // them: Cancel names that, as it did in the sheet this page replaces (#355).
        .navigationBarBackButtonHidden(true)
        // Done saves once the page is gone: on iOS 17 a new tab set rebuilds the tab view (`RootView`), and doing
        // that while this page was still on More's path brought it back, or crashed when it was mid-pop (#1231).
        .onDisappear { if done { save(tabs) } }
        // The real tab bar covered Reset in the bottom toolbar, and a tap on it left the page mid-edit. The preview
        // above stands in for it; the iPad's sidebar has no tab bar to hide (#355).
        .toolbar(sidebar ? .automatic : .hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text("Cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("Done")) { done = true; dismiss() }.fontWeight(.semibold)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(L10n.text("Reset")) { withAnimation(.smooth) { tabs = standard } }
                    .disabled(tabs == standard)
            }
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .textCase(nil)
    }

    private func moveSidebar(from source: IndexSet, to destination: Int) {
        var order = tabs.bar + tabs.more
        order.move(fromOffsets: source, toOffset: destination)
        withAnimation(.smooth) { tabs = PhoneTabs(order: order) }
    }
}

@MainActor @Observable private final class TabBarPreviewModel {
    var bar: [AppSection]
    init(bar: [AppSection]) { self.bar = bar }
}

private struct LiveTabBarPreview: View {
    let model: TabBarPreviewModel
    var body: some View { TabBarPreview(bar: model.bar) }
}

/// Real two-section `UICollectionView` list for editing the phone's tab bar and More sections.
private struct TabBarCollectionView: UIViewControllerRepresentable {
    @Binding var tabs: PhoneTabs
    let slots: Int
    let footerText: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> ContainerController {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.allowsSelection = false
        collectionView.delegate = context.coordinator
        context.coordinator.configure(collectionView)
        context.coordinator.apply(tabs, animated: false)
        return ContainerController(collectionView: collectionView)
    }

    func updateUIViewController(_ controller: ContainerController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.previewModel.bar = tabs.bar
        context.coordinator.apply(tabs, animated: true)
    }

    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { sectionIndex, environment in
            var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
            config.backgroundColor = .clear
            config.showsSeparators = false
            switch Section(rawValue: sectionIndex) {
            case .preview:
                config.headerMode = .none
                config.footerMode = .none
            case .bar:
                config.headerMode = .supplementary
                config.footerMode = .none
            case .more:
                config.headerMode = .supplementary
                config.footerMode = .supplementary
            case nil:
                break
            }
            let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
            if sectionIndex != Section.preview.rawValue {
                section.interGroupSpacing = 8
            }
            return section
        }
    }

    enum Section: Int, Hashable, Sendable {
        case preview = 0, bar = 1, more = 2
    }

    enum Item: Hashable, Sendable {
        case preview
        case section(AppSection)
        var section: AppSection? {
            if case .section(let value) = self { value } else { nil }
        }
    }

    final class ContainerController: UIViewController {
        let collectionView: UICollectionView
        init(collectionView: UICollectionView) {
            self.collectionView = collectionView
            super.init(nibName: nil, bundle: nil)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func loadView() {
            view = collectionView
            setContentScrollView(collectionView)
        }
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: TabBarCollectionView
        let previewModel: TabBarPreviewModel
        private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?

        init(parent: TabBarCollectionView) {
            self.parent = parent
            previewModel = TabBarPreviewModel(bar: parent.tabs.bar)
        }

        func configure(_ collectionView: UICollectionView) {
            let previewReg = UICollectionView.CellRegistration<UICollectionViewListCell, Void> { [previewModel] cell, _, _ in
                cell.contentConfiguration = UIHostingConfiguration {
                    LiveTabBarPreview(model: previewModel)
                }
                .margins(.horizontal, 0)
                .margins(.vertical, 4)
                cell.automaticallyUpdatesBackgroundConfiguration = false
                cell.backgroundConfiguration = .clear()
            }

            let sectionReg = UICollectionView.CellRegistration<UICollectionViewListCell, AppSection> { cell, _, section in
                cell.contentConfiguration = UIHostingConfiguration {
                    HStack(spacing: 12) {
                        SectionGlyph(section: section, size: 30)
                        Text(section.title).font(.body.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
                .margins(.horizontal, 16)
                .margins(.vertical, 8)
                cell.accessories = [.reorder(displayed: .always, options: .init(showsVerticalSeparator: false))]
                cell.automaticallyUpdatesBackgroundConfiguration = false
                var bg = UIBackgroundConfiguration.clear()
                bg.backgroundColor = UIColor { traits in
                    let palette = ColorThemes.shared.current.palette
                    return UIColor(traits.userInterfaceStyle == .dark ? palette.surfaceDark : palette.surfaceLight)
                }
                bg.cornerRadius = 16
                cell.backgroundConfiguration = bg
            }

            let headerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
                elementKind: UICollectionView.elementKindSectionHeader
            ) { cell, _, indexPath in
                let isMore = indexPath.section == Section.more.rawValue
                let title = L10n.text(isMore ? "In More" : "Tab Bar")
                let symbol = isMore ? AppSection.more.icon : "dock.rectangle"
                cell.contentConfiguration = UIHostingConfiguration {
                    Label(title, systemImage: symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .margins(.horizontal, 16)
                .margins(.top, isMore ? 10 : 0)
                .margins(.bottom, 6)
                cell.automaticallyUpdatesBackgroundConfiguration = false
                cell.backgroundConfiguration = .clear()
            }

            let footerReg = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
                elementKind: UICollectionView.elementKindSectionFooter
            ) { [weak self] cell, _, _ in
                let text = self?.parent.footerText ?? ""
                cell.contentConfiguration = UIHostingConfiguration {
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .margins(.horizontal, 16)
                .margins(.top, 8)
                cell.automaticallyUpdatesBackgroundConfiguration = false
                cell.backgroundConfiguration = .clear()
            }

            let dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
                switch item {
                case .preview:
                    collectionView.dequeueConfiguredReusableCell(using: previewReg, for: indexPath, item: ())
                case .section(let section):
                    collectionView.dequeueConfiguredReusableCell(using: sectionReg, for: indexPath, item: section)
                }
            }
            dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
                if kind == UICollectionView.elementKindSectionHeader {
                    return collectionView.dequeueConfiguredReusableSupplementary(using: headerReg, for: indexPath)
                }
                return collectionView.dequeueConfiguredReusableSupplementary(using: footerReg, for: indexPath)
            }
            dataSource.reorderingHandlers.canReorderItem = { item in
                if case .section = item { return true }
                return false
            }
            dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
                self?.handleReorder(transaction)
            }
            self.dataSource = dataSource
        }

        func apply(_ tabs: PhoneTabs, animated: Bool) {
            guard let dataSource else { return }
            let current = dataSource.snapshot()
            if current.sectionIdentifiers == [.preview, .bar, .more],
               current.itemIdentifiers(inSection: .bar).compactMap(\.section) == tabs.bar,
               current.itemIdentifiers(inSection: .more).compactMap(\.section) == tabs.more {
                return
            }
            var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
            snapshot.appendSections([.preview, .bar, .more])
            snapshot.appendItems([.preview], toSection: .preview)
            snapshot.appendItems(tabs.bar.map(Item.section), toSection: .bar)
            snapshot.appendItems(tabs.more.map(Item.section), toSection: .more)
            dataSource.apply(snapshot, animatingDifferences: animated)
        }

        private func handleReorder(_ transaction: NSDiffableDataSourceTransaction<Section, Item>) {
            let final = transaction.finalSnapshot
            let proposedBar = final.itemIdentifiers(inSection: .bar).compactMap(\.section)
            let proposedMore = final.itemIdentifiers(inSection: .more).compactMap(\.section)
            let previous = parent.tabs
            let (bar, more) = TabBarReorder.reconcile(
                previousBar: previous.bar,
                previousMore: previous.more,
                proposedBar: proposedBar,
                proposedMore: proposedMore,
                slots: parent.slots
            )
            let next = PhoneTabs(bar: bar, more: more)
            previewModel.bar = next.bar
            parent.tabs = next
            if proposedBar != next.bar || proposedMore != next.more {
                Task { @MainActor [weak self] in
                    self?.apply(next, animated: true)
                }
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
            atCurrentIndexPath currentIndexPath: IndexPath,
            toProposedIndexPath proposedIndexPath: IndexPath
        ) -> IndexPath {
            if proposedIndexPath.section == Section.preview.rawValue {
                return IndexPath(item: 0, section: Section.bar.rawValue)
            }
            if originalIndexPath.section == Section.bar.rawValue,
               parent.tabs.bar.count <= 1,
               proposedIndexPath.section != Section.bar.rawValue {
                return IndexPath(item: 0, section: Section.bar.rawValue)
            }
            return proposedIndexPath
        }
    }
}
#endif
