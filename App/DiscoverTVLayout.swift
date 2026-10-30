import SwiftUI
import TVCore

/// Catalog measurements follow viewing distance rather than the phone's compact layout.
enum DiscoverLayout {
    #if os(tvOS)
    static let gutter: CGFloat = 50
    static let spacing: CGFloat = 40
    static let posterWidth: CGFloat = 220
    static let landscapeWidth: CGFloat = 360
    static let personWidth: CGFloat = 160
    static let heading: CGFloat = 28
    static let headingHeight: CGFloat = 44
    static let caption: CGFloat = 28
    static let secondary: CGFloat = 24
    static let captionHeight: CGFloat = 70
    static func heroHeight(_ width: CGFloat) -> CGFloat { width * 0.46875 }
    #else
    static let gutter: CGFloat = 17
    static let spacing: CGFloat = 13
    static let posterWidth: CGFloat = 116
    static let landscapeWidth: CGFloat = 177
    static let personWidth: CGFloat = 83
    static let heading: CGFloat = 16
    static let headingHeight: CGFloat = 32
    static let caption: CGFloat = 13
    static let secondary: CGFloat = 11
    static let captionHeight: CGFloat = 46
    static func heroHeight(_ width: CGFloat) -> CGFloat { width < 600 ? width * 1.5 : min(720, width * 0.65) }
    #endif
}

#if os(tvOS)
import UIKit

enum DiscoverTVFocus: Hashable { case search, page(Int) }

/// Directional focus moves between page dots; Select opens the title and Down enters the rail.
/// The full hero is a focus section so the dot group is reachable from the sidebar.
struct DiscoverTVHeroPager: View {
    let items: [TMDBCatalog.Item]
    let details: [String: TMDBMatch.Details]
    @Binding var selection: String?
    @Environment(\.openRoute) private var openRoute
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var focus: FocusState<DiscoverTVFocus?>.Binding
    private var focusedPage: Int? {
        if case .page(let index) = focus.wrappedValue { return index }
        return nil
    }
    @Namespace private var pagesScope
    private var index: Int { items.firstIndex { $0.key == selection } ?? 0 }

    var body: some View {
        if !items.isEmpty {
            let item = items[index]
            let detail = details[item.key]
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    Spacer(minLength: 120)
                    Group {
                        if let logo = detail?.logo {
                            DiscoverTVLogo(url: logo).id(logo)
                        } else {
                            Text(item.name).font(.system(size: 64, weight: .bold)).lineLimit(2)
                                .frame(maxWidth: 720, alignment: .leading)
                        }
                    }
                    Text([detail?.genres.prefix(2).joined(separator: " / ") ?? item.genreNames,
                          detail?.date ?? item.year.map(String.init) ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 24)).lineLimit(1)
                    Text(detail?.overview ?? item.overview)
                        .font(.system(size: 24)).lineSpacing(4).lineLimit(2)
                        .frame(width: 600, alignment: .leading).foregroundStyle(.white.opacity(0.85))
                    if let rating = item.rating {
                        HStack(spacing: 8) {
                            Text("TMDB").font(.system(size: 19, weight: .bold)).foregroundStyle(.cyan)
                            Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 23))
                        }
                    }
                }
                .padding(.horizontal, DiscoverLayout.gutter).padding(.bottom, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle()).multilineTextAlignment(.leading)
                .allowsHitTesting(false)

            }
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { page in
                        Button { openRoute?(Route { AnyView(DiscoverDetailView(item: items[page])) }) } label: {
                            Circle().fill(.white.opacity(page == index ? 1 : 0.35))
                                .frame(width: page == focusedPage ? 13 : 8, height: page == focusedPage ? 13 : 8)
                                .frame(width: 28, height: 48).offset(y: 120)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(DiscoverTVDotStyle())
                        .focused(focus, equals: .page(page))
                        .onMoveCommand { direction in
                            if direction == .up { focus.wrappedValue = .search }
                        }
                        .prefersDefaultFocus(page == index, in: pagesScope)
                        .accessibilityLabel(items[page].name)
                        .accessibilityIdentifier("discover.pageDot.\(page)")
                        .accessibilityAddTraits(page == index ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, 16)
                .background(alignment: .bottom) {
                    Capsule().fill(.white.opacity(focusedPage == nil ? 0 : 0.16)).frame(height: 48).offset(y: 120)
                }
                .overlay(alignment: .bottom) {
                    Capsule().strokeBorder(.white.opacity(focusedPage == nil ? 0 : 0.6), lineWidth: 2).frame(height: 48).offset(y: 120)
                        .allowsHitTesting(false)
                }
                .padding(.top, 160).padding(.bottom, 120)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusScope(pagesScope)
            .focusSection()
            .onChange(of: focusedPage) { _, page in
                guard let page, items.indices.contains(page) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { selection = items[page].key }
            }
        }
    }
}

private struct DiscoverTVLogo: View {
    let url: URL
    @State private var aspect: CGFloat?
    var body: some View {
        TMDBArtwork(url: url, maxPixels: 1200, fill: false, aspect: $aspect)
            .frame(width: min(580, 180 * (aspect ?? 3.2)), height: 180)
    }
}

private struct DiscoverTVDotStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.85 : 1)
    }
}
/// A native horizontal collection owns its boundary focus event: See All opens at the start of the row only when the
/// first title receives Left, as in Rex. Before then it is invisible and absent from accessibility.
struct DiscoverTVNativeShelf: UIViewControllerRepresentable {
    let items: [TMDBCatalog.Item]
    let identifier: String
    let landscape: Bool
    let select: (TMDBCatalog.Item?) -> Void

    static func posterSize(landscape: Bool) -> CGSize {
        landscape ? CGSize(width: DiscoverLayout.landscapeWidth, height: DiscoverLayout.landscapeWidth * 9 / 16)
            : CGSize(width: DiscoverLayout.posterWidth, height: DiscoverLayout.posterWidth * 1.5)
    }

    func makeUIViewController(context: Context) -> Controller { Controller(source: self) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.update(self) }

    /// One row of items laid end to end, exactly `DiscoverLayout.spacing` apart. (The flow layout widened every gap
    /// once the row began with the one-point See All.)
    final class RowLayout: UICollectionViewLayout {
        var leading: () -> CGFloat = { 0 }
        var size: (Int) -> CGSize = { _ in .zero }
        private var frames: [CGRect] = []
        override func prepare() {
            super.prepare()
            guard let collection = collectionView, collection.numberOfSections > 0 else { frames = []; return }
            var x = leading()
            frames = (0..<collection.numberOfItems(inSection: 0)).map { index in
                let size = size(index)
                defer { x += size.width + DiscoverLayout.spacing }
                return CGRect(origin: CGPoint(x: x, y: 24), size: size)
            }
        }
        override var collectionViewContentSize: CGSize {
            CGSize(width: (frames.last?.maxX ?? 0) + DiscoverLayout.gutter, height: collectionView?.bounds.height ?? 0)
        }
        override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
            frames.indices.filter { frames[$0].intersects(rect) }.map(attributes)
        }
        override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
            frames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
        }
        private func attributes(_ index: Int) -> UICollectionViewLayoutAttributes {
            let value = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            value.frame = frames[index]
            return value
        }
    }

    final class Controller: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
        private var source: DiscoverTVNativeShelf
        private var revealed = false
        private var preferred: IndexPath? = IndexPath(item: 1, section: 0)
        private let collection: UICollectionView

        init(source: DiscoverTVNativeShelf) {
            self.source = source
            let layout = RowLayout()
            collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
            super.init(nibName: nil, bundle: nil)
            layout.leading = { [unowned self] in revealed ? DiscoverLayout.gutter : DiscoverLayout.gutter - DiscoverLayout.spacing - 1 }
            layout.size = { [unowned self] in itemSize($0) }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = collection
            collection.backgroundColor = .clear
            collection.overrideUserInterfaceStyle = .dark
            collection.showsHorizontalScrollIndicator = false
            collection.contentInsetAdjustmentBehavior = .never
            // The focused poster grows past the row; its lift and shadow must not be cut off.
            collection.clipsToBounds = false
            collection.dataSource = self
            collection.delegate = self
            collection.register(Cell.self, forCellWithReuseIdentifier: "title")
            collection.register(MoreCell.self, forCellWithReuseIdentifier: "more")
        }

        func update(_ value: DiscoverTVNativeShelf) {
            let changed = source.items.map(\.key) != value.items.map(\.key) || source.landscape != value.landscape
            source = value
            if changed, isViewLoaded { collection.reloadData() }
        }

        // Item 0 is See All. Until the first Left past the first title it is a 1-point sliver in the margin, invisible
        // and outside accessibility, so that Left lands on it (rather than finding nothing and opening the sidebar)
        // and it widens in that same focus move.
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            source.items.isEmpty ? 0 : source.items.count + 1
        }
        private func itemSize(_ index: Int) -> CGSize {
            let poster = DiscoverTVNativeShelf.posterSize(landscape: source.landscape)
            let width = index > 0 ? poster.width : revealed ? MoreCell.width : 1
            return CGSize(width: width, height: poster.height + DiscoverLayout.captionHeight)
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let poster = DiscoverTVNativeShelf.posterSize(landscape: source.landscape)
            if indexPath.item == 0 {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "more", for: indexPath) as! MoreCell
                cell.show(height: poster.height, identifier: "discover.more.\(source.identifier)", revealed: revealed)
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "title", for: indexPath) as! Cell
            let item = source.items[indexPath.item - 1]
            cell.show(item, landscape: source.landscape, size: poster, identifier: "discover.title.\(source.identifier).\(item.key)")
            return cell
        }
        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            source.select(indexPath.item == 0 ? nil : source.items[indexPath.item - 1])
        }
        func collectionView(_ collectionView: UICollectionView, shouldUpdateFocusIn context: UICollectionViewFocusUpdateContext) -> Bool {
            guard context.nextFocusedIndexPath?.item == 0 else { return true }
            // Only Left from the first title opens See All; Down or Up into the row never lands on the sliver.
            guard revealed || (context.previouslyFocusedIndexPath?.item == 1 && context.focusHeading.contains(.left)) else { return false }
            if !revealed {
                revealed = true
                (collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? MoreCell)?.reveal()
                UIView.animate(withDuration: 0.25) { self.collection.collectionViewLayout.invalidateLayout(); self.collection.layoutIfNeeded() }
            }
            return true
        }
        func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? { preferred }
        func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            if let next = context.nextFocusedIndexPath, next.item > 0 { preferred = next }
            guard revealed, context.previouslyFocusedIndexPath?.item == 0, context.nextFocusedIndexPath?.item != 0 else { return }
            revealed = false
            preferred = context.nextFocusedIndexPath ?? IndexPath(item: 1, section: 0)
            let more = collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? MoreCell
            more?.conceal()
            coordinator.addCoordinatedAnimations { self.collection.collectionViewLayout.invalidateLayout(); self.collection.layoutIfNeeded() }
        }
    }

    /// A title as on the Home screen: the system lifts the poster, and the centred captions move down with it.
    final class Cell: UICollectionViewCell {
        private let poster = UIImageView()
        private let title = UILabel()
        private let detail = UILabel()
        private var posterHeight: NSLayoutConstraint!
        private var url: URL?
        private var size = CGSize.zero
        private var task: Task<Void, Never>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityTraits = [.button]
            // The system's focus effect rounds the corners and draws the glass rim, as on Rex's covers; masking it to
            // the image's contents would cut the rim off.
            poster.adjustsImageWhenAncestorFocused = true
            title.font = .systemFont(ofSize: DiscoverLayout.caption, weight: .medium)
            title.textColor = .white
            detail.font = .systemFont(ofSize: DiscoverLayout.secondary)
            detail.textColor = UIColor(white: 1, alpha: 0.55)
            for label in [title, detail] { label.textAlignment = .center; label.lineBreakMode = .byTruncatingTail }
            for view in [poster, title, detail] { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }
            posterHeight = poster.heightAnchor.constraint(equalToConstant: 330)
            NSLayoutConstraint.activate([
                poster.topAnchor.constraint(equalTo: contentView.topAnchor),
                poster.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                poster.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                posterHeight,
                title.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 10),
                title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                title.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
                detail.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // The captions move down with the poster's focus growth (about 12%, half of it below), as on the Home screen.
        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            let shift = isFocused ? CGAffineTransform(translationX: 0, y: posterHeight.constant * 0.06 + 6) : .identity
            coordinator.addCoordinatedAnimations { [title, detail] in title.transform = shift; detail.transform = shift }
        }

        func show(_ item: TMDBCatalog.Item, landscape: Bool, size: CGSize, identifier: String) {
            accessibilityIdentifier = identifier
            accessibilityLabel = [item.name, item.year.map(String.init)].compactMap { $0 }.joined(separator: "、")
            title.text = item.name
            detail.text = [item.year.map(String.init), landscape && !item.genreNames.isEmpty ? item.genreNames : nil].compactMap { $0 }.joined(separator: "  ")
            posterHeight.constant = size.height
            let url = landscape ? item.backdrop ?? item.poster : item.poster
            guard url != self.url || size != self.size || poster.image == nil else { return }
            self.url = url; self.size = size
            task?.cancel()
            poster.image = Self.cover(nil, size)
            guard let url else { return }
            task = Task { [weak self] in
                guard let image = await PosterPalette.image(url), !Task.isCancelled, let self, self.url == url else { return }
                self.poster.image = Self.cover(image, size)
            }
        }

        /// The cover cropped to fill the poster, or a placeholder plate.
        static func cover(_ image: CGImage?, _ size: CGSize) -> UIImage {
            UIGraphicsImageRenderer(size: size).image { context in
                let bounds = CGRect(origin: .zero, size: size)
                guard let image else { UIColor(white: 0.2, alpha: 1).setFill(); context.fill(bounds); return }
                let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
                let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                UIImage(cgImage: image).draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                                        width: drawn.width, height: drawn.height))
            }
        }
    }

    /// The row's See All, as tall as the posters: a dim plate that turns light under focus.
    final class MoreCell: UICollectionViewCell {
        static let width: CGFloat = 96
        private let plate = UIView()
        private let label = UILabel()
        private let symbol = UIImageView(image: UIImage(systemName: "chevron.right.circle.fill"))
        private var plateHeight: NSLayoutConstraint!

        override init(frame: CGRect) {
            super.init(frame: frame)
            accessibilityTraits = [.button]
            accessibilityLabel = L10n.text("See All")
            plate.layer.cornerRadius = 16
            plate.layer.cornerCurve = .continuous
            label.text = L10n.text("See All")
            label.numberOfLines = 2
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 26, weight: .medium)
            symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
            let stack = UIStackView(arrangedSubviews: [label, symbol])
            stack.axis = .vertical; stack.alignment = .center; stack.spacing = 12
            for view in [plate, stack] { view.translatesAutoresizingMaskIntoConstraints = false }
            contentView.addSubview(plate)
            plate.addSubview(stack)
            plateHeight = plate.heightAnchor.constraint(equalToConstant: 330)
            NSLayoutConstraint.activate([
                plate.topAnchor.constraint(equalTo: contentView.topAnchor),
                plate.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                plate.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                plateHeight,
                stack.centerYAnchor.constraint(equalTo: plate.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: plate.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: plate.trailingAnchor, constant: -8)
            ])
            restyle()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func show(height: CGFloat, identifier: String, revealed: Bool) {
            plateHeight.constant = height
            accessibilityIdentifier = identifier
            isAccessibilityElement = revealed
            contentView.alpha = revealed ? 1 : 0
        }
        func reveal() {
            isAccessibilityElement = true
            UIView.animate(withDuration: 0.25) { self.contentView.alpha = 1 }
        }
        func conceal() {
            isAccessibilityElement = false
            UIView.animate(withDuration: 0.2) { self.contentView.alpha = 0 }
        }
        private func restyle() {
            plate.backgroundColor = isFocused ? UIColor(white: 0.88, alpha: 1) : UIColor(white: 1, alpha: 0.12)
            label.textColor = isFocused ? .black : .white
            symbol.tintColor = isFocused ? .black : .white
        }
        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            coordinator.addCoordinatedAnimations {
                self.restyle()
                self.transform = self.isFocused ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
                self.layer.shadowOpacity = self.isFocused ? 0.35 : 0
                self.layer.shadowRadius = 18
                self.layer.shadowOffset = CGSize(width: 0, height: 10)
            }
        }
    }
}

/// Lift and shadow under focus, for cards and portraits that draw their own plate.
struct DiscoverTVLiftStyle: ButtonStyle {
    var scale: CGFloat = 1.06
    func makeBody(configuration: Configuration) -> some View { Lift(configuration: configuration, scale: scale) }
    private struct Lift: View {
        let configuration: ButtonStyleConfiguration
        let scale: CGFloat
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? scale * 0.97 : focused ? scale : 1)
                .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 24, y: 14)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}

/// A filter chip: a Liquid Glass capsule that turns white under focus; one with a value set stays lighter.
struct DiscoverTVChipStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View { Chip(configuration: configuration, active: active) }
    private struct Chip: View {
        let configuration: ButtonStyleConfiguration
        let active: Bool
        @Environment(\.isFocused) private var focused
        var body: some View {
            configuration.label
                .font(.system(size: 26, weight: .medium)).lineLimit(1)
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 30).frame(height: 62)
                .glassSurface(glass, in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.05 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 16, y: 10)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
        private var glass: GlassStyle {
            if focused { return .regular.tint(.white.opacity(0.9)).interactive() }
            return active ? .regular.tint(.white.opacity(0.28)).interactive() : .regular.interactive()
        }
    }
}

/// Catalog search on the Apple TV, a page laid out for the remote: the field across the top, filters as a row of
/// chips that open menus, then people and rows of wide title cards, each row opening into a grid.
struct DiscoverTVSearchView: View {
    private enum Field: Hashable { case query }
    @State private var model = DiscoverSearchModel()
    @State private var query = ""
    @State private var filter: TMDBCatalog.Filter?
    @State private var expanded: TMDBCatalog.SearchKind?
    @State private var keywordsShown = false
    @State private var revision = 0
    @FocusState private var focus: Field?
    private var keyword: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var request: DiscoverSearchRequest { .init(keyword: keyword, feed: .popular, filter: filter, revision: revision) }
    private var current: TMDBCatalog.Filter { filter ?? .init() }
    private let gutter = DiscoverLayout.gutter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                HStack(spacing: 30) {
                    Image(systemName: "magnifyingglass").font(.system(size: 30, weight: .medium))
                        .frame(width: 70, height: 70).background(.white.opacity(0.12), in: Circle())
                    TextField(L10n.text("Search"), text: $query)
                        .focused($focus, equals: .query)
                        .onSubmit { model.remember(keyword) }
                        .accessibilityIdentifier("discover.search.field")
                }.padding(.horizontal, gutter).focusSection()
                chips
                if model.loading && model.groups.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 80) }
                ForEach([TMDBCatalog.SearchKind.person, .movie, .tv], id: \.self) { kind in
                    if let group = model.groups[kind], group.count > 0 { section(group, kind: kind) }
                }
                if model.isEmpty && !model.loading && !model.failed {
                    ContentUnavailableView(L10n.text("No Results"), systemImage: "magnifyingglass",
                                           description: Text(L10n.text("Try another title or change your filters.")))
                        .accessibilityIdentifier("discover.search.empty")
                }
                if model.failed { Button(L10n.text("Try Again")) { revision += 1 }.frame(maxWidth: .infinity) }
            }.padding(.top, 50).padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .background { DiscoverSearchAtmosphere().ignoresSafeArea() }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(edges: .horizontal)
        .defaultFocus($focus, .query)
        .onChange(of: query) { _, value in if value.count > 100 { query = String(value.prefix(100)) } }
        .onChange(of: filter) { _, _ in expanded = nil }
        .task(id: request) { await model.load(request) }
        .sheet(isPresented: $keywordsShown) {
            DiscoverSearchFilters(filter: Binding(get: { current }, set: { filter = $0 }), section: .keywords).frame(width: 900)
        }
    }

    // MARK: Filters

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 20) {
                menu(.type) {
                    Picker(DiscoverFilterSection.type.title, selection: binding(\.kind, set: { $0.switchKind($1) })) {
                        ForEach([TMDBCatalog.SearchKind.movie, .tv], id: \.self) { Text($0.title).tag($0) }
                    }
                }
                menu(.genres) {
                    ForEach(DiscoverGenres.ids(for: current.kind), id: \.self) { id in
                        let selected = current.genres.contains(id)
                        Button {
                            update { if selected { $0.genres.remove(id) } else if $0.genres.count < 8 { $0.genres.insert(id) } }
                        } label: {
                            let name = L10n.text(DiscoverGenres.names[id] ?? (id == 10766 ? "Soap" : "War & Politics"))
                            if selected { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                }
                menu(.years) {
                    Picker(DiscoverFilterSection.years.title, selection: Binding(get: { "\(current.from)-\(current.to)" }, set: { value in
                        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                        update { $0.from = parts.first ?? ""; $0.to = parts.last ?? "" }
                    })) {
                        ForEach(yearRanges, id: \.key) { Text($0.title).tag($0.key) }
                    }
                }
                menu(.sort) {
                    Picker(DiscoverFilterSection.sort.title, selection: binding(\.sort)) {
                        ForEach(DiscoverSearchFilters.sortOptions(current.kind), id: \.0) { Text(L10n.text($0.1)).tag($0.0) }
                    }
                    Picker(L10n.text("Minimum Rating"), selection: binding(\.rating)) {
                        ForEach([0, 6, 7, 8, 9], id: \.self) { Text($0 == 0 ? L10n.text("Any") : "\($0)+").tag($0) }
                    }
                    Picker(L10n.text("Minimum Votes"), selection: binding(\.votes)) {
                        ForEach([0, 100, 500, 1000, 5000], id: \.self) { Text($0 == 0 ? L10n.text("Any") : "\($0)+").tag($0) }
                    }
                }
                menu(.platform) {
                    Picker(DiscoverFilterSection.platform.title, selection: binding(\.company)) {
                        Text(L10n.text("Any")).tag("")
                        ForEach(DiscoverSearchFilters.platforms(current.kind), id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                menu(.language) {
                    Picker(DiscoverFilterSection.language.title, selection: binding(\.originalLanguage)) {
                        Text(L10n.text("Any")).tag("")
                        ForEach(DiscoverSearchFilters.languages, id: \.self) { code in
                            Text(Locale(identifier: TMDBMatch.language).localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }
                }
                menu(.region) {
                    Picker(DiscoverFilterSection.region.title, selection: binding(\.region)) {
                        Text(L10n.text("Any")).tag("")
                        ForEach(DiscoverSearchFilters.regions, id: \.self) { code in
                            Text(Locale(identifier: TMDBMatch.language).localizedString(forRegionCode: code) ?? code).tag(code)
                        }
                    }
                }
                Button(DiscoverFilterSection.keywords.chipTitle(filter)) { keywordsShown = true }
                    .buttonStyle(DiscoverTVChipStyle(active: !current.keywords.isEmpty))
                    .accessibilityIdentifier("discover.filter.section.keywords")
                if filter != nil {
                    Button { filter = nil } label: { Label(L10n.text("Reset Filters"), systemImage: "xmark") }
                        .buttonStyle(DiscoverTVChipStyle(active: false))
                        .accessibilityIdentifier("discover.search.resetFilters")
                }
            }.padding(.horizontal, gutter).padding(.vertical, 16)
        }.scrollClipDisabled().focusSection()
    }

    private func menu(_ section: DiscoverFilterSection, @ViewBuilder content: () -> some View) -> some View {
        Menu { content() } label: { Text(section.chipTitle(filter)) }
            .menuStyle(.button)
            .buttonStyle(DiscoverTVChipStyle(active: filter != nil && section.chipTitle(filter) != section.chipTitle(nil)))
            .accessibilityIdentifier("discover.filter.section.\(section.rawValue)")
    }

    private func update(_ change: (inout TMDBCatalog.Filter) -> Void) {
        var value = current
        change(&value)
        filter = value
    }
    private func binding<Value>(_ path: WritableKeyPath<TMDBCatalog.Filter, Value>,
                                set: ((inout TMDBCatalog.Filter, Value) -> Void)? = nil) -> Binding<Value> {
        Binding(get: { current[keyPath: path] }, set: { value in update { if let set { set(&$0, value) } else { $0[keyPath: path] = value } } })
    }
    private var yearRanges: [(key: String, title: String)] {
        let year = Calendar.current.component(.year, from: Date())
        return [("-", L10n.text("Any"))]
            + stride(from: year, through: year - 4, by: -1).map { ("\($0)-\($0)", String($0)) }
            + stride(from: 2020, through: 1900, by: -10).map { ("\($0)-\($0 + 9)", L10n.text("%@s", String($0))) }
    }

    // MARK: Results

    @ViewBuilder private func section(_ group: DiscoverSearchGroup, kind: TMDBCatalog.SearchKind) -> some View {
        let grid = expanded == kind || (filter != nil && kind != .person)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 34) {
                Text(filter == nil || kind == .person ? kind.title : L10n.text("Filtered Results"))
                    .font(.system(size: 34, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                if kind != .person, filter == nil, group.items.count > 3 || group.hasMore {
                    Button { withAnimation { expanded = grid ? nil : kind } } label: {
                        Label(L10n.text(grid ? "Show Less" : "See All"), systemImage: grid ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 26)).foregroundStyle(.white.opacity(0.7))
                    }
                    .buttonStyle(DiscoverTVChipStyle(active: false))
                    .accessibilityIdentifier("discover.search.expand.\(kind.rawValue)")
                }
            }.padding(.horizontal, gutter)
            if kind == .person {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(group.people) { person in
                            RouteLink { DiscoverPersonView(id: person.id, name: person.name, profile: person.profile) } label: { portrait(person) }
                                .cardButton(.circle)
                                .accessibilityIdentifier("discover.search.person.\(person.id)")
                        }
                    }.padding(.horizontal, gutter).padding(.vertical, 24)
                }.scrollClipDisabled()
            } else if grid {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 3), alignment: .leading, spacing: 40) {
                    ForEach(group.items, id: \.key) { item in
                        card(item).onAppear {
                            if item.key == group.items.last?.key { Task { await model.more(kind, request: request) } }
                        }
                    }
                }.padding(.horizontal, gutter)
                if group.loadingMore { ProgressView().frame(maxWidth: .infinity) }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 40) {
                        ForEach(group.items, id: \.key) { item in card(item).frame(width: 590) }
                    }.padding(.horizontal, gutter).padding(.vertical, 24)
                }.scrollClipDisabled()
            }
        }.focusSection()
    }

    private func card(_ item: TMDBCatalog.Item) -> some View {
        RouteLink { DiscoverDetailView(item: item) } label: { DiscoverTVSearchCard(item: item) }
            .panelCardButton(cornerRadius: 24)
            .accessibilityIdentifier("discover.search.result.\(item.key)")
    }

    private func portrait(_ person: TMDBCatalog.SearchPerson) -> some View {
        VStack(spacing: 14) {
            PosterImage(url: person.profile, symbol: "person.fill").frame(width: 200, height: 200).posterClip(Circle())
            VStack(spacing: 4) {
                Text(person.name).font(.system(size: 28)).lineLimit(1)
                Text(L10n.text(person.department == "Acting" ? "Actor" : person.department ?? "People"))
                    .font(.system(size: 22)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }.frame(width: 220)
    }
}

/// A search result on the TV: the cover beside its title, kind and year, rating and the start of the overview.
private struct DiscoverTVSearchCard: View {
    let item: TMDBCatalog.Item
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            PosterImage(url: item.poster).frame(width: 150, height: 225).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                Text(item.name).font(.system(size: 29, weight: .bold)).lineLimit(1)
                Text([L10n.text(item.mediaType == .tv ? "Series" : "Movies"), item.year.map(String.init),
                      item.genreNames.isEmpty ? nil : item.genreNames.replacingOccurrences(of: " / ", with: " · ")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 23)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                if let rating = item.rating {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            ForEach(0..<5) { index in
                                Image(systemName: rating / 2 >= Double(index + 1) ? "star.fill" : rating / 2 > Double(index) ? "star.leadinghalf.filled" : "star")
                                    .font(.system(size: 20)).foregroundStyle(rating / 2 > Double(index) ? Color.yellow : .white.opacity(0.4))
                            }
                        }
                        Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 23)).foregroundStyle(.yellow)
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("TMDB \(rating.formatted(.number.precision(.fractionLength(1))))")
                }
                Text(item.overview).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).lineLimit(2).lineSpacing(3)
            }.padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(12).frame(height: 249)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1) }
    }
}
#endif

