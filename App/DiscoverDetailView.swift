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
    private var details: TMDBMatch.Details? { model.details }
    private var dark: Bool { model.paint?.isDark ?? true }
    private var seasons: [TMDBMatch.SeasonSummary] { details?.seasons.filter { $0.number > 0 } ?? [] }

    var body: some View {
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
                            if !details.genres.isEmpty { genreRail(details.genres) }
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
        #if os(iOS)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { searchShown = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel(L10n.text("Search Catalog"))
                    .accessibilityIdentifier("discover.detail.search")
                #if !os(tvOS)
                ShareLink(item: details?.link ?? URL(string: "https://www.themoviedb.org/\(item.mediaType.rawValue)/\(item.id)")!) {
                    Image(systemName: "square.and.arrow.up")
                }.accessibilityLabel(L10n.text("Share"))
                #endif
            }
        }
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
            }.presentationDetents([.medium, .large])
        }
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
            }.presentationDetents([.medium, .large])
        }
        .sheet(item: $still) { selection in
            NavigationStack {
                TMDBArtwork(url: selection.url, maxPixels: 2400, fill: false)
                    .background(.black).ignoresSafeArea(edges: .bottom)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { still = nil } } }
            }.preferredColorScheme(.dark)
        }
        .sheet(isPresented: $trailerShown) {
            if let trailer = details?.trailer { DiscoverTrailerScreen(trailer: trailer, title: item.name) }
        }
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
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 13) {
                        ForEach(season.episodes, id: \.number) { value in
                            Button { episode = DiscoverEpisode(value: value) } label: {
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
                }.scrollIndicators(.hidden)
            }
        }
    }

    private func people(_ people: [TMDBMatch.Person], title: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(title)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 7) {
                            PosterImage(url: person.profile, symbol: "person.fill").frame(width: 83, height: 83).clipShape(Circle())
                            VStack(spacing: 2) {
                                Text(person.name).font(.system(size: 13)).lineLimit(1)
                                if let role = person.role { Text(role).font(.system(size: 11)).lineLimit(1).opacity(0.55) }
                            }
                        }.frame(width: 99)
                    }
                }.padding(.horizontal, 20)
            }.scrollIndicators(.hidden)
        }
    }

    private func studioRail(_ studios: [TMDBMatch.Studio]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Studios & Networks"))
            ScrollView(.horizontal) {
                HStack(spacing: 13) {
                    ForEach(Array(studios.enumerated()), id: \.offset) { _, studio in
                        VStack(spacing: 10) {
                            AsyncImage(url: studio.logo) { phase in
                                if let image = phase.image { image.resizable().scaledToFit() } else { Image(systemName: "film.stack") }
                            }.frame(width: 100, height: 44)
                            Text(studio.name).font(.system(size: 11)).lineLimit(1)
                        }.padding(15).frame(width: 145).background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }.padding(.horizontal, 20)
            }.scrollIndicators(.hidden)
        }
    }

    private func genreRail(_ genres: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Genres"))
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(genres, id: \.self) { genre in
                        Text(genre).font(.system(size: 14, weight: .medium)).padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.primary.opacity(0.08), in: Capsule())
                    }
                }.padding(.horizontal, 20)
            }.scrollIndicators(.hidden)
        }
    }

    private func stillRail(_ images: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading(L10n.text("Stills"))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 13) {
                    ForEach(images, id: \.self) { url in
                        Button { still = DiscoverStill(url: url) } label: {
                            PosterImage(url: url).frame(width: 260, height: 146.25).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        }.buttonStyle(.plain).accessibilityIdentifier("discover.detail.still")
                    }
                }.padding(.horizontal, 20)
            }.scrollIndicators(.hidden)
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
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 13) {
                    ForEach(items, id: \.key) { candidate in
                        RouteLink { DiscoverDetailView(item: candidate.catalogItem) } label: { DiscoverTile(item: candidate.catalogItem).frame(width: 116) }.tmdbCardButton()
                    }
                }.padding(.horizontal, 20)
            }.scrollIndicators(.hidden)
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

private struct DiscoverSearchPresentation: ViewModifier {
    @Binding var isPresented: Bool
    func body(content: Content) -> some View {
        #if os(iOS)
        content.fullScreenCover(isPresented: $isPresented) { DiscoverSearchView() }
        #else
        content.sheet(isPresented: $isPresented) { DiscoverSearchView() }
        #endif
    }
}
