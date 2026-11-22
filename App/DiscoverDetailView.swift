import SwiftUI
import TVCore
import AVKit

/// Catalog detail uses the same independent, full-bleed paint layer as the home hero.
/// Available actions use Yingxia's source search and system share sheet.
struct DiscoverDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var appColorScheme
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
    /// The latest season's air dates while it airs (#1186).
    @State private var airing: AirSchedule?
    @State private var airCalendarShown = false
    /// The title on the viewer's sources, searched while the page is on screen.
    @State private var sources: DiscoverSources?
    #if os(tvOS)
    @State private var tvScrolled = false
    @State private var tvOverviewShown = false
    #endif
    private var details: TMDBMatch.Details? { model.details }
    private var dark: Bool { model.paint?.isDark ?? true }
    private var seasons: [TMDBMatch.SeasonSummary] { details?.seasons.filter { $0.number > 0 } ?? [] }
    private var catalogSeason: Int? { seasonNumber ?? seasons.first?.number }

    var body: some View {
        page
        .modifier(DiscoverSearchPresentation(isPresented: $searchShown))
        .onAppear { onScreen = true; startSources() }
        .onDisappear { onScreen = false; stopSources() }
        .task(id: item.key) { await model.load(item) }
        .onChange(of: details?.id) { _, _ in
            if sources == nil { startSources() }
        }
        .onChange(of: store.subscription?.importedAt) { _, _ in startSources() }
        // A video playing over the page (the player covers it without the page going away) pauses the search for the
        // title's other sources until it closes: their plugins ran flat out under the video and warmed the phone (#1428).
        .onChange(of: store.playing == nil) { _, idle in if idle { startSources() } else { stopSources() } }
        .task(id: catalogSeason) { await loadSeason() }
        .task(id: details?.id) { await loadAiring() }
        #if DEBUG
        .task(id: details?.id) {
            // QA: -qaToggleFollow <seconds> follows or unfollows the series that long after its details load, for the toast.
            let delay = UserDefaults.standard.double(forKey: "qaToggleFollow")
            guard details != nil, delay > 0 else { return }
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { DiscoverFollowing.toggle(followItem, in: store) }
        }
        #endif
        .modifier(DiscoverAirCalendarPresentation(isPresented: $airCalendarShown, schedule: airing, show: followItem))
        .modifier(DiscoverToastHost(active: !airCalendarShown))
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
        #elseif os(iOS)
        // The movie player, full screen: SwiftUI's VideoPlayer in a sheet had no full screen, Fill or speed (#300).
        .fullScreenCover(isPresented: $trailerShown) {
            // Store handed in, as for every full-screen cover: the iPad app on a Mac leaves environment objects behind.
            if let trailer = details?.trailer { DiscoverMobileTrailerScreen(trailer: trailer, title: details?.name ?? item.name).environment(store) }
        }
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
                        discoverEpisodes
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
        #if os(macOS)
        .artUnderToolbar()
        #else
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
                if item.mediaType == .tv { DiscoverFollowButton(item: followItem) }
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

    /// The title's sources start searching when the page shows, with a subscription to search, and pause when it goes
    /// or a video plays over it.
    /// A page opened with only the title's id (a link) has no name to search for until its details are in.
    private func startSources() {
        guard onScreen, store.playing == nil else { return }
        guard store.subscription != nil else {
            stopSources()
            sources = nil
            return
        }
        let work = followItem
        guard !work.name.isEmpty else { return }
        let model = sources ?? DiscoverSources.of(work)
        if sources == nil { sources = model }
        model.start(store)
    }
    private func stopSources() {
        sources?.stop()
    }

    @ViewBuilder private var discoverEpisodes: some View {
        #if !os(tvOS)
        if let airing {
            DiscoverAirCalendarRow(schedule: airing) { DiscoverFollowing.present { airCalendarShown = true } }
        }
        #endif
        if let sources {
            DiscoverSourceEpisodes(sources: sources, item: followItem, appColorScheme: appColorScheme, selectedSeason: $seasonNumber,
                                   seasonControl: { number in seasons.isEmpty ? nil : AnyView(catalogSeasonMenu(number)) }) { number in
                if number == nil || number == catalogSeason {
                    catalogEpisodes(showsSeasonControl: number == nil)
                }
            }
        } else {
            catalogEpisodes()
        }
    }

    @ViewBuilder private func catalogSeasonMenu(_ current: Int?) -> some View {
        let title = seasons.first { $0.number == current }?.name ?? L10n.text("Seasons")
        #if os(macOS)
        DiscoverMacSeasonButton(title: title, seasons: seasons, current: current, appColorScheme: appColorScheme) { seasonNumber = $0 }
            .accessibilityIdentifier("discover.detail.season")
        #else
        Menu {
            ForEach(seasons, id: \.number) { value in
                Button { seasonNumber = value.number } label: {
                    if current == value.number { Label(value.name, systemImage: "checkmark") } else { Text(value.name) }
                }
            }
        } label: {
            #if os(tvOS)
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            #else
            EpisodeDropdownLabel(title: title).fixedSize()
            #endif
        }
        #if os(tvOS)
        .menuStyle(.button).buttonStyle(DiscoverTVChipStyle(active: false))
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityIdentifier("discover.detail.season")
        #endif
    }

    @ViewBuilder private func catalogEpisodes(showsSeasonControl: Bool = true) -> some View {
        if !seasons.isEmpty {
            #if os(tvOS)
            tvEpisodes(showsSeasonControl: showsSeasonControl)
            #else
            episodes(showsSeasonControl: showsSeasonControl)
            #endif
        }
    }

    private func episodes(showsSeasonControl: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsSeasonControl { catalogSeasonMenu(catalogSeason).padding(.horizontal, 20) }
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
    /// The page's details with what the list it came from had, for following the series.
    private var followItem: TMDBCatalog.Item {
        guard let details else { return item }
        return TMDBCatalog.Item(id: item.id, mediaType: item.mediaType, name: details.name.isEmpty ? item.name : details.name,
                                originalName: details.originalName, year: details.year ?? item.year,
                                overview: details.overview.isEmpty ? item.overview : details.overview,
                                poster: details.poster ?? item.poster, backdrop: details.backdrop ?? item.backdrop,
                                rating: details.rating ?? item.rating, genreIDs: item.genreIDs, date: details.date ?? item.date)
    }

    /// The air calendar, for a series still airing or followed: one more request for its latest season, kept 12 hours.
    private func loadAiring() async {
        guard let details, details.mediaType == .tv else { return }
        let current = ["Returning Series", "In Production", "Planned", "Pilot"].contains(details.status ?? "")
        guard current || store.followedShows.contains(details.id) else { airing = nil; return }
        let value = await AirSchedules.shared.schedule(details.id, details: details)
        guard !Task.isCancelled else { return }
        airing = value?.isAiring(today: DiscoverFollowing.today) == true ? value : nil
        #if DEBUG
        // QA: -qaAirCalendar 1 opens the air calendar once it loads.
        if airing != nil, UserDefaults.standard.bool(forKey: "qaAirCalendar") { DiscoverFollowing.present { airCalendarShown = true } }
        #endif
    }

    private func loadSeason() async {
        guard let number = catalogSeason else { return }
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

#if os(macOS)
private struct DiscoverMacSeasonButton: View {
    let title: String
    let seasons: [TMDBMatch.SeasonSummary]
    let current: Int?
    let appColorScheme: ColorScheme
    let choose: (Int) -> Void
    @State private var showingSeasons = false

    var body: some View {
        Button { showingSeasons.toggle() } label: {
            EpisodeDropdownLabel(title: title).fixedSize()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingSeasons) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(seasons, id: \.number) { season in
                        Button {
                            showingSeasons = false
                            choose(season.number)
                        } label: {
                            HStack(spacing: 8) {
                                Text(season.name)
                                Spacer(minLength: 12)
                                if season.number == current { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                            .padding(.horizontal, 10).frame(minHeight: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(season.number == current ? .isSelected : [])
                    }
                }
                .padding(8)
            }
            .frame(width: 210, height: CGFloat(min(seasons.count, 8)) * 34 + 12)
            .foregroundStyle(.primary)
            .preferredColorScheme(appColorScheme)
        }
    }
}
#endif

// MARK: The title on the viewer's sources

/// Discover's title page looks for its title on the viewer's sources with a search of its own: the Search tab's
/// results, history and tab stay as they were. The best match's episodes show on the page, the other matches under
/// Change Source. One per title for the session, so coming back to a title doesn't search again.
@MainActor @Observable final class DiscoverSources {
    let search = SearchModel()
    /// The results that are the title, best first (`SourceTitleMatch.ranked`).
    private(set) var matches: [SourceTitleMatch.Candidate] = []
    /// The one whose episodes show: the best match, or the one chosen under Change Source.
    private(set) var chosen: SourceTitleMatch.Candidate?
    /// Every source asked has answered.
    private(set) var finished = false
    @ObservationIgnored private let keyword: String
    @ObservationIgnored private let wanted: SourceTitleMatch.Wanted
    @ObservationIgnored private var found: [SourceTitleMatch.Candidate] = []
    /// The Watch Now row's order, by source key: the best match comes from the source highest in it.
    @ObservationIgnored private var order: [String: Int] = [:]
    @ObservationIgnored private var subscription: String?
    /// Answers still being matched off the main thread.
    @ObservationIgnored private var pending = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var grace: Task<Void, Never>?

    private static var kept: [String: DiscoverSources] = [:]
    private static var recent: [String] = []

    /// The title's sources; the last dozen titles opened keep theirs.
    static func of(_ item: TMDBCatalog.Item) -> DiscoverSources {
        recent.removeAll { $0 == item.key }
        recent.append(item.key)
        if let sources = kept[item.key] { return sources }
        let sources = DiscoverSources(item)
        kept[item.key] = sources
        if recent.count > 12 { kept[recent.removeFirst()] = nil }
        return sources
    }

    private init(_ item: TMDBCatalog.Item) {
        keyword = item.name
        wanted = SourceTitleMatch.Wanted(names: [item.name, item.originalName], year: item.year)
    }

    /// The page is on screen: the first time it searches; later it carries on a search the page left unfinished.
    func start(_ store: Store) {
        guard let config = store.subscription else { return }
        let identity = "\(config.origin)|\(config.importedAt.timeIntervalSince1970)"
        if subscription != identity {
            subscription = identity
            generation += 1; pending = 0
            grace?.cancel(); grace = nil
            found = []; matches = []; chosen = nil; finished = false
            search.reset()
        }
        order = Dictionary(store.recommendationSites(config).enumerated().map { ($1.key, $0) }) { first, _ in first }
        search.order = store.sourceOrder
        search.onResult = { [weak self] in self?.absorb($0) }
        if search.keyword.isEmpty {
            let hidden = store.hiddenSources
            search.search(keyword, config: config) { hidden.contains($0, origin: config.origin) }
            // Answered from the model's own cache, the results are in already.
            search.results.forEach(absorb)
        } else if search.suspended {
            search.resumeSuspended(config: config)
        }
        settle()
    }

    /// The page left: the search pauses (the sources that answered keep their results), and so does the wait to choose.
    func stop() {
        search.suspend()
        grace?.cancel(); grace = nil
    }

    func choose(_ candidate: SourceTitleMatch.Candidate) {
        grace?.cancel(); grace = nil
        chosen = candidate
    }

    private func absorb(_ result: SearchSourceResult) {
        guard let videos = result.page?.videos, !videos.isEmpty else { settle(); return }
        let site = result.site, wanted = wanted, generation = generation
        pending += 1
        Task {
            // Normalizing titles (traditional to simplified, widths) runs off the main thread, once per answer.
            let more = await Task.detached(priority: .userInitiated) { SourceTitleMatch.candidates(videos, site: site, wanted: wanted) }.value
            guard generation == self.generation else { return }
            pending -= 1
            if !more.isEmpty {
                found += more
                matches = SourceTitleMatch.ranked(found, sourceOrder: order)
            }
            settle()
        }
    }

    /// The best match shows once nothing can beat it (the title itself, from its year), once every source answered, or
    /// four seconds after the first match, so a slow source doesn't hold the page up. Then it stays: a better match
    /// that comes later goes under Change Source rather than swapping the episodes under the viewer.
    private func settle() {
        let done = pending == 0 && !search.suspended && search.completed >= search.total
        if finished != done { finished = done }
        guard chosen == nil, let best = matches.first else { return }
        if done || best.decisive { choose(best); return }
        guard grace == nil else { return }
        grace = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.chosen == nil, let best = self.matches.first else { return }
            self.choose(best)
        }
    }
}

/// One episode section uses source playback when available and catalog episodes while it searches.
private struct DiscoverSourceEpisodes<CatalogEpisodes: View>: View {
    @Environment(Store.self) private var store
    let sources: DiscoverSources
    let item: TMDBCatalog.Item
    let appColorScheme: ColorScheme
    @Binding var selectedSeason: Int?
    let seasonControl: (Int) -> AnyView?
    @ViewBuilder let catalogEpisodes: (Int?) -> CatalogEpisodes
    @State private var changing = false

    private var currentMatch: SourceTitleMatch.Candidate? {
        guard let selectedSeason else { return sources.chosen }
        if let chosen = sources.chosen, Self.season(of: chosen) == selectedSeason { return chosen }
        return sources.finished ? sources.matches.first { Self.season(of: $0) == selectedSeason } : nil
    }

    private static func season(of match: SourceTitleMatch.Candidate) -> Int {
        SeasonTitles.parse(match.video.name).season ?? 1
    }

    var body: some View {
        Group {
            if let chosen = currentMatch, let config = store.subscription {
                let number = Self.season(of: chosen)
                VideoDetailView(video: chosen.video, client: CatalogClient(site: chosen.site, origin: config.origin, jarURL: config.spiderURL),
                                embed: DetailEmbed(work: item, season: number, seasonControl: seasonControl(number),
                                                   catalogFallback: { AnyView(catalogEpisodes(number)) },
                                                   changeSource: { changing = true }, appColorScheme: appColorScheme))
                    .id(chosen.id)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        heading
                        if sources.finished {
                            Text(L10n.text(selectedSeason == nil ? "None of your sources has this title." : "None of your sources has this season."))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button {
                                if sources.matches.isEmpty { store.searchVideos(item.name) } else { changing = true }
                            } label: {
                                Label(L10n.text(sources.matches.isEmpty ? "Search Sources" : "Change Source"), systemImage: "magnifyingglass")
                            }
                            #if os(tvOS)
                            .glassPill()
                            #else
                            .controlButton()
                            #endif
                            .accessibilityIdentifier("discover.sources.search")
                        } else {
                            searchProgress.accessibilityIdentifier("discover.sources.searching")
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    catalogEpisodes(nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .fullScreenCover(isPresented: $changing) { picker.task { sources.start(store) } }
        #else
        .sheet(isPresented: $changing) {
            // Passed on by hand: an iPad app on a Mac lost the store in sheets (#1163).
            // The page draws in its art's look (white text, dark scheme) and the sheet inherits both, while its
            // background follows the app: on iOS 17 and 18 the sources were white on white (#1355, #1356).
            // `Color.primary`, not `.primary`: that is the inherited style's first level, the page's white.
            picker.foregroundStyle(Color.primary).environment(\.colorScheme, appColorScheme).preferredColorScheme(appColorScheme)
        }
        #endif
    }

    private var picker: some View {
        DiscoverSourcePicker(sources: sources, selected: currentMatch) { match in
            sources.choose(match)
            selectedSeason = Self.season(of: match)
        }
        .environment(store)
    }

    private var horizontalInset: CGFloat {
        #if os(tvOS)
        DiscoverLayout.gutter
        #else
        20
        #endif
    }

    private var heading: some View {
        Text(L10n.text("Episodes")).font(.title3.weight(.semibold))
    }

    @ViewBuilder private var searchProgress: some View {
        let search = sources.search
        if search.total > 0 {
            ProgressView(value: Double(search.completed), total: Double(search.total)) {
                Text(L10n.text("Searching for sources…")).font(.subheadline)
            } currentValueLabel: {
                Text(L10n.text("Searched %lld of %lld sources", search.completed, search.total))
                    .font(.footnote).monospacedDigit()
            }
            .progressViewStyle(.linear)
            if !search.activeSources.isEmpty {
                let names = search.activeSources.map { SourceLabel($0.site.name).text }.joined(separator: " · ")
                Text(L10n.text("Searching %@…", names))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        } else {
            HStack(spacing: 10) {
                ProgressView().appControlSize(.small)
                Text(L10n.text("Searching for sources…")).font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
    }
}

/// Change Source: the results that are the title, as they arrive, the one showing checked. As a book's source picker.
private struct DiscoverSourcePicker: View {
    let sources: DiscoverSources
    let selected: SourceTitleMatch.Candidate?
    let choose: (SourceTitleMatch.Candidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(L10n.text("Change Source")).font(.title2.bold())
                    Spacer()
                    Button(L10n.text("Done")) { dismiss() }.glassPill()
                }
                LazyVStack(spacing: 14) { options }
            }
            .padding(.horizontal, DiscoverLayout.gutter).padding(.vertical, 48)
        }
        .background { Color.black.ignoresSafeArea() }
        .preferredColorScheme(.dark)
        #else
        NavigationStack {
            List { options }
            .navigationTitle(L10n.text("Change Source"))
            #if os(iOS)
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .listStyle(.inset)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        .foregroundStyle(.primary)
        .tint(.accentColor)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        #else
        .frame(minWidth: 460, minHeight: 420)
        #endif
        #endif
    }

    @ViewBuilder private var options: some View {
        ForEach(sources.matches) { match in
            let checked = match.id == selected?.id
            Button { choose(match); dismiss() } label: {
                NovelRow(symbol: checked ? "checkmark.circle.fill" : "circle", title: SourceLabel(match.site.name).text,
                         detail: match.video.remarks.isEmpty ? match.video.year ?? "" : match.video.remarks, note: match.video.name)
            }
            #if os(tvOS)
            .glassRow()
            #else
            .buttonStyle(.plain)
            #endif
            .accessibilityAddTraits(checked ? .isSelected : [])
            .accessibilityIdentifier("discover.sources.option")
        }
        if !sources.finished {
            HStack(spacing: 10) {
                ProgressView().appControlSize(.small)
                Text(L10n.text("Searched %lld of %lld sources", sources.search.completed, sources.search.total))
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            }
        } else if sources.matches.isEmpty {
            Text(L10n.text("None of your sources has this title.")).foregroundStyle(.secondary)
        }
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

#if os(iOS)
/// A trailer in the movie player, so it fills the screen and has Fill, speed and Picture in Picture like any video.
/// The channel has no history context, so the trailer stays out of Continue Watching.
private struct DiscoverMobileTrailerScreen: View {
    @Environment(\.dismiss) private var dismiss
    let trailer: TMDBMatch.Trailer
    let title: String
    @State private var channel: Channel?
    @State private var failed = false
    var body: some View {
        if let channel {
            PlaybackView(channel: channel)
        } else {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                Group {
                    if failed { Text(L10n.text("Trailer Unavailable")) } else { ProgressView() }
                }.foregroundStyle(.white).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
                }.accessibilityLabel(L10n.text("Close")).padding(.horizontal, 12)
            }.preferredColorScheme(.dark)
                .task {
                    guard let stream = await DiscoverTrailerResolver.shared.resolve(trailer), !Task.isCancelled else { failed = true; return }
                    channel = Channel(name: title, url: stream.url, headers: stream.headers)
                }
        }
    }
}
#endif

struct DiscoverSearchPresentation: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openRoute) private var openRoute
    @Environment(Store.self) private var store
    func body(content: Content) -> some View {
        #if os(iOS)
        // Store handed in: the iPad app on a Mac presents a full-screen cover without the presenter's environment objects.
        content.fullScreenCover(isPresented: $isPresented) { DiscoverSearchView().environment(store) }
            // Search Sources on a detail page opened from here switches to the Search tab, which is behind this
            // full-screen sheet: close it so the source results show instead of the catalog search.
            .onChange(of: store.section) { if isPresented { isPresented = false } }
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
    /// Artwork that runs under the bars. On the Mac it is laid out beside the sidebar: the split view's detail reports
    /// the sidebar's width as a leading inset, so ignoring every edge stretched the art under the sidebar. On macOS 26
    /// a mirrored, blurred copy fills the space under the floating sidebar instead, so the page has no hard edge there.
    @ViewBuilder func discoverFullBleed() -> some View {
        #if os(macOS)
        if #available(macOS 26, *) {
            // The art itself from the window's top edge; only the sidebar's side gets the mirrored copy. Extending
            // first laid the art out below the toolbar and filled the toolbar with a blurred copy of it.
            ignoresSafeArea(edges: .top).backgroundExtensionEffect()
        } else {
            ignoresSafeArea(edges: .top)
        }
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
                discoverEpisodes
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
                        if item.mediaType == .tv {
                            let following = store.followedShows.contains(item.id)
                            tvIconButton(following ? "calendar.badge.checkmark" : "calendar.badge.plus", following ? "Unfollow Show" : "Follow Show",
                                         "discover.detail.follow") { DiscoverFollowing.toggle(followItem, in: store) }
                        }
                        if airing != nil {
                            tvIconButton("calendar", "Air Calendar", "discover.detail.airCalendar") { airCalendarShown = true }
                        }
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

    /// One of the round buttons under Search Sources. Up to five share the column's 368 pt (Trailer, Overview,
    /// Follow Show, Air Calendar, Search Catalog), so they keep little padding: with the usual 18 pt each one
    /// needs about 76 pt and five overflow the column, wider than Search Sources above them.
    private func tvIconButton(_ symbol: String, _ label: String, _ identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(maxWidth: .infinity) }
            .buttonStyle(DiscoverTVActionStyle(height: 75, font: 30, corner: 24, padding: 6))
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

    private func tvEpisodes(showsSeasonControl: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsSeasonControl { catalogSeasonMenu(catalogSeason).padding(.horizontal, DiscoverLayout.gutter) }
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
                .coverOverlay(alignment: .bottomTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 20, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule()).padding(12)
                    }
                }
            VStack(alignment: .leading, spacing: 4) { captions() }.padding(.horizontal, 4).cardCaption()
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
            }.cardCaption()
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

/// Whether a page has scrolled past its hero, which frosts the backdrop (Discover's title page, Bilibili's video page).
struct DiscoverTVScrolled: ViewModifier {
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
struct DiscoverTVActionStyle: ButtonStyle {
    let height: CGFloat
    let font: CGFloat
    var corner: CGFloat?
    var padding: CGFloat = 18
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
                .padding(.horizontal, style.padding).frame(height: style.height)
                .glassSurface(focused ? .regular.tint(.white.opacity(0.9)).interactive() : .regular.interactive(), in: shape)
                .scaleEffect(configuration.isPressed ? 0.97 : focused ? 1.06 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 16, y: 10)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
    }
}
#endif
