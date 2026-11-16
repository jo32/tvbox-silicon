import SwiftUI
import TVCore

/// Following series from Discover (追剧, #1186): a Follow button on a series' page, its season's air calendar, and
/// the Following Calendar shelf and page listing when the followed series' next episodes air. Only TMDB's air dates,
/// through the Worker: no sources, no Douban.
enum DiscoverFollowing {
    static var today: String { AirSchedule.day(Date()) }

    /// "Today", "Tomorrow", else the weekday and day of the month ("Wed 18", "周三 18").
    static func dayName(_ date: String, today: String = today) -> String {
        if date == today { return L10n.text("Today") }
        if let start = AirSchedule.date(today), date == AirSchedule.day(start.addingTimeInterval(86_400)) { return L10n.text("Tomorrow") }
        guard let value = AirSchedule.date(date), let day = date.split(separator: "-").last.flatMap({ Int($0) }) else { return date }
        return "\(value.formatted(Date.FormatStyle(locale: Locale(identifier: L10n.resolvedLanguage())).weekday(.abbreviated))) \(day)"
    }

    /// "11-16": a day without its year, as Rex shows it.
    static func monthDay(_ date: String) -> String { String(date.dropFirst(5)) }

    static func episodes(_ day: AirSchedule.Day) -> String { L10n.text("Episode %@", day.range) }

    /// The shelf's caption: when the next episodes air and which.
    static func caption(_ entry: AirSchedule.Upcoming, today: String = today) -> String {
        guard let day = entry.day else { return entry.schedule == nil ? " " : L10n.text("No upcoming episodes") }
        return "\(dayName(day.date, today: today)) · \(episodes(day))"
    }

    /// The air calendar row's value: "11-16 · Episode 7-8 / 30", or how many aired once nothing is coming.
    static func progress(_ schedule: AirSchedule, today: String = today) -> String {
        let total = String(schedule.total)
        guard let next = schedule.next(today: today) else { return L10n.text("Episode %@ / %@", String(schedule.aired(today: today)), total) }
        return "\(monthDay(next.date)) · " + L10n.text("Episode %@ / %@", next.range, total)
    }

    #if os(tvOS)
    static func entry(_ entry: AirSchedule.Upcoming) -> DiscoverTVNativeShelf.Entry {
        DiscoverTVNativeShelf.Entry(key: String(entry.show.id), title: entry.show.name, detail: caption(entry), image: entry.show.poster,
                                    highlight: entry.day?.date == today)
    }
    #endif
}

/// The page's Follow Show button, beside Search Sources.
struct DiscoverFollowButton: View {
    @Environment(Store.self) private var store
    let item: TMDBCatalog.Item
    var body: some View {
        let following = store.followedShows.contains(item.id)
        Button { store.followedShows.toggle(item) } label: {
            Image(systemName: following ? "calendar.badge.checkmark" : "calendar.badge.plus").font(.system(size: 21))
                .frame(width: 54, height: 54)
                .glassSurface(.regular, in: Circle())
        }
        .buttonStyle(.plain)
        .help(L10n.text(following ? "Unfollow Show" : "Follow Show"))
        .accessibilityLabel(L10n.text(following ? "Unfollow Show" : "Follow Show"))
        .accessibilityIdentifier("discover.detail.follow")
    }
}

/// "Air Calendar · 11-16 · Episode 7-8 / 30" over a series' episodes while its latest season airs.
struct DiscoverAirCalendarRow: View {
    let schedule: AirSchedule
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "calendar").font(.system(size: 15, weight: .medium))
                Text(L10n.text("Air Calendar")).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(DiscoverFollowing.progress(schedule)).font(.system(size: 14, design: .rounded)).monospacedDigit().lineLimit(1).opacity(0.75)
                Image(systemName: "chevron.forward").font(.system(size: 13, weight: .semibold)).opacity(0.5)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .glassSurface(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("discover.detail.airCalendar")
    }
}

/// Opens the air calendar: a sheet, full screen on the TV.
struct DiscoverAirCalendarPresentation: ViewModifier {
    @Environment(Store.self) private var store
    @Binding var isPresented: Bool
    let schedule: AirSchedule?
    let show: TMDBCatalog.Item
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.fullScreenCover(isPresented: $isPresented) {
            if let schedule { DiscoverAirCalendarView(schedule: schedule, show: show).environment(store) }
        }
        #else
        content.sheet(isPresented: $isPresented) {
            if let schedule {
                DiscoverAirCalendarView(schedule: schedule, show: show).environment(store)
                    .presentationDetents([.large]).discoverSheetSize(width: 520, height: 780)
            }
        }
        #endif
    }
}

/// A season's air calendar, month by month: each day with the episodes it brings, past days dimmed, today marked.
struct DiscoverAirCalendarView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let schedule: AirSchedule
    let show: TMDBCatalog.Item
    private let today = DiscoverFollowing.today

    #if os(tvOS)
    private static let posterWidth: CGFloat = 300
    #else
    private static let posterWidth: CGFloat = 84
    #endif

    var body: some View {
        #if os(tvOS)
        ZStack(alignment: .topLeading) {
            Color.black
            if let backdrop = show.backdrop { TMDBArtwork(url: backdrop, maxPixels: 2400).opacity(0.25) }
            HStack(alignment: .top, spacing: 90) {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    followButton.buttonStyle(DiscoverTVActionStyle(height: 82, font: 30)).frame(width: 420)
                }.frame(width: 520, alignment: .leading).focusSection()
                ScrollView {
                    VStack(spacing: 60) {
                        ForEach(months, id: \.self) { month in
                            DiscoverAirMonth(month: month, days: days, today: today).focusable()
                        }
                    }.padding(.vertical, 20)
                }.scrollClipDisabled().focusSection()
            }.padding(96)
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    ForEach(months, id: \.self) { month in DiscoverAirMonth(month: month, days: days, today: today) }
                    followButton.buttonStyle(.bordered).controlSize(.large).frame(maxWidth: .infinity)
                }.padding(20)
            }
            .navigationTitle(L10n.text("Air Calendar"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }
        #endif
    }

    private var header: some View {
        let layout = tvLayout ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        return layout {
            PosterImage(url: show.poster, symbol: "tv").frame(width: Self.posterWidth, height: Self.posterWidth * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: tvLayout ? 20 : 10, style: .continuous))
            VStack(alignment: .leading, spacing: tvLayout ? 10 : 5) {
                Text(show.name).font(.system(size: tvLayout ? 48 : 20, weight: .bold)).lineLimit(2)
                Text(L10n.text("%@ · %@ Episodes", schedule.seasonTitle, String(schedule.total)))
                    .font(.system(size: tvLayout ? 28 : 14)).opacity(0.75)
                if !schedule.networks.isEmpty {
                    Text(schedule.networks.prefix(3).joined(separator: " / ")).font(.system(size: tvLayout ? 26 : 13, weight: .semibold)).opacity(0.6)
                }
                Text(L10n.text("%@ of %@ aired", String(schedule.aired(today: today)), String(schedule.total)))
                    .font(.system(size: tvLayout ? 26 : 13, design: .rounded)).monospacedDigit().foregroundStyle(Brand.accent)
            }
        }
    }

    private var followButton: some View {
        let following = store.followedShows.contains(show.id)
        return Button { store.followedShows.toggle(show) } label: {
            Label(L10n.text(following ? "Following Show" : "Follow Show"), systemImage: following ? "calendar.badge.checkmark" : "calendar.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("discover.airCalendar.follow")
    }

    private var tvLayout: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var days: [String: AirSchedule.Day] { Dictionary(schedule.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first }) }

    /// "yyyy-MM" from the first air date's month to the last's (this month when nothing is dated), at most a year.
    private var months: [String] {
        let dated = schedule.days.map(\.date)
        let first = String((dated.first ?? today).prefix(7)), last = String((dated.last ?? today).prefix(7))
        var result: [String] = []
        var value = first
        while value <= last, result.count < 12 {
            result.append(value)
            let parts = value.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 2 else { break }
            value = parts[1] == 12 ? String(format: "%04d-01", parts[0] + 1) : String(format: "%04d-%02d", parts[0], parts[1] + 1)
        }
        return result
    }
}

/// One month of the air calendar, weeks starting on the viewer's first weekday.
private struct DiscoverAirMonth: View {
    /// "yyyy-MM"
    let month: String
    let days: [String: AirSchedule.Day]
    let today: String

    #if os(tvOS)
    private static let cell: CGFloat = 96, number: CGFloat = 32, small: CGFloat = 20, title: CGFloat = 36
    #else
    private static let cell: CGFloat = 50, number: CGFloat = 16, small: CGFloat = 10, title: CGFloat = 17
    #endif

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: L10n.resolvedLanguage())
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    var body: some View {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        let calendar = calendar
        let first = parts.count == 2 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1, hour: 12)) : nil
        let count = first.flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 30
        let leading = first.map { (calendar.component(.weekday, from: $0) - calendar.firstWeekday + 7) % 7 } ?? 0
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let weekdays = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        VStack(spacing: 10) {
            Text(first.map { $0.formatted(Date.FormatStyle(locale: calendar.locale ?? .current).year().month(.wide)) } ?? month)
                .font(.system(size: Self.title, weight: .semibold)).frame(maxWidth: .infinity)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(weekdays.indices, id: \.self) { index in
                    Text(weekdays[index]).font(.system(size: Self.small)).opacity(0.5)
                }
                ForEach(0..<leading, id: \.self) { index in Color.clear.frame(height: Self.cell) }
                ForEach(1...count, id: \.self) { day in cell(day) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func cell(_ day: Int) -> some View {
        let date = month + String(format: "-%02d", day)
        let episodes = days[date]
        let past = date < today
        let isToday = date == today
        return VStack(spacing: 2) {
            Text("\(day)").font(.system(size: Self.number, weight: episodes == nil ? .regular : .bold, design: .rounded))
            Text(episodes?.range ?? " ").font(.system(size: Self.small, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity).frame(height: Self.cell)
        .foregroundStyle(episodes != nil && !past ? AnyShapeStyle(Brand.onAccent) : AnyShapeStyle(.primary.opacity(past && episodes == nil ? 0.45 : 1)))
        .background {
            if episodes != nil {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Brand.accent.opacity(past ? 0.3 : 0.9))
            }
        }
        .overlay {
            if isToday { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary, lineWidth: 1.5) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(episodes.map { "\(date) " + DiscoverFollowing.episodes($0) } ?? date)
    }
}

/// A followed series as Discover draws its titles: the cover, the name, and when its next episodes air.
struct DiscoverFollowingTile: View {
    let show: FollowedShow
    let caption: String
    var highlight = false
    var width: CGFloat = DiscoverLayout.posterWidth
    var body: some View {
        #if os(tvOS)
        VStack(spacing: 5) {
            PosterImage(url: show.poster, symbol: "tv").frame(width: width, height: width * 1.5)
                .coverOverlay(alignment: .topLeading) { badge.padding(12) }
            VStack(spacing: 0) {
                Text(show.name).font(.system(size: DiscoverLayout.caption))
                Text(caption).font(.system(size: DiscoverLayout.secondary, weight: .medium))
                    .foregroundStyle(highlight ? Brand.accent : .white.opacity(0.5))
            }.lineLimit(1).cardCaption()
        }.frame(width: width)
        #else
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(2.0 / 3, contentMode: .fit)
                .overlay { PosterImage(url: show.poster, symbol: "tv") }
                .posterClip(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
                .overlay(alignment: .topLeading) { badge.padding(6) }
            VStack(alignment: .leading, spacing: 1) {
                Text(show.name).font(.system(size: DiscoverLayout.caption)).lineLimit(1)
                Text(caption).lineLimit(1)
                    .font(.system(size: DiscoverLayout.secondary, design: .rounded)).monospacedDigit()
                    .foregroundStyle(highlight ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary.opacity(0.56)))
            }.frame(maxWidth: .infinity, alignment: .leading).frame(height: DiscoverLayout.captionHeight)
        }
        .accessibilityElement(children: .combine)
        #endif
    }

    @ViewBuilder private var badge: some View {
        if highlight {
            Text(L10n.text("Today"))
                #if os(tvOS)
                .font(.system(size: 20, weight: .bold)).padding(.horizontal, 12).padding(.vertical, 5)
                #else
                .font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                #endif
                .foregroundStyle(Brand.onAccent).background(Brand.accent, in: Capsule())
        }
    }
}

/// Opens a followed series' Discover page; its menu unfollows it.
struct DiscoverFollowingLink<Label: View>: View {
    @Environment(Store.self) private var store
    let show: FollowedShow
    @ViewBuilder let label: Label
    var body: some View {
        RouteLink { DiscoverDetailView(item: show.catalogItem) } label: { label }
        #if os(tvOS)
        .cardButton()
        #else
        .tmdbCardButton()
        #endif
        .contextMenu {
            Button(role: .destructive) { store.followedShows.unfollow(show.id) } label: {
                SwiftUI.Label(L10n.text("Unfollow Show"), systemImage: "calendar.badge.minus")
            }
        }
        .accessibilityIdentifier("discover.following.\(show.id)")
    }
}

/// The Following Calendar shelf's page: the followed series' episodes for the next four weeks, day by day, then the
/// series with nothing coming.
struct DiscoverFollowingView: View {
    @Environment(Store.self) private var store
    @State private var schedules: [Int: AirSchedule]
    @State private var loading = false

    init(initial: [Int: AirSchedule] = [:]) { _schedules = State(initialValue: initial) }

    #if os(tvOS)
    private static let tile: CGFloat = 224
    private static var columns: [GridItem] { Array(repeating: GridItem(.fixed(224), spacing: 51, alignment: .top), count: 6) }
    #else
    private static let tile: CGFloat = DiscoverLayout.posterWidth
    private static var columns: [GridItem] { [GridItem(.adaptive(minimum: DiscoverLayout.posterWidth), spacing: DiscoverLayout.spacing, alignment: .top)] }
    #endif

    var body: some View {
        let shows = store.followedShows.shows
        let today = DiscoverFollowing.today
        let agenda = AirSchedule.agenda(shows, schedules: schedules, today: today)
        let listed = Set(agenda.flatMap { $0.entries.map(\.show.id) })
        let quiet = shows.filter { !listed.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                #if os(tvOS)
                Text(L10n.text("Following Calendar")).font(.system(size: 52, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity).padding(.top, 60)
                #endif
                if shows.isEmpty {
                    EmptyResults(symbol: "calendar.badge.plus", title: L10n.text("No Shows Followed"),
                                 message: L10n.text("Open a series in Discover and tap Follow Show to see when its new episodes air."))
                        .frame(maxWidth: .infinity).padding(.top, 80)
                }
                ForEach(agenda) { day in
                    group("\(DiscoverFollowing.dayName(day.date, today: today)) · \(DiscoverFollowing.monthDay(day.date))",
                          entries: day.entries, today: day.date == today) { DiscoverFollowing.episodes($0.day!) }
                }
                if !quiet.isEmpty {
                    group(L10n.text("No upcoming episodes"), entries: quiet.map { AirSchedule.Upcoming(show: $0, schedule: schedules[$0.id], day: nil) }, today: false) { entry in
                        guard let schedule = entry.schedule else { return " " }
                        return DiscoverFollowing.progress(schedule, today: today)
                    }
                }
                if loading, agenda.isEmpty, !shows.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40) }
            }
            #if os(tvOS)
            .frame(width: 6 * 224 + 5 * 51).frame(maxWidth: .infinity).padding(.bottom, 80)
            #else
            .padding(.vertical, DiscoverLayout.gutter)
            #endif
        }
        #if os(tvOS)
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationTitle(L10n.text("Following Calendar"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        #endif
        .background { DiscoverCanvas(poster: shows.first?.poster) }
        .foregroundStyle(.white).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
        .task(id: shows.map(\.id)) {
            loading = true
            let fresh = await AirSchedules.shared.schedules(shows.map(\.id))
            if !Task.isCancelled { schedules.merge(fresh) { _, new in new }; loading = false }
        }
    }

    private func group(_ title: String, entries: [AirSchedule.Upcoming], today: Bool, caption: @escaping (AirSchedule.Upcoming) -> String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: DiscoverLayout.heading, weight: .semibold))
                .foregroundStyle(today ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.primary))
                #if !os(tvOS)
                .padding(.horizontal, DiscoverLayout.gutter)
                #endif
            LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 22) {
                ForEach(entries) { entry in
                    DiscoverFollowingLink(show: entry.show) {
                        DiscoverFollowingTile(show: entry.show, caption: caption(entry), highlight: today, width: Self.tile)
                    }
                }
            }
            #if os(tvOS)
            .focusSection()
            #else
            .padding(.horizontal, DiscoverLayout.gutter)
            #endif
        }
    }
}
