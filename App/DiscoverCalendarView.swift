import SwiftUI
import TVCore

#if !os(tvOS)
/// Discover's Airing Today row and the week page it opens (TMDBCalendar): anime and series by day, Monday to Sunday,
/// as TV-guide cards (time, poster, title, episode). A card with a TMDB work opens its detail page; an anime TMDB
/// doesn't know opens its Bangumi page.
struct DiscoverCalendarView: View {
    @State private var weeks: [String: TMDBCalendar.Week]
    @State private var failed = Set<String>()
    @State private var kind: TMDBCalendar.Kind
    @State private var region = TMDBCalendar.Region.preferred
    /// The day picked, by date; today until the viewer picks another.
    @State private var picked: [String: String] = [:]

    init(initial: [TMDBCalendar.Kind: TMDBCalendar.Week] = [:], kind: TMDBCalendar.Kind = .anime) {
        var weeks: [String: TMDBCalendar.Week] = [:]
        if let anime = initial[.anime] { weeks[Self.key(.anime, .preferred)] = anime }
        if let series = initial[.tv] { weeks[Self.key(.tv, .preferred)] = series }
        _weeks = State(initialValue: weeks)
        _kind = State(initialValue: kind)
    }

    private static func key(_ kind: TMDBCalendar.Kind, _ region: TMDBCalendar.Region) -> String { kind == .anime ? "anime" : "tv|\(region.rawValue)" }
    private var key: String { Self.key(kind, region) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(L10n.text("Airing Schedule"), selection: $kind) {
                    Text(L10n.text("Anime")).tag(TMDBCalendar.Kind.anime)
                    Text(L10n.text("TV Series")).tag(TMDBCalendar.Kind.tv)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 260)
                .accessibilityIdentifier("calendar.kind")
                if kind == .tv {
                    DiscoverCalendarChips(values: TMDBCalendar.Region.allCases, selection: $region, title: \.title)
                }
                if let week = weeks[key] {
                    let date = picked[key] ?? week.today()?.date ?? week.days.first?.date
                    DiscoverCalendarDays(week: week, selection: Binding(get: { date }, set: { picked[key] = $0 }))
                    if week.stale {
                        Label(L10n.text("The schedule sources can't be reached right now, so this is an older copy."), systemImage: "clock.arrow.circlepath")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let day = week.days.first(where: { $0.date == date }), !day.items.isEmpty {
                        let today = day.date == week.today()?.date
                        let next = today ? DiscoverAiring.next(day.items) : nil
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 420), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(day.items) { item in
                                DiscoverAiringCard(item: item, state: today ? DiscoverAiring.state(item, next: next) : .later)
                                    .accessibilityIdentifier("calendar.item.\(item.id)")
                            }
                        }
                    } else {
                        EmptyResults(symbol: "calendar", title: L10n.text("Nothing Airing"))
                    }
                    DiscoverCalendarCredits(week: week)
                } else if failed.contains(key) {
                    EmptyResults(symbol: "calendar.badge.exclamationmark", title: L10n.text("Couldn't load the airing schedule."),
                                 message: L10n.text("Please try again later."), action: L10n.text("Try Again")) { Task { await load() } }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 80)
                }
            }
            .padding(DiscoverLayout.gutter)
        }
        .navigationTitle(L10n.text("Airing Schedule"))
        .task(id: key) { if weeks[key] == nil { await load() } }
    }

    private func load() async {
        let (key, kind, region) = (key, kind, region)
        failed.remove(key)
        do { weeks[key] = try await TMDBCalendar.week(kind, region: region) } catch {
            guard !(error is CancellationError) else { return }
            Diagnostics.shared.record(.warning, "calendar", "calendar=\(key) failed=\(String(reflecting: error))")
            failed.insert(key)
        }
    }
}

/// Discover's row: today's anime or series, from the next one to air, and the week page behind its heading.
struct DiscoverAiringToday: View {
    let weeks: [TMDBCalendar.Kind: TMDBCalendar.Week]
    @State private var kind = TMDBCalendar.Kind.anime
    var body: some View {
        let kinds = TMDBCalendar.Kind.allCases.filter { !(weeks[$0]?.today()?.items.isEmpty ?? true) }
        let shown = kinds.contains(kind) ? kind : kinds.first
        if let shown, let items = weeks[shown]?.today()?.items {
            let next = DiscoverAiring.next(items)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(L10n.text("Airing Today")).font(.system(size: DiscoverLayout.heading, weight: .semibold))
                    if kinds.count > 1 {
                        DiscoverCalendarChips(values: kinds, selection: Binding(get: { shown }, set: { kind = $0 }), title: \.title, compact: true)
                    }
                    Spacer()
                    RouteLink { DiscoverCalendarView(initial: weeks, kind: shown) } label: {
                        HStack(spacing: 3) {
                            Text(L10n.text("Full Schedule"))
                            Image(systemName: "chevron.forward").font(.system(size: 11, weight: .semibold))
                        }.font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("discover.more.calendar")
                }
                .padding(.horizontal, DiscoverLayout.gutter)
                DiscoverRail(arrowCenter: 58) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(DiscoverAiring.fromNow(items)) { item in
                            DiscoverAiringCard(item: item, state: DiscoverAiring.state(item, next: next)).frame(width: 300)
                                .accessibilityIdentifier("discover.calendar.\(item.id)")
                        }
                    }.padding(.horizontal, DiscoverLayout.gutter)
                }
                .id(shown)
            }
        }
    }
}

/// Where an item of today stands against now.
enum DiscoverAiring {
    enum State { case aired, next, later }

    static func next(_ items: [TMDBCalendar.Item], now: Date = Date()) -> String? {
        items.filter { ($0.airDate ?? .distantPast) > now }.min { $0.airDate! < $1.airDate! }?.id
    }

    static func state(_ item: TMDBCalendar.Item, next: String?, now: Date = Date()) -> State {
        if item.id == next { return .next }
        if let date = item.airDate, date <= now { return .aired }
        return .later
    }

    /// For the row: from the last one that aired, so it opens on what's next; all of it once everything has aired.
    static func fromNow(_ items: [TMDBCalendar.Item], now: Date = Date()) -> [TMDBCalendar.Item] {
        guard let next = next(items, now: now), let index = items.firstIndex(where: { $0.id == next }) else { return items }
        return Array(items[max(0, index - 1)...])
    }
}

/// A TV-guide card: the poster, the air time large, the title, and the episode and channel.
struct DiscoverAiringCard: View {
    let item: TMDBCalendar.Item
    var state: DiscoverAiring.State = .later
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let work = item.tmdb {
            RouteLink { DiscoverDetailView(item: item.catalogItem(work)) } label: { card }.tmdbCardButton()
        } else if let page = item.bangumiPage {
            DiscoverButton { openURL(page) } label: { card }.buttonStyle(.plain)
        } else {
            card
        }
    }

    private var time: String? {
        item.airDate?.formatted(Date.FormatStyle(locale: Locale(identifier: L10n.resolvedLanguage())).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }
    private var detail: String {
        let parts = [item.episode.map { L10n.text("Episode %@", String($0)) }, item.network ?? item.links.first?.name].compactMap { $0 }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return item.originalTitle == item.title ? "" : item.originalTitle
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: 64, height: 96)
                .overlay { PosterImage(url: item.cover, symbol: "tv") }
                .posterClip(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if let time {
                        Text(time).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(state == .next ? Color.accentColor : .primary)
                    }
                    if state == .next {
                        Text(L10n.text("Airs Next")).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.accentColor, in: Capsule())
                    } else if state == .aired {
                        Text(L10n.text("Aired")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    if time == nil, let rating = item.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill").labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    .layoutPriority(1)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                }
                // TMDB's TV list has no times or episodes, so a line of synopsis says what the show is.
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(height: 116, alignment: .top)
        .background { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.primary.opacity(state == .next ? 0.1 : 0.05)) }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(state == .next ? Color.accentColor.opacity(0.6) : .primary.opacity(0.06), lineWidth: state == .next ? 1 : 0.5)
        }
        .opacity(state == .aired ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A row of pill buttons, one selected.
private struct DiscoverCalendarChips<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: KeyPath<Value, String>
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(values, id: \.self) { value in
                let selected = value == selection
                Button { selection = value } label: {
                    Text(value[keyPath: title]).font(.system(size: compact ? 12 : 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : .primary)
                        .padding(.horizontal, compact ? 9 : 12).padding(.vertical, compact ? 3 : 5)
                        .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Monday to Sunday, today marked.
private struct DiscoverCalendarDays: View {
    let week: TMDBCalendar.Week
    @Binding var selection: String?
    var body: some View {
        let today = week.today()?.date
        HStack(spacing: 6) {
            ForEach(week.days) { day in
                let selected = day.date == selection
                Button { selection = day.date } label: {
                    VStack(spacing: 2) {
                        Text(day.date == today ? L10n.text("Today") : weekdayName(day)).font(.system(size: 12, weight: .semibold))
                        Text(dayNumber(day)).font(.system(size: 17, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(selected ? Color.white : day.date == today ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor : Color.primary.opacity(0.06)) }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weekdayName(day) + " " + dayNumber(day))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("calendar.day.\(day.weekday)")
            }
        }
        .frame(maxWidth: 560)
    }

    private func weekdayName(_ day: TMDBCalendar.Day) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: week.timeZone) ?? .current
        let parts = day.date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)) else { return "" }
        var style = Date.FormatStyle(locale: Locale(identifier: L10n.resolvedLanguage())).weekday(.abbreviated)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
    private func dayNumber(_ day: TMDBCalendar.Day) -> String { String(Int(day.date.suffix(2)) ?? 0) }
}

/// Whom the data comes from, as their licenses ask.
private struct DiscoverCalendarCredits: View {
    let week: TMDBCalendar.Week
    var body: some View {
        if !week.attribution.isEmpty {
            HStack(spacing: 4) {
                Text(L10n.text("Data:"))
                ForEach(Array(week.attribution.enumerated()), id: \.offset) { index, credit in
                    if index > 0 { Text("·") }
                    Link(credit.name, destination: credit.url)
                }
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.top, 12)
        }
    }
}

extension TMDBCalendar.Kind {
    var title: String { self == .anime ? L10n.text("Anime") : L10n.text("TV Series") }
}

extension TMDBCalendar.Region {
    var title: String {
        switch self {
        case .cn: L10n.text("Chinese Series")
        case .hktw: L10n.text("Hong Kong & Taiwan Series")
        case .us: L10n.text("American Series")
        case .jp: L10n.text("Japanese Series")
        case .kr: L10n.text("Korean Series")
        case .gb: L10n.text("British Series")
        }
    }
}

extension TMDBCalendar.Item {
    /// Enough of a catalog card for the detail page, which loads the rest itself.
    func catalogItem(_ work: TMDBCalendar.Work) -> TMDBCatalog.Item {
        TMDBCatalog.Item(id: work.id, mediaType: work.type, name: title, originalName: originalTitle, year: nil, overview: "",
                         poster: cover, backdrop: nil, rating: rating, genreIDs: [])
    }
}
#endif
