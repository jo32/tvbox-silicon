import SwiftUI
import TVCore
import AVKit

/// Catalog detail uses the same independent, full-bleed paint layer as the home hero.
/// Available actions use Yingxia's source search and system share sheet.
struct DiscoverDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let item: TMDBCatalog.Item
    @State private var model = DiscoverDetailModel()
    @State private var seasonNumber: Int?
    @State private var season: TMDBMatch.Season?
    @State private var loadingSeason = false
    @State private var seasonFailed = false
    @State private var onScreen = false
    @State private var overviewShown = false
    @State private var trailerShown = false
    @State private var searchShown = false
    @State private var still: DiscoverStill?
    @State private var episode: DiscoverEpisode?
    #if os(tvOS)
    @State private var tvScrolled = false
    @State private var tvOverviewShown = false
    #endif
    private var details: TMDBMatch.Details? { model.details }
    private var dark: Bool { model.paint?.isDark ?? true }
    private var seasons: [TMDBMatch.SeasonSummary] { details?.seasons.filter { $0.number > 0 } ?? [] }

    var body: some View {
        page
        .modifier(DiscoverSearchPresentation(isPresented: $searchShown))
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .task(id: item.key) { await model.load(item) }
        .onChange(of: details?.id) { _, _ in
            if seasonNumber == nil { seasonNumber = seasons.first?.number }
        }
        .task(id: seasonNumber) { await loadSeason() }
        .sheet(isPresented: $overviewShown) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(details?.name ?? item.name).font(.title2.bold())
                        if let tagline = details?.tagline, !tagline.isEmpty { Text(tagline).font(.headline).foregroundStyle(.secondary) }
                        Text(details?.overview ?? item.overview).font(.body).lineSpacing(5).selectable()
                    }.padding(24)
                }.navigationTitle(L10n.text("Overview"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { overviewShown = false } } }
            }.presentationDetents([.medium, .large]).discoverSheetSize(width: 560, height: 480)
        }
        #if os(tvOS)
        // Full-screen pages, as the TV presents things: the iPhone's sheets froze the TV app when they opened.
        .fullScreenCover(item: $episode) { selection in tvEpisodeScreen(selection.value) }
        .fullScreenCover(item: $still) { selection in
            ZStack { Color.black; TMDBArtwork(url: selection.url, maxPixels: 2400, fill: false) }.ignoresSafeArea()
        }
        #else
        .sheet(item: $episode) { selection in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        PosterImage(url: selection.value.still ?? details?.backdrop).aspectRatio(16.0 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                        Text(selection.value.name).font(.title2.bold())
                        Text(selection.value.overview).lineSpacing(4)
                        sourceButton
                    }.padding(20)
                }.navigationTitle(selection.value.name)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { episode = nil } } }
            }.presentationDetents([.medium, .large]).discoverSheetSize(width: 600, height: 640)
        }
        .sheet(item: $still) { selection in
            NavigationStack {
                TMDBArtwork(url: selection.url, maxPixels: 2400, fill: false)
                    .background(.black).ignoresSafeArea(edges: .bottom)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { still = nil } } }
            }.preferredColorScheme(.dark).discoverSheetSize(width: 1000, height: 640)
        }
        #endif
        #if os(tvOS)
        // The system player, full screen: the iPhone's sheet with SwiftUI's VideoPlayer froze the TV app.
        .fullScreenCover(isPresented: $trailerShown) {
            if let trailer = details?.trailer { DiscoverTVTrailerScreen(trailer: trailer) }
        }
        .fullScreenCover(isPresented: $tvOverviewShown) { tvOverviewScreen }
        #else
        .sheet(isPresented: $trailerShown) {
            if let trailer = details?.trailer { DiscoverTrailerScreen(trailer: trailer, title: item.name).discoverSheetSize(width: 960, height: 600) }
        }
        #endif
    }

    @ViewBuilder private var page: some View {
        #if os(tvOS)
        tvPage
        #else
        GeometryReader { geometry in
            let width = geometry.size.width
            let coverHeight = width < 600 ? width * 1.5 : min(760, width * 0.7)
            ZStack(alignment: .top) {
                DiscoverDetailBackground(model: model, width: width, height: coverHeight,
                                         active: onScreen && scenePhase == .active && !trailerShown && !searchShown && still == nil && !overviewShown)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        identity(width: width)
                        if model.failed {
                            Button(L10n.text("Try Again")) { Task { await model.load(item) } }.padding(.horizontal, 20)
                        }
                        if !seasons.isEmpty { episodes }
                        if let details {
                            if !details.cast.isEmpty { people(details.cast, title: L10n.text("Cast")) }
                            if details.crew.contains(where: { $0.profile != nil }) { people(details.crew, title: L10n.text("Crew")) }
                            if let studios = details.studios, !studios.isEmpty { studioRail(studios) }
                            if !details.genres.isEmpty { genreRail(details) }
                            if let images = details.stills, !images.isEmpty { stillRail(images) }
                            if details.trailer != nil { trailerCard }
                            facts(details)
                            if let recommendations = details.recommendations, !recommendations.isEmpty { related(recommendations) }
                            Link(destination: details.link) { Label(L10n.text("View on TMDB"), systemImage: "arrow.up.right.square") }
                                .font(.footnote).frame(maxWidth: .infinity).padding(.vertical, 15)
                        }
                    }.padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .modifier(DiscoverDetailScroll(model: model))
            }
        }
        .foregroundStyle(dark ? Color.white : Color.black)
        .environment(\.colorScheme, dark ? .dark : .light)
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
        #if !os(macOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(dark ? .dark : .light, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { searchShown = true } label: { Image(systemName: "text.magnifyingglass") }
                    .accessibilityLabel(L10n.text("Search Catalog"))
                    .accessibilityIdentifier("discover.detail.search")
                #if !os(tvOS)
                ShareLink(item: details?.link ?? URL(string: "https://www.themoviedb.org/\(item.mediaType.rawValue)/\(item.id)")!) {
                    Image(systemName: "square.and.arrow.up")
                }.accessibilityLabel(L10n.text("Share"))
                #endif
            }
        }
        #endif
    }

    private func identity(width: CGFloat) -> some View {
        VStack(spacing: 16) {
            Color.clear.frame(height: width < 600 ? width * 0.95 : width * 0.25)
            Group {
                if let logo = details?.logo {
                    TMDBArtwork(url: logo, maxPixels: 1000, fill: false)
                        .frame(width: min(width * 0.82, 440), height: 116)
                        .accessibilityLabel(details?.name ?? item.name)
                } else {
                    Text(details?.name ?? item.name).font(.system(size: 38, weight: .semibold))
                        .multilineTextAlignment(.center).lineLimit(3).minimumScaleFactor(0.6)
                        .frame(minHeight: 70)
                }
            }
            Text(metadata).font(.system(size: 13)).multilineTextAlignment(.center).opacity(0.88)
            HStack(spacing: 12) {
                sourceButton
                if let trailer = details?.trailer, trailer.site == "IMDb" {
                    Button { trailerShown = true } label: {
                        Image(systemName: "play.rectangle").font(.system(size: 21)).frame(width: 54, height: 54)
                            .glassSurface(.regular, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel(L10n.text("Trailer"))
                        .accessibilityIdentifier("discover.detail.playTrailer")
                }
            }
            Button { overviewShown = true } label: {
                Text(details?.overview ?? item.overview).font(.system(size: 12)).lineLimit(3)
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("discover.detail.overview")
            if let rating = details?.rating ?? item.rating {
                HStack(spacing: 5) {
                    TMDBBadge()
                    Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 12, design: .rounded))
                    if let votes = details?.voteCount { Text("(\(votes))").font(.system(size: 11, design: .rounded)).opacity(0.6) }
                }
            }
            if model.loading, details == nil { ProgressView().padding(10) }
        }
        .padding(.horizontal, 20).padding(.bottom, 0)
        #if os(macOS)
        .frame(maxWidth: 640)
        #endif
        .frame(maxWidth: .infinity)
    }

    private var metadata: String {
        var values = [details?.date ?? item.year.map(String.init) ?? ""]
        if let details {
            values += [countries(details), details.genres.prefix(2).joined(separator: " / ")]
            if let runtime = details.runtime, runtime > 0 { values.append("\(Int(runtime)) " + L10n.text("min")) }
        } else { values.append(item.genreNames) }
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var sourceButton: some View {
        Button {
            episode = nil
            if store.subscription == nil { store.section = .settings }
            else { store.searchVideos(item.name) }
        } label: {
            Label(L10n.text(store.subscription == nil ? "Add Subscription" : "Search Sources"), systemImage: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 54)
                .foregroundStyle(dark ? Color.black : Color.white)
                .background(dark ? Color.white : Color.black, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("discover.findSources")
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 14) {
            Menu {
                ForEach(seasons, id: \.number) { value in
                    Button { seasonNumber = value.number } label: {
                        if seasonNumber == value.number { Label(value.name, systemImage: "checkmark") } else { Text(value.name) }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(seasons.first { $0.number == seasonNumber }?.name ?? L10n.text("Seasons"))
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .medium))
                }.font(.system(size: 22, weight: .semibold)).padding(.horizontal, 20)
            }.buttonStyle(.plain).accessibilityIdentifier("discover.detail.season")
            if loadingSeason { ProgressView().frame(maxWidth: .infinity).frame(height: 120) }
            else if seasonFailed { Button(L10n.text("Try Again")) { Task { await loadSeason() } }.padding(.horizontal, 20) }
            else if let season {
                DiscoverRail(arrowCenter: 73) {
                    LazyHStack(alignment: .top, spacing: 13) {
                        ForEach(season.episodes, id: \.number) { value in
                            DiscoverButton { episode = DiscoverEpisode(value: value) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    PosterImage(url: value.still ?? details?.backdrop).frame(width: 260, height: 146.25)
                                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                        .overlay(alignment: .bottomTrailing) {
                                            if let runtime = value.runtime { Text("\(Int(runtime)) " + L10n.text("min")).font(.caption2).padding(5).background(.black.opacity(0.55), in: Capsule()).padding(8).foregroundStyle(.white) }
                                        }
                                    Text("\(value.number). \(value.name)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                    Text(value.overview).font(.system(size: 12)).lineLimit(2).opacity(0.65)
                                }.frame(width: 260, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityIdentifier("discover.detail.episode.\(value.number)")
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }

    private func people(_ people: [TMDBMatch.Person], title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(title)
            DiscoverRail(arrowCenter: 41.5) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                        if let id = person.id {
                            RouteLink { DiscoverPersonView(id: id, name: person.name, profile: person.profile) } label: { personCard(person) }
                                .buttonStyle(.plain).accessibilityIdentifier("discover.detail.person.\(id)")
                        } else { personCard(person) }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }

    private func personCard(_ person: TMDBMatch.Person) -> some View {
        VStack(spacing: 7) {
            PosterImage(url: person.profile, symbol: "person.fill").frame(width: 83, height: 83).clipShape(Circle())
            VStack(spacing: 2) {
                Text(person.name).font(.system(size: 13)).lineLimit(1)
                if let role = person.role { Text(role).font(.system(size: 11)).lineLimit(1).opacity(0.55) }
            }
        }.frame(width: 99)
    }

    private func studioRail(_ studios: [TMDBMatch.Studio]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Studios & Networks"))
            DiscoverRail {
                HStack(spacing: 13) {
                    ForEach(Array(studios.enumerated()), id: \.offset) { _, studio in
                        if let id = studio.id {
                            RouteLink { DiscoverBrowseView(title: studio.name, filter: .studio(id, type: studio.kind == "network" ? .tv : .movie), logo: studio.logo) } label: { studioCard(studio) }
                                .buttonStyle(.plain).accessibilityIdentifier("discover.detail.studio.\(id)")
                        } else { studioCard(studio) }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }

    private func studioCard(_ studio: TMDBMatch.Studio) -> some View {
        VStack(spacing: 10) {
            AsyncImage(url: studio.logo) { phase in
                if let image = phase.image { image.resizable().scaledToFit() } else { Image(systemName: "film.stack") }
            }.frame(width: 100, height: 44)
            Text(studio.name).font(.system(size: 11)).lineLimit(1)
        }.padding(15).frame(width: 145).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func genreRail(_ details: TMDBMatch.Details) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Genres"))
            DiscoverRail {
                HStack(spacing: 10) {
                    if let genres = details.genreItems, !genres.isEmpty {
                        ForEach(genres) { genre in
                            RouteLink { DiscoverBrowseView(title: genre.name, filter: .genre(genre.id, type: item.mediaType)) } label: { genreChip(genre.name) }
                                .buttonStyle(.plain).accessibilityIdentifier("discover.detail.genre.\(genre.id)")
                        }
                    } else {
                        ForEach(details.genres, id: \.self) { genreChip($0) }
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
    private func genreChip(_ name: String) -> some View {
        Text(name).font(.system(size: 14, weight: .medium)).padding(.horizontal, 20).padding(.vertical, 12)
            .background(.primary.opacity(0.08), in: Capsule())
    }

    private func stillRail(_ images: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Stills"))
            DiscoverRail(arrowCenter: 73) {
                LazyHStack(spacing: 13) {
                    ForEach(images, id: \.self) { url in
                        DiscoverButton { still = DiscoverStill(url: url) } label: {
                            PosterImage(url: url).frame(width: 260, height: 146.25).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }.buttonStyle(.plain).accessibilityIdentifier("discover.detail.still")
                    }
                }.padding(.horizontal, 20)
            }
        }
    }

    private var trailerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Trailer"))
            Button { trailerShown = true } label: {
                PosterImage(url: details?.backdrop ?? item.backdrop).frame(height: 210)
                    .overlay { Image(systemName: "play.fill").font(.system(size: 28)).frame(width: 64, height: 64).glassSurface(.regular, in: Circle()) }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }.buttonStyle(.plain).padding(.horizontal, 20).accessibilityIdentifier("discover.detail.trailer")
        }
    }

    private func facts(_ details: TMDBMatch.Details) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Information"))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 18) {
                fact(L10n.text("Original Title"), details.originalName)
                fact(L10n.text("Release Date"), details.date ?? "—")
                fact(L10n.text("Country / Region"), countries(details))
                fact(L10n.text("Status"), details.status.map { L10n.text($0) } ?? "—")
                if !details.crew.isEmpty { fact(L10n.text("Crew"), details.crew.map(\.name).joined(separator: " / ")) }
            }.padding(18).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 20)
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).opacity(0.55)
            Text(value).font(.system(size: 14)).lineLimit(3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func related(_ items: [TMDBMatch.Candidate]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("You May Like"))
            DiscoverRail(arrowCenter: 87) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(items, id: \.key) { candidate in
                        RouteLink { DiscoverDetailView(item: candidate.catalogItem) } label: { DiscoverTile(item: candidate.catalogItem).frame(width: 116) }.tmdbCardButton()
                    }
                }.padding(.horizontal, 20)
            }
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 19, weight: .semibold)).padding(.horizontal, 20)
    }
    private func countries(_ details: TMDBMatch.Details) -> String {
        let locale = Locale(identifier: TMDBMatch.language)
        return details.countries.map { locale.localizedString(forRegionCode: $0) ?? $0 }.joined(separator: " / ")
    }
    private func loadSeason() async {
        guard let number = seasonNumber else { return }
        loadingSeason = true; seasonFailed = false; season = nil
        defer { if !Task.isCancelled { loadingSeason = false } }
        do {
            let value = try await TMDBMatch.details(item.mediaType, id: item.id, season: number)
            if !Task.isCancelled { season = value.season }
        } catch { if !Task.isCancelled { seasonFailed = true } }
    }
}

@MainActor @Observable private final class DiscoverDetailModel {
    var details: TMDBMatch.Details?
    var paint: DiscoverPaint?
    var loading = true
    var failed = false
    var scrollY: CGFloat = 0
    func load(_ item: TMDBCatalog.Item) async {
        loading = true; failed = false
        defer { loading = false }
        do {
            let value = try await TMDBMatch.details(item.mediaType, id: item.id, season: nil)
            guard !Task.isCancelled else { return }
            details = value
            if let poster = value.heroPoster ?? item.poster { paint = await DiscoverPainter.shared.paint(poster) }
        } catch { if !Task.isCancelled { failed = true } }
    }
}

private struct DiscoverDetailBackground: View {
    let model: DiscoverDetailModel
    let width: CGFloat
    let height: CGFloat
    let active: Bool
    var body: some View {
        DiscoverBackdrop(paint: model.paint, width: width, heroHeight: height, scrollY: model.scrollY,
                         trailer: model.details?.trailer, playsTrailer: active && model.scrollY < height * 0.35)
    }
}
private struct DiscoverDetailScroll: ViewModifier {
    let model: DiscoverDetailModel
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, tvOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, value in model.scrollY = value }
        } else { content }
    }
}
private struct DiscoverStill: Identifiable { let url: URL; var id: URL { url } }
private struct DiscoverEpisode: Identifiable { let value: TMDBMatch.EpisodeInfo; var id: Int { value.number } }

private struct DiscoverTrailerScreen: View {
    @Environment(\.dismiss) private var dismiss
    let trailer: TMDBMatch.Trailer
    let title: String
    @State private var player = AVPlayer()
    @State private var failed = false
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VideoPlayer(player: player)
                if failed { Text(L10n.text("Trailer Unavailable")).foregroundStyle(.white) }
            }.navigationTitle(title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }.preferredColorScheme(.dark)
            .task {
                guard let stream = await DiscoverTrailerResolver.shared.resolve(trailer), !Task.isCancelled else { failed = true; return }
                let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset)); player.play()
            }
            .onDisappear { player.pause(); player.replaceCurrentItem(with: nil) }
    }
}

struct DiscoverSearchPresentation: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openRoute) private var openRoute
    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { DiscoverSearchView() }
        #else
        // A page of its own (Back returns), rather than the iPhone's full-screen sheet: on the Mac with the toolbar's
        // search field, on the TV laid out for the remote.
        content.onChange(of: isPresented) { _, shown in
            guard shown else { return }
            isPresented = false
            #if os(macOS)
            openRoute?(Route { AnyView(DiscoverMacSearchView()) })
            #else
            openRoute?(Route { AnyView(DiscoverTVSearchView()) })
            #endif
        }
        #endif
    }
}

extension View {
    /// Artwork that runs under the bars. On the Mac it stops at the sidebar: the split view's detail reports the
    /// sidebar's width as a leading inset, so ignoring every edge stretched the art under the sidebar.
    func discoverFullBleed() -> some View {
        #if os(macOS)
        ignoresSafeArea(edges: .top)
        #else
        ignoresSafeArea()
        #endif
    }

    /// A sheet's size on the Mac, where a sheet otherwise shrinks to its content's smallest size.
    func discoverSheetSize(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: width * 0.8, idealWidth: width, minHeight: height * 0.8, idealHeight: height)
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// The detail page on the TV, laid out like Rex: the backdrop fills the screen with the logo, actions and summary at
/// its foot; below it, rows sized for the remote. Scrolling frosts the backdrop.
extension DiscoverDetailView {
    private static let tvGutter: CGFloat = 96

    var tvPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 60) {
                tvHero
                if model.failed {
                    Button(L10n.text("Try Again")) { Task { await model.load(item) } }.padding(.horizontal, Self.tvGutter)
                }
                if !seasons.isEmpty { tvEpisodes }
                if let details {
                    if !details.cast.isEmpty { tvPeople(details.cast, title: L10n.text("Cast")) }
                    if details.crew.contains(where: { $0.profile != nil }) { tvPeople(details.crew, title: L10n.text("Crew")) }
                    if !details.genres.isEmpty { tvGenres(details) }
                    if let images = details.stills, !images.isEmpty { tvStills(images) }
                    if let recommendations = details.recommendations, !recommendations.isEmpty { tvRelated(recommendations) }
                }
            }.padding(.bottom, 90)
        }
        .scrollClipDisabled()
        // Only crossing the hero's edge matters. A per-frame offset re-rendered the page on every scroll step, and a
        // sheet's presentation fed back into it until the watchdog killed the app.
        .modifier(DiscoverTVScrolled(scrolled: $tvScrolled))
        .background { tvBackdrop }
        .ignoresSafeArea()
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var tvPlaysTrailer: Bool {
        onScreen && scenePhase == .active && !tvScrolled && !trailerShown && !searchShown && !tvOverviewShown && episode == nil && still == nil
    }

    private var tvBackdrop: some View {
        ZStack {
            Color.black
            if let url = details?.backdrop ?? item.backdrop { TMDBArtwork(url: url, maxPixels: 2400) }
            // The trailer plays behind the title, as in Rex, until the page scrolls or something covers it.
            if let trailer = details?.trailer, tvPlaysTrailer { DiscoverTrailer(trailer: trailer) }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.85), location: 1)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(.regularMaterial).opacity(tvScrolled ? 1 : 0)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: tvScrolled)
    }

    private var tvHero: some View {
        VStack(alignment: .leading, spacing: 34) {
            Group {
                if let logo = details?.logo {
                    TMDBArtwork(url: logo, maxPixels: 1400, fill: false)
                        .frame(width: 600, height: 240, alignment: .bottomLeading)
                        .accessibilityLabel(details?.name ?? item.name)
                } else {
                    Text(details?.name ?? item.name).font(.system(size: 76, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                        .frame(maxWidth: 1000, alignment: .bottomLeading)
                }
            }.shadow(color: .black.opacity(0.4), radius: 12)
            HStack(alignment: .top, spacing: 56) {
                VStack(alignment: .leading, spacing: 14) {
                    Button { tvFindSources() } label: {
                        Label(L10n.text(store.subscription == nil ? "Add Subscription" : "Search Sources"), systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DiscoverTVActionStyle(height: 82, font: 30))
                    .accessibilityIdentifier("discover.findSources")
                    HStack(spacing: 7) {
                        if details?.trailer != nil {
                            tvIconButton("play.rectangle", "Trailer", "discover.detail.playTrailer") { trailerShown = true }
                        }
                        tvIconButton("text.alignleft", "Overview", "discover.detail.overview") { tvOverviewShown = true }
                        tvIconButton("text.magnifyingglass", "Search Catalog", "discover.detail.search") { searchShown = true }
                    }
                }.frame(width: 368).focusSection()
                VStack(alignment: .leading, spacing: 14) {
                    Text(details?.overview ?? item.overview).font(.system(size: 28)).lineLimit(2).lineSpacing(4)
                    Text(metadata).font(.system(size: 26)).opacity(0.65).lineLimit(1)
                    if let rating = details?.rating ?? item.rating {
                        HStack(spacing: 10) {
                            TMDBBadge()
                            Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 26, design: .rounded))
                            if let votes = details?.voteCount { Text("(\(votes))").font(.system(size: 22, design: .rounded)).opacity(0.6) }
                        }
                    }
                    if model.loading, details == nil { ProgressView() }
                }.frame(maxWidth: 1150, alignment: .leading)
            }
        }
        .padding(.horizontal, Self.tvGutter)
        .frame(maxWidth: .infinity, minHeight: 950, alignment: .bottomLeading)
    }

    private func tvIconButton(_ symbol: String, _ label: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(maxWidth: .infinity) }
            .buttonStyle(DiscoverTVActionStyle(height: 75, font: 30, corner: 24))
            .accessibilityLabel(L10n.text(label))
            .accessibilityIdentifier(identifier)
    }

    /// The whole overview, over the dimmed backdrop: the hero shows only two lines of it.
    private var tvOverviewScreen: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let url = details?.backdrop ?? item.backdrop { TMDBArtwork(url: url, maxPixels: 2400).opacity(0.35) }
            LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 24) {
                Text(details?.name ?? item.name).font(.system(size: 56, weight: .bold)).lineLimit(2)
                if let tagline = details?.tagline, !tagline.isEmpty { Text(tagline).font(.system(size: 30, weight: .medium)).opacity(0.7) }
                Text(details?.overview ?? item.overview).font(.system(size: 30)).lineSpacing(6).lineLimit(14)
                Text(metadata).font(.system(size: 26)).opacity(0.6)
            }
            .frame(maxWidth: 1300, alignment: .leading)
            .padding(Self.tvGutter)
            // Something must hold focus for Menu to close the page.
            .focusable()
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
    }

    private func tvFindSources() {
        episode = nil
        if store.subscription == nil { store.section = .settings } else { store.searchVideos(item.name) }
    }

    func tvEpisodeScreen(_ value: TMDBMatch.EpisodeInfo) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            PosterImage(url: value.still ?? details?.backdrop).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.92), location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 24) {
                Text("\(value.number). \(value.name)").font(.system(size: 56, weight: .bold)).lineLimit(2)
                if !value.overview.isEmpty {
                    Text(value.overview).font(.system(size: 28)).lineSpacing(4).lineLimit(4).opacity(0.8)
                        .frame(maxWidth: 1300, alignment: .leading)
                }
                Button { tvFindSources() } label: {
                    Label(L10n.text(store.subscription == nil ? "Add Subscription" : "Search Sources"), systemImage: "magnifyingglass")
                        .frame(width: 380)
                }
                .buttonStyle(DiscoverTVActionStyle(height: 86, font: 30))
                .accessibilityIdentifier("discover.episode.findSources")
            }.padding(Self.tvGutter)
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
    }

    private func tvRow(_ title: String?, spacing: CGFloat = 40, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.system(size: 34, weight: .medium)).opacity(0.6).padding(.horizontal, DiscoverLayout.gutter) }
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: spacing) { content() }
                    .padding(.horizontal, DiscoverLayout.gutter).padding(.vertical, 24)
            }.scrollClipDisabled()
        }.focusSection()
    }

    private var tvEpisodes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                ForEach(seasons, id: \.number) { value in
                    Button { seasonNumber = value.number } label: {
                        if seasonNumber == value.number { Label(value.name, systemImage: "checkmark") } else { Text(value.name) }
                    }
                }
            } label: {
                Label(seasons.first { $0.number == seasonNumber }?.name ?? L10n.text("Seasons"), systemImage: "chevron.down")
            }
            .menuStyle(.button).buttonStyle(DiscoverTVChipStyle(active: false))
            .padding(.horizontal, DiscoverLayout.gutter)
            .accessibilityIdentifier("discover.detail.season")
            if loadingSeason { ProgressView().frame(maxWidth: .infinity).frame(height: 300) }
            else if seasonFailed { Button(L10n.text("Try Again")) { Task { await loadSeason() } }.padding(.horizontal, DiscoverLayout.gutter) }
            else if let season {
                tvRow(nil) {
                    ForEach(season.episodes, id: \.number) { value in
                        Button { episode = DiscoverEpisode(value: value) } label: {
                            tvLandscape(value.still ?? details?.backdrop, width: 420,
                                        badge: value.runtime.map { "\(Int($0)) " + L10n.text("min") }) {
                                Text("\(value.number). \(value.name)").font(.system(size: 26, weight: .semibold)).lineLimit(1)
                                Text(value.overview).font(.system(size: 22)).lineLimit(2).opacity(0.6)
                            }
                        }
                        .cardButton(.roundedRectangle(radius: 16))
                        .accessibilityIdentifier("discover.detail.episode.\(value.number)")
                    }
                }
            }
        }
    }

    /// A landscape image over left-aligned captions; only the image lifts with focus.
    private func tvLandscape(_ url: URL?, width: CGFloat, badge: String? = nil, @ViewBuilder captions: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PosterImage(url: url).frame(width: width, height: width * 9 / 16)
                .posterClip(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 20, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule()).padding(12)
                    }
                }
            VStack(alignment: .leading, spacing: 4) { captions() }.padding(.horizontal, 4)
        }.frame(width: width, alignment: .leading)
    }

    private func tvPeople(_ people: [TMDBMatch.Person], title: String) -> some View {
        tvRow(title, spacing: 36) {
            ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                if let id = person.id {
                    RouteLink { DiscoverPersonView(id: id, name: person.name, profile: person.profile) } label: { tvPerson(person) }
                        .cardButton(.circle)
                        .accessibilityIdentifier("discover.detail.person.\(id)")
                } else { tvPerson(person) }
            }
        }
    }

    private func tvPerson(_ person: TMDBMatch.Person) -> some View {
        VStack(spacing: 12) {
            PosterImage(url: person.profile, symbol: "person.fill").frame(width: 190, height: 190).posterClip(Circle())
            VStack(spacing: 4) {
                Text(person.name).font(.system(size: 26)).lineLimit(1)
                if let role = person.role { Text(role).font(.system(size: 22)).lineLimit(1).opacity(0.55) }
            }
        }.frame(width: 210)
    }

    private func tvGenres(_ details: TMDBMatch.Details) -> some View {
        tvRow(L10n.text("Genres"), spacing: 20) {
            if let genres = details.genreItems, !genres.isEmpty {
                ForEach(genres) { genre in
                    RouteLink { DiscoverBrowseView(title: genre.name, filter: .genre(genre.id, type: item.mediaType)) } label: { Text(genre.name) }
                        .buttonStyle(DiscoverTVChipStyle(active: false))
                        .accessibilityIdentifier("discover.detail.genre.\(genre.id)")
                }
            } else {
                ForEach(details.genres, id: \.self) { name in
                    Text(name).font(.system(size: 26, weight: .medium)).padding(.horizontal, 30).frame(height: 62)
                        .background(.white.opacity(0.14), in: Capsule())
                }
            }
        }
    }

    private func tvStills(_ images: [URL]) -> some View {
        tvRow(L10n.text("Stills")) {
            ForEach(images, id: \.self) { url in
                Button { still = DiscoverStill(url: url) } label: {
                    PosterImage(url: url).frame(width: 560, height: 315).posterClip(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .cardButton(.roundedRectangle(radius: 16))
                .accessibilityIdentifier("discover.detail.still")
            }
        }
    }

    private func tvRelated(_ items: [TMDBMatch.Candidate]) -> some View {
        tvRow(L10n.text("You May Like")) {
            ForEach(items, id: \.key) { candidate in
                let value = candidate.catalogItem
                RouteLink { DiscoverDetailView(item: value) } label: {
                    tvLandscape(value.backdrop ?? value.poster, width: 380) {
                        Text(value.name).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 10) {
                            if let rating = value.rating {
                                Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                    .labelStyle(DiscoverTVStarLabel())
                            }
                            if let year = value.year { Text(String(year)).opacity(0.6) }
                        }.font(.system(size: 22))
                        Text(value.overview).font(.system(size: 22)).lineLimit(2).opacity(0.6)
                    }
                }
                .cardButton(.roundedRectangle(radius: 16))
                .accessibilityIdentifier("discover.detail.related.\(value.key)")
            }
        }
    }
}

private struct DiscoverTVScrolled: ViewModifier {
    @Binding var scrolled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(tvOS 18, *) {
            content.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 120 } action: { _, value in scrolled = value }
        } else { content }
    }
}

/// A trailer on the TV in the system player; Menu returns to the page.
private struct DiscoverTVTrailerScreen: View {
    let trailer: TMDBMatch.Trailer
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.black
            DiscoverTVTrailerPlayer(trailer: trailer, failed: $failed)
            if failed { Text(L10n.text("Trailer Unavailable")).font(.system(size: 32)).foregroundStyle(.white) }
        }.ignoresSafeArea()
    }
}

private struct DiscoverTVTrailerPlayer: UIViewControllerRepresentable {
    let trailer: TMDBMatch.Trailer
    @Binding var failed: Bool
    final class Coordinator { var task: Task<Void, Never>? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let player = AVPlayer()
        controller.player = player
        let failed = $failed
        context.coordinator.task = Task { @MainActor in
            guard let stream = await DiscoverTrailerResolver.shared.resolve(trailer) else { failed.wrappedValue = true; return }
            guard !Task.isCancelled else { return }
            let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": stream.headers])
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            player.play()
        }
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.task?.cancel()
        controller.player?.pause()
        controller.player?.replaceCurrentItem(with: nil)
    }
}

/// A yellow star beside the rating, as on Rex's cards.
private struct DiscoverTVStarLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.foregroundStyle(.yellow); configuration.title }
    }
}

/// The detail page's actions: Liquid Glass plates that turn white under focus.
private struct DiscoverTVActionStyle: ButtonStyle {
    let height: CGFloat
    let font: CGFloat
    var corner: CGFloat?
    func makeBody(configuration: Configuration) -> some View { Action(configuration: configuration, style: self) }
    private struct Action: View {
        let configuration: ButtonStyleConfiguration
        let style: DiscoverTVActionStyle
        @Environment(\.isFocused) private var focused
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.corner ?? style.height / 2, style: .continuous)
            configuration.label
                .font(.system(size: style.font, weight: .medium)).lineLimit(1)
                .foregroundStyle(focused ? Color.black : Color.white)
                .padding(.horizontal, 18).frame(height: style.height)
                .glassSurface(focused ? .regular.tint(.white.opacity(0.9)).interactive() : .regular.interactive(), in: shape)
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.06 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 16, y: 10)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif
