import SwiftUI
import TVCore
#if canImport(UIKit)
import UIKit
#endif

/// A person's credits share one page whether reached from a title, search or the home shelf.
struct DiscoverPersonView: View {
    let id: Int
    let name: String
    let profile: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var person: TMDBCatalog.PersonProfile?
    @State private var paint: DiscoverPaint?
    @State private var loading = true
    @State private var failed = false
    @State private var revision = 0
    #if os(tvOS)
    @FocusState private var tvChip: String?
    #endif
    @State private var kind = "all"
    @State private var contribution = "all"
    @State private var biographyShown = false
    private var color: Color {
        guard let paint else { return Color(red: 0.46, green: 0.41, blue: 0.43) }
        // Keep the poster's hue in a muted surface that stays legible behind credits.
        return Color(red: 0.385 + paint.red * 0.3, green: 0.385 + paint.green * 0.3, blue: 0.385 + paint.blue * 0.3)
    }
    private var works: [TMDBCatalog.PersonWork] {
        (person?.works ?? []).filter { (kind == "all" || $0.item.mediaType.rawValue == kind)
            && (contribution == "all" || $0.departments.contains(contribution)) }
    }
    private var wallPosters: [URL] {
        let credits = person?.works ?? []
        let narrative = credits.filter { work in
            !work.item.genreIDs.contains(where: { [99, 10763, 10764, 10767].contains($0) })
                && !work.roles.contains(where: { $0.lowercased().hasPrefix("self") || $0.lowercased().hasPrefix("herself") || $0.lowercased().hasPrefix("himself") })
        }.compactMap(\.item.poster)
        return Array((narrative.count >= 3 ? narrative : credits.compactMap(\.item.poster)).prefix(12))
    }
    #if os(macOS)
    /// The biography and timeline in a centred column on the Mac; full-width rows were mostly empty.
    private static let column: CGFloat = 680
    #endif
    @ViewBuilder private var page: some View {
        #if os(tvOS)
        tvPage
        #else
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0) {
                    header(width: geometry.size.width)
                    if loading { ProgressView().padding(30).frame(maxWidth: .infinity) }
                    if failed { Button(L10n.text("Try Again")) { revision += 1 }.padding(30) }
                    if !loading && !failed && works.isEmpty {
                        ContentUnavailableView(L10n.text("No Results"), systemImage: "film")
                    }
                    ForEach(Array(works.enumerated()), id: \.element.id) { index, work in
                        RouteLink { DiscoverDetailView(item: work.item) } label: {
                            timeline(work, marker: index == 0 || works[index - 1].date?.prefix(7) != work.date?.prefix(7), last: index == works.count - 1)
                        }.buttonStyle(.plain).accessibilityIdentifier("discover.person.work.\(work.id)")
                        #if os(macOS)
                        .frame(maxWidth: Self.column)
                        #endif
                    }
                }.padding(.bottom, 100)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: kind)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: contribution)
            }
            .scrollIndicators(.hidden)
            .background(color.discoverFullBleed())
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .bottomTrailing) { filters.padding(20) }
        }
        #endif
    }

    var body: some View {
        page
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .navigationTitle("")
        #if !os(macOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: revision) {
            loading = true; failed = false
            do {
                let loaded = try await TMDBCatalog.person(id)
                try Task.checkCancellation()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) { person = loaded; loading = false }
                // Use the central collage poster's palette so the wall and timeline share one colour.
                let posters = wallPosters
                if !posters.isEmpty { paint = await DiscoverPainter.shared.paint(posters[min(4, posters.count - 1)]) }
            } catch { if !Task.isCancelled { loading = false; failed = true } }
        }
        #if !os(tvOS)
        .sheet(isPresented: $biographyShown) {
            NavigationStack {
                ScrollView { Text(person?.biography ?? "").lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).padding(24).selectable() }
                    .navigationTitle(person?.name ?? name)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { biographyShown = false } } }
            }.presentationDetents([.medium, .large]).discoverSheetSize(width: 560, height: 480)
        }
        #endif
    }
    private func header(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: min(width * 0.88, 430))
            PosterImage(url: person?.profile ?? profile, symbol: "person.fill")
                .frame(width: 90, height: 135).clipShape(RoundedRectangle(cornerRadius: 14))
            Text(person?.name ?? name).font(.system(size: 22, weight: .medium)).padding(.top, 11)
            if let person { Text(L10n.text("%lld works", person.works.count)).font(.system(size: 14)).opacity(0.85).padding(.top, 7) }
            if let biography = person?.biography, !biography.isEmpty {
                Button { biographyShown = true } label: {
                    Text(biography).font(.system(size: 12)).lineLimit(3).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(.top, 16).accessibilityIdentifier("discover.person.biography")
            }
            if let handle = person?.instagram, let url = URL(string: "https://www.instagram.com/\(handle)/") {
                Link(destination: url) { Label(handle, systemImage: "camera").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading) }.padding(.top, 12)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 16)
        #if os(macOS)
        .frame(maxWidth: Self.column)
        #endif
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            DiscoverPosterWall(urls: wallPosters, color: color)
                .frame(height: min(width * 0.88, 430) + 270)
                .visualEffect { view, proxy in
                    view.offset(y: min(0, -proxy.frame(in: .scrollView).minY * 0.16))
                }
        }
    }
    private func timeline(_ work: TMDBCatalog.PersonWork, marker: Bool, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if marker {
                    Text(work.date.map { String($0.prefix(4)) } ?? "—").font(.system(size: 16, weight: .medium))
                    if let date = work.date { Text(month(date)).font(.system(size: 11)).opacity(0.75) }
                }
            }.frame(width: 42, alignment: .leading).padding(.top, 4)
            ZStack(alignment: .top) {
                Rectangle().fill(.white.opacity(0.35)).frame(width: 1).padding(.top, marker ? 14 : 0).opacity(last ? 0 : 1)
                if marker { Circle().fill(.white).frame(width: 8, height: 8).padding(.top, 8) }
            }.frame(width: 12)
            HStack(alignment: .top, spacing: 10) {
                PosterImage(url: work.item.poster).frame(width: 70, height: 105).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    Text(work.item.name).font(.system(size: 15, weight: .medium)).lineLimit(2)
                    Text([L10n.text(work.item.mediaType == .tv ? "Series" : "Movies"), work.item.genreNames].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).lineLimit(1).opacity(0.7)
                    Text(work.roles.joined(separator: " · ")).font(.system(size: 11)).lineLimit(2).opacity(0.85)
                    Spacer(minLength: 0)
                    if let rating = work.item.rating {
                        HStack(spacing: 4) { TMDBBadge(); Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 11)) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 105, alignment: .top)
            }.padding(10).background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 15))
                .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.09), lineWidth: 0.5) }
                .padding(.leading, 8).padding(.bottom, 10)
        }.padding(.horizontal, 18).fixedSize(horizontal: false, vertical: true)
    }
    private func month(_ value: String) -> String {
        guard let month = Int(value.dropFirst(5).prefix(2)),
              let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2000, month: month, day: 1)) else { return "" }
        return date.formatted(.dateTime.month(.abbreviated).locale(Locale(identifier: TMDBMatch.language)))
    }
    private var filters: some View {
        Menu {
            Picker(L10n.text("Content Type"), selection: $kind) {
                Text(L10n.text("All")).tag("all"); Text(L10n.text("Movies")).tag("movie"); Text(L10n.text("Series")).tag("tv")
            }
            Picker(L10n.text("Contribution"), selection: $contribution) {
                Text(L10n.text("All")).tag("all")
                ForEach(["Acting", "Directing", "Writing", "Production", "Editing"], id: \.self) { Text(L10n.text($0)).tag($0) }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 20)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle())
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        #endif
        .accessibilityLabel(L10n.text("Filter")).accessibilityIdentifier("discover.person.filter")
    }
}

#if os(tvOS)
/// The TV page, as Rex lays it out: the wall of covers over the person's colour, their photo, name and biography,
/// two filter chips and a grid of their works.
extension DiscoverPersonView {
    private static let tvMargin: CGFloat = 80

    var tvPage: some View {
        // The header has nothing to focus; reaching the chips scrolls it back into view, as Up does in Rex.
        ScrollViewReader { proxy in
            tvScroll.onChange(of: tvChip) { _, chip in
                guard chip != nil else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo("tvTop", anchor: .top) }
            }
        }
    }

    private var tvScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                tvHeader.id("tvTop")
                HStack(spacing: 20) {
                    tvMenu(L10n.text("Content Type"), $kind, [("all", L10n.text("All")), ("movie", L10n.text("Movies")), ("tv", L10n.text("Series"))],
                           identifier: "discover.person.kind")
                    tvMenu(L10n.text("Contribution"), $contribution,
                           [("all", L10n.text("All"))] + ["Acting", "Directing", "Writing", "Production", "Editing"].map { ($0, L10n.text($0)) },
                           identifier: "discover.person.contribution")
                }
                .padding(.horizontal, Self.tvMargin).padding(.top, 40).focusSection()
                if loading { ProgressView().frame(maxWidth: .infinity).padding(60) }
                if failed { Button(L10n.text("Try Again")) { revision += 1 }.padding(60) }
                if !loading && !failed && works.isEmpty {
                    ContentUnavailableView(L10n.text("No Results"), systemImage: "film")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 50, alignment: .top), count: 6), alignment: .leading, spacing: 60) {
                    ForEach(works, id: \.id) { work in
                        RouteLink { DiscoverDetailView(item: work.item) } label: { tvWork(work) }
                            .cardButton()
                            .accessibilityIdentifier("discover.person.work.\(work.id)")
                    }
                }
                .padding(.horizontal, Self.tvMargin).padding(.top, 70).padding(.bottom, 120).focusSection()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: kind)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: contribution)
            }
        }
        .scrollClipDisabled()
        .background(color.ignoresSafeArea())
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var tvHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 430)
            HStack(alignment: .top, spacing: 40) {
                PosterImage(url: person?.profile ?? profile, symbol: "person.fill")
                    .frame(width: 240, height: 240).clipShape(Circle())
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                VStack(alignment: .leading, spacing: 10) {
                    Text(person?.name ?? name).font(.system(size: 52, weight: .bold)).lineLimit(1)
                    if let person { Text(L10n.text("%lld works", person.works.count)).font(.system(size: 26)).opacity(0.85) }
                    if let biography = person?.biography, !biography.isEmpty {
                        Text(biography).font(.system(size: 26)).lineSpacing(4).lineLimit(2).opacity(0.72)
                            .frame(maxWidth: 1250, alignment: .leading).padding(.top, 26)
                    }
                }.padding(.top, 34)
            }
        }
        .padding(.horizontal, Self.tvMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) { DiscoverPosterWall(urls: wallPosters, color: color).frame(height: 640) }
    }

    private func tvMenu(_ title: String, _ selection: Binding<String>, _ options: [(String, String)], identifier: String) -> some View {
        let value = options.first { $0.0 == selection.wrappedValue }?.1 ?? ""
        return Menu {
            Picker(title, selection: selection) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }
        } label: {
            Text(TMDBMatch.language.hasPrefix("zh") ? "\(title)：\(value)" : "\(title): \(value)")
        }
        .menuStyle(.button)
        .buttonStyle(DiscoverTVChipStyle(active: selection.wrappedValue != "all"))
        .focused($tvChip, equals: identifier)
        .accessibilityIdentifier(identifier)
    }

    private func tvWork(_ work: TMDBCatalog.PersonWork) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Unclipped: the button's border shape rounds it, and a clip would cut off the focus rim.
            PosterImage(url: work.item.poster).frame(width: 250, height: 375)
                .padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 5) {
                Text(work.item.name).font(.system(size: 26, weight: .medium)).lineLimit(1)
                Text([L10n.text(work.item.mediaType == .tv ? "Series" : "Movies"), work.item.genreNames].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 21)).lineLimit(1).opacity(0.6)
                if !work.roles.isEmpty {
                    Text(work.roles.joined(separator: " · ")).font(.system(size: 21)).lineLimit(1).opacity(0.6)
                }
                if let rating = work.item.rating {
                    HStack(spacing: 6) { TMDBBadge(); Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 21)) }
                }
            }.cardCaption()
        }.frame(width: 250, alignment: .leading)
    }
}
#endif

/// Animate only the poster layer. The list does not recompute on animation frames.
private struct DiscoverPosterWall: View {
    let urls: [URL]
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    private var animates: Bool { visible && scenePhase == .active && !reduceMotion && !urls.isEmpty }
    var body: some View {
        DiscoverNativePosterWall(urls: urls, active: animates).clipped()
            .overlay { LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: color.opacity(0.35), location: 0.65), .init(color: color, location: 1)], startPoint: .top, endPoint: .bottom) }
            .accessibilityHidden(true).allowsHitTesting(false)
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }
}

private struct DiscoverNativePosterWall {
    let urls: [URL]
    let active: Bool
}

#if os(macOS)
extension DiscoverNativePosterWall: NSViewRepresentable {
    func makeNSView(context: Context) -> DiscoverPosterWallView { DiscoverPosterWallView() }
    func updateNSView(_ view: DiscoverPosterWallView, context: Context) { view.wall.update(urls: urls, active: active) }
    static func dismantleNSView(_ view: DiscoverPosterWallView, coordinator: ()) { view.wall.stop() }
}

private final class DiscoverPosterWallView: NSView {
    let wall = DiscoverPosterWallLayers()
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting, so AppKit leaves the layers alone; flipped to lay out top-down as on iPhone.
        wall.root.isGeometryFlipped = true
        layer = wall.root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); wall.layout(bounds.size) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
extension DiscoverNativePosterWall: UIViewRepresentable {
    func makeUIView(context: Context) -> DiscoverPosterWallView { DiscoverPosterWallView() }
    func updateUIView(_ view: DiscoverPosterWallView, context: Context) { view.wall.update(urls: urls, active: active) }
    static func dismantleUIView(_ view: DiscoverPosterWallView, coordinator: ()) { view.wall.stop() }
}

private final class DiscoverPosterWallView: UIView {
    let wall = DiscoverPosterWallLayers()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(wall.root)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wall.root.frame = bounds
        CATransaction.commit()
        wall.layout(bounds.size)
    }
}
#endif

/// Three tilted columns of posters drifting upwards, in layers so every platform shares them.
@MainActor private final class DiscoverPosterWallLayers {
    let root = CALayer()
    private let rotation = CALayer()
    private let canvas = CALayer()
    private static let rows = 8
    private var tiles: [CALayer] = []
    private var images: [URL: CGImage] = [:]
    private var urls: [URL] = []
    private var task: Task<Void, Never>?
    private var active = false
    private var cycle: CGFloat = 0
    init() {
        root.masksToBounds = true
        root.addSublayer(rotation); rotation.addSublayer(canvas)
    }
    /// Neighbours across differ by one poster, and down by three.
    private func url(at index: Int) -> URL? {
        guard !urls.isEmpty else { return nil }
        let column = index / Self.rows, row = index % Self.rows
        return urls[(column + (row % 4) * 3) % urls.count]
    }
    func update(urls: [URL], active: Bool) {
        self.active = active
        if self.urls != urls {
            self.urls = urls; task?.cancel(); images = [:]
            for tile in tiles { tile.contents = nil }
            task = Task { [weak self] in
                await withTaskGroup(of: (URL, CGImage?).self) { group in
                    for url in Set(urls) { group.addTask { (url, await PosterPalette.image(url)) } }
                    for await (url, image) in group {
                        guard !Task.isCancelled, let self, self.urls == urls, let image else { continue }
                        self.images[url] = image
                        for (index, tile) in self.tiles.enumerated() where self.url(at: index) == url { tile.contents = image }
                    }
                }
            }
        }
        animate()
    }
    func layout(_ size: CGSize) {
        guard size.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let width = min(size.width * 0.4263, 220), height = width * 1.5, step = height + 8
        // Tilted, the wall needs a little more than the width; a phone keeps its three columns.
        let columns = max(3, Int((size.width + size.height * 0.18) / (width + 8)) + 1)
        while tiles.count < columns * Self.rows {
            let tile = CALayer()
            tile.contentsGravity = .resizeAspectFill; tile.masksToBounds = true; tile.cornerRadius = 10
            tile.backgroundColor = CGColor(gray: 1, alpha: 0.06); canvas.addSublayer(tile); tiles.append(tile)
        }
        rotation.setAffineTransform(.identity)
        rotation.bounds = CGRect(x: 0, y: 0, width: CGFloat(columns) * (width + 8) - 8, height: size.height + step * 2)
        rotation.position = CGPoint(x: size.width / 2, y: size.height / 2 - step * 0.3)
        rotation.setAffineTransform(CGAffineTransform(rotationAngle: -.pi / 18))
        canvas.frame = rotation.bounds
        for (index, tile) in tiles.enumerated() {
            let column = index / Self.rows, row = index % Self.rows
            tile.isHidden = column >= columns
            tile.frame = CGRect(x: CGFloat(column) * (width + 8), y: CGFloat(row) * step + (column % 2 == 1 ? height * 0.3 : 0), width: width, height: height)
            if tile.contents == nil, let url = url(at: index) { tile.contents = images[url] }
        }
        if cycle != step * 4 { cycle = step * 4; canvas.removeAnimation(forKey: "drift") }
        animate()
    }
    private func animate() {
        guard active, !urls.isEmpty, cycle > 0 else { canvas.removeAnimation(forKey: "drift"); return }
        guard canvas.animation(forKey: "drift") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = 0; animation.toValue = -cycle
        animation.duration = 90; animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        canvas.add(animation, forKey: "drift")
    }
    func stop() { task?.cancel(); canvas.removeAnimation(forKey: "drift") }
}
