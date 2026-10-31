import ImageIO
import SwiftUI
import TVCore

/// A video page's TMDB details (`TMDBMatch`): what this device already knows shows at once; otherwise the lookup runs
/// while the page is open and its steps show, since a title nobody opened before takes some seconds.
@MainActor @Observable final class TMDBLookup {
    enum Phase: Equatable {
        case idle, looking, matched, ambiguous, notFound, failed, off
    }
    private(set) var phase: Phase = .idle
    /// The latest step worth showing: "thinking" between steps keeps the one before.
    private(set) var step: TMDBMatch.Step = .starting
    private(set) var details: TMDBMatch.Details?
    private(set) var answer: TMDBMatch.Answer?
    /// The viewer chose the work (or "none of these") for this video.
    private(set) var chosen = false
    private var key: String?
    private var request: TMDBMatch.Request?

    var numbering: TMDBMatch.Numbering { answer?.match?.numbering ?? answer?.numbering ?? .season }
    /// The agent's offset counts only for the work it matched, not one the viewer picked instead.
    var offset: Int { answer?.match.flatMap { $0.id == details?.id ? $0.offset : nil } ?? 0 }
    var candidates: [TMDBMatch.Candidate] { answer?.candidates ?? [] }

    /// Not for sources whose videos aren't on TMDB: Hongguo's short dramas, Bilibili's uploads, Douyin, music.
    static func applies(to site: Site) -> Bool {
        TMDBMatch.enabled && !TMDBMatch.skipsSource(key: site.key, api: site.api)
    }

    /// What this device knows for the video: the viewer's pick, else a recent answer. False when the Worker must be asked.
    func prepare(key: String) async -> Bool {
        guard self.key != key else { return phase != .idle }
        self.key = key
        if let choice = await TMDBMatchStore.shared.choice(for: key) {
            chosen = true
            switch choice {
            case .none: phase = .notFound
            case .work(let type, let id, let season): await load(type, id: id, season: season)
            }
            return true
        }
        if let answer = await TMDBMatchStore.shared.answer(for: key) {
            show(answer)
            // Details saved before "you may like" was added lack it; a movie fetches its details again just for that.
            if let match = answer.match, match.mediaType == .tv || answer.details?.recommendations == nil { refreshDetails(match, key: key) }
            return true
        }
        return false
    }

    /// A series gets new episodes, and so does the source: a kept answer shows at once, and the series' details are
    /// fetched again behind it, so the new episodes line up too. A movie's don't change; one is fetched again only when
    /// its saved details have no "you may like".
    private func refreshDetails(_ match: TMDBMatch.Match, key: String) {
        Task {
            guard let fresh = try? await TMDBMatch.details(match.mediaType, id: match.id, season: match.season),
                  self.key == key, !chosen, fresh != details else { return }
            let answer = await TMDBMatchStore.shared.update(fresh, for: key)
            withAnimation(.smooth(duration: 0.35)) {
                details = fresh
                if let answer { self.answer = answer }
            }
        }
    }

    /// Asks the Worker, unless `prepare` already had an answer. Cancelled with the page; the Worker finishes anyway and
    /// keeps the answer for the next visit.
    func run(key: String, request: TMDBMatch.Request) async {
        self.request = request
        guard !(await prepare(key: key)), phase == .idle || phase == .failed else { return }
        phase = .looking; step = .starting
        do {
            let answer = try await TMDBMatch.lookup(request) { step in
                Task { @MainActor [weak self] in
                    guard let self, step != .thinking || self.step == .starting else { return }
                    withAnimation(.smooth(duration: 0.25)) { self.step = step }
                }
            }
            await TMDBMatchStore.shared.save(answer, for: key)
            withAnimation(.smooth(duration: 0.35)) { show(answer) }
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { phase = .idle; return }
            // Not a failure of the page: it just shows the source's own details.
            Diagnostics.shared.record(.warning, "tmdb", "lookup failed: \(error.localizedDescription)")
            withAnimation { phase = .failed }
        }
    }

    func choose(_ type: TMDBMatch.MediaType, id: Int, season: Int?) async {
        guard let key else { return }
        let season = type == .tv ? season ?? answer?.season ?? 1 : nil
        chosen = true
        await TMDBMatchStore.shared.choose(.work(type, id, season: season), for: key)
        if let request { Task.detached { await TMDBMatch.link(request, to: type, id: id, season: season) } }
        await load(type, id: id, season: season)
    }

    /// A video the page won't look up (AI-generated, a short drama): the page stops waiting for TMDB.
    func skip() { phase = .off }

    /// "None of These": the page goes back to the source's own details, and stays so for this video.
    func reject() async {
        guard let key else { return }
        chosen = true
        await TMDBMatchStore.shared.choose(.none, for: key)
        withAnimation(.smooth(duration: 0.3)) { details = nil; phase = .notFound }
    }

    private func load(_ type: TMDBMatch.MediaType, id: Int, season: Int?) async {
        phase = .looking; step = .loading
        do {
            let value = try await TMDBMatch.details(type, id: id, season: season)
            withAnimation(.smooth(duration: 0.35)) { details = value; phase = .matched }
        } catch {
            guard !Task.isCancelled else { return }
            Diagnostics.shared.record(.warning, "tmdb", "details failed: \(error.localizedDescription)")
            phase = .failed
        }
    }

    private func show(_ answer: TMDBMatch.Answer) {
        self.answer = answer
        details = answer.details
        phase = switch answer.status {
        case .matched: answer.details == nil ? .failed : .matched
        case .ambiguous: answer.candidates.isEmpty ? .notFound : .ambiguous
        case .notFound: .notFound
        }
    }

    /// TMDB's episode for each of the line's episodes, when the season lines up.
    func episodes(_ items: [Episode]) -> [Episode.ID: TMDBMatch.EpisodeInfo] {
        guard let details, details.season != nil else { return [:] }
        let mapped = details.episodes(for: items.map(\.name), numbering: numbering, offset: offset)
        var result: [Episode.ID: TMDBMatch.EpisodeInfo] = [:]
        for (episode, info) in zip(items, mapped) { result[episode.id] = info }
        return result
    }
}

extension TMDBMatch.Step {
    var text: String {
        switch self {
        case .starting, .thinking: L10n.text("Reading the title…")
        case .waiting: L10n.text("Someone is looking up this title right now…")
        case .loading: L10n.text("Loading details…")
        case .searching(let query): L10n.text("Searching for “%@”…", query)
        case .checking(let name, let year):
            if let name, let year { L10n.text("Checking %@ (%lld)…", name, year) }
            else if let name { L10n.text("Checking %@…", name) }
            else { L10n.text("Checking a result…") }
        case .season(let number): L10n.text("Lining up episodes of season %lld…", number)
        }
    }
}

extension TMDBMatch.Details {
    /// "2024 · 剧情 / 古装 · 2 季 · ★ 8.1": what kind of work it is, in a line.
    var facts: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: " / ")) }
        if mediaType == .tv {
            let count = seasons.filter { $0.number > 0 }.count
            if count > 1 { parts.append(L10n.text("%lld Seasons", count)) }
        } else if let runtime, runtime > 0 {
            let minutes = Int(runtime.rounded())
            parts.append(minutes >= 60 ? L10n.text("%lldh %lldm", minutes / 60, minutes % 60) : L10n.text("%lld min", minutes))
        }
        if let rating, voteCount >= 10 { parts.append("★ " + String(format: "%.1f", rating)) }
        return parts.joined(separator: " · ")
    }

    /// The season's overview when it has one (a season's story), else the work's.
    var story: String { season.map(\.overview).flatMap { $0.isEmpty ? nil : $0 } ?? overview }
}

// MARK: Lookup state

/// While the lookup runs: what it is doing. When it found several works: which one it is. Otherwise nothing.
struct TMDBLookupStatus: View {
    let lookup: TMDBLookup
    var body: some View {
        switch lookup.phase {
        case .looking:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Finding this title on TMDB")).font(.subheadline.weight(.semibold))
                    Text(lookup.step.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .contentTransition(.opacity)
                        .id(lookup.step.text)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                TMDBBadge()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        case .ambiguous:
            TMDBChoices(lookup: lookup)
        default:
            EmptyView()
        }
    }
}

/// "Which one is it?": the works TMDB has under this name, to choose from.
struct TMDBChoices: View {
    let lookup: TMDBLookup
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Which one is it?")).font(.headline)
                    Text(L10n.text("TMDB has more than one title like this. Choose one to see its cast, artwork and episodes."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                TMDBBadge()
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: TMDBMetrics.spacing) {
                    ForEach(lookup.candidates) { candidate in
                        Button { Task { await lookup.choose(candidate.mediaType, id: candidate.id, season: nil) } } label: {
                            TMDBCandidateTile(candidate: candidate)
                        }
                        .tmdbCardButton()
                    }
                    Button { Task { await lookup.reject() } } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "xmark").font(.title3.weight(.semibold))
                            Text(L10n.text("None of These")).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: TMDBMetrics.candidate, height: TMDBMetrics.candidate * 1.5)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .panelCardButton(cornerRadius: 10)
                }
                .padding(.vertical, TMDBMetrics.focusRoom)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct TMDBCandidateTile: View {
    let name: String
    let year: Int?
    let mediaType: TMDBMatch.MediaType
    let poster: URL?
    init(candidate: TMDBMatch.Candidate) {
        self.init(name: candidate.name, year: candidate.year, mediaType: candidate.mediaType, poster: candidate.poster)
    }
    init(name: String, year: Int?, mediaType: TMDBMatch.MediaType, poster: URL?) {
        self.name = name; self.year = year; self.mediaType = mediaType; self.poster = poster
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(url: poster)
                .frame(width: TMDBMetrics.candidate, height: TMDBMetrics.candidate * 1.5)
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(name).font(.caption.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading).cardCaption()
            Text([year.map(String.init), L10n.text(mediaType == .tv ? "TV Series" : "Movie")].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).cardCaption()
        }
        .frame(width: TMDBMetrics.candidate, alignment: .leading)
        .foregroundStyle(.primary)
    }
}

/// TMDB's name for what the details come from, in its colors.
struct TMDBBadge: View {
    var body: some View {
        Text("TMDB")
            .font(.system(size: TMDBMetrics.badge, weight: .heavy, design: .rounded))
            .foregroundStyle(LinearGradient(colors: [Color(red: 0.56, green: 0.81, blue: 0.63), Color(red: 0.00, green: 0.71, blue: 0.89)],
                                            startPoint: .leading, endPoint: .trailing))
            .accessibilityLabel("TMDB")
    }
}

enum TMDBMetrics {
    #if os(tvOS)
    static let candidate: CGFloat = 200, castPhoto: CGFloat = 110, spacing: CGFloat = 28, badge: CGFloat = 20, focusRoom: CGFloat = 24
    static let episodeTile: CGFloat = 340
    #else
    static let candidate: CGFloat = 92, castPhoto: CGFloat = 64, spacing: CGFloat = 12, badge: CGFloat = 12, focusRoom: CGFloat = 0
    static let episodeTile: CGFloat = 200
    #endif
}

extension View {
    @ViewBuilder func tmdbCardButton() -> some View {
        #if os(tvOS)
        // The cards' focus plate: borderless only grew the focused tile a little, too little to see which one it was.
        cardButton()
        #else
        buttonStyle(.plain)
        #endif
    }
}

// MARK: Matched

/// Who's in it: round photos with the character under each name.
struct TMDBCastRow: View {
    let cast: [TMDBMatch.Person]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Cast")).font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TMDBMetrics.spacing) {
                    ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                        VStack(spacing: 6) {
                            PosterImage(url: person.profile, symbol: "person.fill")
                                .frame(width: TMDBMetrics.castPhoto, height: TMDBMetrics.castPhoto)
                                .clipShape(Circle())
                            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                            if let role = person.role { Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(width: TMDBMetrics.castPhoto + 16)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// TMDB's "you may like". A title here isn't from any source, so choosing one searches the viewer's sources for
/// it, as an index source's titles do.
struct TMDBRelatedRow: View {
    let titles: [TMDBMatch.Candidate]
    let search: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("You May Like")).font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TMDBMetrics.spacing) {
                    ForEach(titles, id: \.key) { title in
                        Button { search(title.name) } label: { TMDBCandidateTile(candidate: title) }
                            .tmdbCardButton()
                    }
                }
                .padding(.vertical, TMDBMetrics.focusRoom)
            }
            .scrollIndicators(.never)
            .scrollClipDisabled()
        }
    }
}

/// The facts that don't fit in a line: who made it, where, when, its original name.
struct TMDBInfoGrid: View {
    let details: TMDBMatch.Details
    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        if !details.originalName.isEmpty, details.originalName != details.name { rows.append((L10n.text("Original Title"), details.originalName)) }
        let makers = details.crew.map(\.name).joined(separator: "、")
        if !makers.isEmpty { rows.append((L10n.text(details.mediaType == .tv ? "Created By" : "Directed By"), makers)) }
        if !details.networks.isEmpty { rows.append((L10n.text(details.mediaType == .tv ? "Network" : "Studio"), details.networks.joined(separator: "、"))) }
        if let date = details.date { rows.append((L10n.text(details.mediaType == .tv ? "First Aired" : "Released"), date)) }
        let countries = details.countries.compactMap { Locale.current.localizedString(forRegionCode: $0) }
        if !countries.isEmpty { rows.append((L10n.text("Country or Region"), countries.joined(separator: "、"))) }
        return rows
    }
    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Information")).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                    ForEach(rows, id: \.0) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.0).font(.caption).foregroundStyle(.secondary)
                            Text(row.1).font(.subheadline).fixedSize(horizontal: false, vertical: true).selectable()
                        }
                    }
                }
            }
        }
    }
}

/// Where the details come from, TMDB's notice, and a way to correct the match.
struct TMDBFooter: View {
    let lookup: TMDBLookup
    let title: String
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TMDBBadge()
                Text(L10n.text("Details from TMDB")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.text("Not This Title?")) { choosing = true }
                    #if os(tvOS)
                    .controlButton()
                    #else
                    .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    #endif
            }
            Text(L10n.text("This product uses the TMDB API but is not endorsed or certified by TMDB."))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        #if DEBUG
        // `-qaTMDBPicker 1` opens the picker, for screenshots.
        .task { if UserDefaults.standard.bool(forKey: "qaTMDBPicker") { choosing = true } }
        #endif
        #if os(tvOS)
        // A page of posters: a sheet with a list was a small box in the middle of the screen.
        .fullScreenCover(isPresented: $choosing) { TMDBTVPicker(lookup: lookup, title: title) }
        #else
        .sheet(isPresented: $choosing) { TMDBPicker(lookup: lookup, title: title) }
        #endif
    }
}

/// Choose the work by hand: the other candidates, a search of TMDB, or none.
struct TMDBPicker: View {
    let lookup: TMDBLookup
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [TMDBMatch.SearchResult] = []
    @State private var searching = false

    init(lookup: TMDBLookup, title: String) {
        self.lookup = lookup
        _query = State(initialValue: title)
    }

    var body: some View {
        NavigationStack {
            List {
                if !lookup.candidates.isEmpty && results.isEmpty {
                    Section(L10n.text("Suggestions")) {
                        ForEach(lookup.candidates) { candidate in
                            row(name: candidate.name, year: candidate.year, type: candidate.mediaType, poster: candidate.poster) {
                                await lookup.choose(candidate.mediaType, id: candidate.id, season: nil)
                            }
                        }
                    }
                }
                if !results.isEmpty {
                    Section(L10n.text("TMDB")) {
                        ForEach(results) { result in
                            row(name: result.name, year: result.year, type: result.mediaType, poster: result.poster) {
                                await lookup.choose(result.mediaType, id: result.id, season: nil)
                            }
                        }
                    }
                }
                Section {
                    Button(L10n.text("None of These"), role: .destructive) { Task { await lookup.reject(); dismiss() } }
                }
            }
            #if !os(tvOS)
            .searchable(text: $query, prompt: L10n.text("Search TMDB"))
            #endif
            .onSubmit(of: .search) { Task { await search() } }
            .overlay { if searching { ProgressView() } }
            .navigationTitle(L10n.text("Not This Title?"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
            .task { if lookup.candidates.isEmpty { await search() } }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        searching = true
        defer { searching = false }
        results = (try? await TMDBMatch.search(text)) ?? []
    }

    private func row(name: String, year: Int?, type: TMDBMatch.MediaType, poster: URL?, choose: @escaping () async -> Void) -> some View {
        Button { Task { await choose(); dismiss() } } label: {
            HStack(spacing: 12) {
                PosterImage(url: poster).frame(width: 44, height: 66).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                    Text([year.map(String.init), L10n.text(type == .tv ? "TV Series" : "Movie")].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

#if os(tvOS)
/// Apple TV's "Not This Title?": TMDB's results for the title as posters (the lookup's suggestions first), searched again
/// as the viewer types, and None of These.
struct TMDBTVPicker: View {
    let lookup: TMDBLookup
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [TMDBMatch.SearchResult] = []
    @State private var searching = false

    init(lookup: TMDBLookup, title: String) {
        self.lookup = lookup
        _query = State(initialValue: title)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    Text(L10n.text("Not This Title?")).font(.title2.weight(.bold))
                    if !lookup.candidates.isEmpty {
                        shelf(L10n.text("Suggestions"), lookup.candidates.map { ($0.key, TMDBCandidateTile(candidate: $0), $0.mediaType, $0.id) })
                    }
                    let suggested = Set(lookup.candidates.map(\.key))
                    let others = results.filter { !suggested.contains($0.key) }
                    if !others.isEmpty {
                        shelf(L10n.text("TMDB"), others.map {
                            ($0.key, TMDBCandidateTile(name: $0.name, year: $0.year, mediaType: $0.mediaType, poster: $0.poster), $0.mediaType, $0.id)
                        })
                    } else if searching {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    HStack(spacing: 20) {
                        Button(L10n.text("None of These")) { Task { await lookup.reject(); dismiss() } }.controlButton()
                        Button(L10n.text("Cancel")) { dismiss() }.controlButton()
                    }
                    .tvFocusSection()
                }
                .pageContainer()
            }
            .catalogSearchable(text: $query, prompt: L10n.text("Search TMDB"))
            .screenBackdrop()
        }
        // Searches as the viewer types: the inline keyboard has no reliable submit.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    private func shelf(_ title: String, _ tiles: [(String, TMDBCandidateTile, TMDBMatch.MediaType, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: TMDBMetrics.candidate), spacing: TMDBMetrics.spacing, alignment: .top)],
                      alignment: .leading, spacing: TMDBMetrics.spacing) {
                ForEach(tiles, id: \.0) { tile in
                    Button { Task { await lookup.choose(tile.2, id: tile.3, season: nil); dismiss() } } label: { tile.1 }
                        .tmdbCardButton()
                }
            }
            .tvFocusSection()
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; return }
        searching = true
        defer { searching = false }
        results = (try? await TMDBMatch.search(text)) ?? []
    }
}
#endif

/// Mac and iPad, and Apple TV: TMDB's backdrop across the page, with the title (its logo when TMDB has one), the facts and
/// the page's actions over its lower edge, as in the TV app.
struct TMDBBanner<Actions: View>: View {
    let details: TMDBMatch.Details
    let backdrop: URL
    /// The words of the source's title outside TMDB's name, such as 第二季.
    let unmatched: String
    @ViewBuilder let actions: Actions
    @State private var logoAspect: CGFloat?
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.12)
                TMDBArtwork(url: backdrop, maxPixels: 2400).frame(width: width, height: proxy.size.height).clipped()
                LinearGradient(stops: [.init(color: .black.opacity(0.0), location: 0.35), .init(color: .black.opacity(0.82), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.6)],
                               startPoint: .leading, endPoint: .trailing)
                VStack(alignment: .leading, spacing: TMDBBannerMetrics.spacing) {
                    title(width: width)
                    let facts = [details.facts, unmatched].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !facts.isEmpty { Text(facts).font(TMDBBannerMetrics.factsFont).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
                    if !details.tagline.isEmpty {
                        Text(details.tagline).font(TMDBBannerMetrics.factsFont.italic()).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    actions.padding(.top, 6)
                }
                .padding(TMDBBannerMetrics.inset)
                // A narrow banner (an iPad's side-by-side window) gives the title its whole width.
                .frame(maxWidth: width < 600 ? width : min(width * 0.62, TMDBBannerMetrics.textWidth), alignment: .leading)
            }
        }
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: TMDBBannerMetrics.corner, style: .continuous))
    }

    @ViewBuilder private func title(width: CGFloat) -> some View {
        if let logo = details.logo {
            // The name until the logo is in, and instead of one that fails.
            let size = logoSize(width)
            TMDBArtwork(url: logo, maxPixels: 1000, fill: false, aspect: $logoAspect)
                .frame(width: logoAspect == nil ? nil : size.width, height: logoAspect == nil ? nil : size.height, alignment: .leading)
                .overlay(alignment: .leading) { if logoAspect == nil { nameText } }
                .shadow(color: .black.opacity(0.35), radius: 10)
                .accessibilityLabel(details.name)
        } else {
            nameText
        }
    }

    /// Wide logos get a width limit, tall ones a height limit.
    private func logoSize(_ width: CGFloat) -> CGSize {
        let aspect = max(logoAspect ?? 3, 0.5)
        let logoWidth = min(width * 0.36, TMDBBannerMetrics.logoHeight * aspect)
        return CGSize(width: logoWidth, height: logoWidth / aspect)
    }

    private var nameText: some View {
        Text(details.name).font(.system(size: TMDBBannerMetrics.title, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.4), radius: 8)
    }
}

enum TMDBBannerMetrics {
    #if os(tvOS)
    static let inset: CGFloat = 48, spacing: CGFloat = 14, title: CGFloat = 60, logoHeight: CGFloat = 150, corner: CGFloat = 24
    /// The facts line fits on one line at the TV's type size.
    static let textWidth: CGFloat = 1100
    static let factsFont = Font.title3
    #else
    static let inset: CGFloat = 24, spacing: CGFloat = 8, title: CGFloat = 34, logoHeight: CGFloat = 90, corner: CGFloat = 20
    static let textWidth: CGFloat = 760
    static let factsFont = Font.subheadline
    #endif
}

/// TMDB's banner made from the source's own cover, until TMDB's backdrop is in and for titles TMDB doesn't
/// have. The same shape and type as TMDBBanner, so the page doesn't change its layout when that one fades in: a blur of
/// the cover across it, the cover itself at the trailing edge, the title and actions over the lower leading corner.
struct PosterBanner<Actions: View>: View {
    let poster: URL?
    var headers: [String: String] = [:]
    let title: String
    let subtitle: String
    /// The cover's width over height once it loads; landscape covers are common (Bilibili, short dramas).
    @Binding var aspect: CGFloat?
    @ViewBuilder let actions: Actions
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size, inset = TMDBBannerMetrics.inset
            let ratio = min(max(aspect ?? 2.0 / 3.0, 0.6), 1.8)
            // A landscape cover may take at most ~40% of the banner, so the title keeps its room.
            let artWidth = min(max(size.height - inset * 2, 60) * ratio, size.width * 0.4)
            ZStack(alignment: .bottomLeading) {
                Color(white: 0.12)
                PosterImage(url: poster, headers: headers)
                    .frame(width: size.width, height: size.height).clipped()
                    .blur(radius: 40).scaleEffect(1.35)
                    .overlay(Color.black.opacity(0.35))
                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .clear, location: 0.6)],
                               startPoint: .leading, endPoint: .trailing)
                PosterImage(url: poster, headers: headers, aspect: $aspect)
                    .frame(width: artWidth, height: artWidth / ratio)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    .padding(inset)
                    .frame(width: size.width, height: size.height, alignment: .trailing)
                VStack(alignment: .leading, spacing: TMDBBannerMetrics.spacing) {
                    Text(title).font(.system(size: TMDBBannerMetrics.title, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.4), radius: 8)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(TMDBBannerMetrics.factsFont).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    }
                    actions.padding(.top, 6)
                }
                .padding(inset)
                .frame(maxWidth: min(max(size.width - artWidth - inset * 2, 240), TMDBBannerMetrics.textWidth), alignment: .leading)
            }
        }
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: TMDBBannerMetrics.corner, style: .continuous))
    }
}

/// An episode without a still: its number set large in italics on a soft plate (the name itself when it has no number),
/// so the tile keeps its shape and the row still reads at a glance.
struct EpisodeNumberArt: View {
    let name: String
    var body: some View {
        GeometryReader { proxy in
            let number = TMDBMatch.episodeNumber(name)
            let height = proxy.size.height
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(number.map { String(format: "%02d", $0) } ?? name)
                    .font(.system(size: height * (number == nil ? 0.3 : 0.62), weight: .heavy).italic())
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .lineLimit(1).minimumScaleFactor(0.3)
                    .padding(.horizontal, height * 0.12).padding(.bottom, height * (number == nil ? 0.12 : 0.02))
            }
        }
        .accessibilityHidden(true)
    }
}

/// An episode with TMDB's still: the picture, the source's name for it and TMDB's title. An episode without a still
/// keeps the tile's shape, with its number in the picture's place.
struct TMDBEpisodeTile: View {
    let name: String
    let info: TMDBMatch.EpisodeInfo?
    var current = false
    var loading = false
    /// nil fills the grid cell.
    var width: CGFloat? = TMDBMetrics.episodeTile
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear.aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let still = info?.still { PosterImage(url: still, symbol: "play.rectangle") } else { EpisodeNumberArt(name: name) }
                }
                .coverOverlay { if loading { ProgressView().padding(8).background(.black.opacity(0.45), in: Circle()) } }
                .coverOverlay(alignment: .bottomTrailing) {
                    if let runtime = info?.runtime, runtime > 0 {
                        Text(L10n.text("%lld min", Int(runtime))).font(.caption2.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: Capsule()).foregroundStyle(.white).padding(6)
                    }
                }
                .posterClip(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .coverOverlay { if current { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.accent, lineWidth: 2) } }
            Text(name).font(.subheadline.weight(current ? .bold : .semibold)).lineLimit(1)
                .foregroundStyle(current ? Brand.accent : .primary).cardCaption()
            // Always a second line, so tiles in a row stay one height.
            Text(info.map(\.name).flatMap { $0.isEmpty || $0 == name ? nil : $0 } ?? " ")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).cardCaption()
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Large TMDB artwork: backdrops at the banner's size (posters stop at 720 pixels) and logos, which are transparent.
struct TMDBArtwork: View {
    let url: URL
    var maxPixels = 1600
    /// Fills its frame (a backdrop) or fits in it (a logo).
    var fill = true
    var aspect: Binding<CGFloat?>? = nil
    @State private var image: CGImage?
    private static let cache: NSCache<NSURL, Box> = { let cache = NSCache<NSURL, Box>(); cache.countLimit = 24; return cache }()
    final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            if let cached = Self.cache.object(forKey: url as NSURL) { show(cached.image); return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary), !Task.isCancelled else { return }
            Self.cache.setObject(Box(decoded), forKey: url as NSURL)
            withAnimation(.easeOut(duration: 0.3)) { show(decoded) }
        }
    }

    private func show(_ decoded: CGImage) {
        image = decoded
        aspect?.wrappedValue = CGFloat(decoded.width) / CGFloat(max(decoded.height, 1))
    }
}
