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
        Button { DiscoverFollowing.toggle(item, in: store) } label: {
            // Words and a fill, not just a badge on the icon: whether the series is followed reads at a glance.
            let label = HStack(spacing: 5) {
                Image(systemName: following ? "checkmark" : "plus").font(.system(size: 14, weight: .bold))
                Text(L10n.text(following ? "Following Show" : "Follow Show")).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 54)
            if following {
                label.foregroundStyle(.black).background(Capsule().fill(.white))
            } else {
                label.glassSurface(.regular, in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: following)
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

// MARK: - Following, unfollowing, and the note that says so

extension DiscoverFollowing {
    /// Follows or unfollows a series and says so in a toast: the title page's button, the calendar's, the TV's.
    @MainActor static func toggle(_ item: TMDBCatalog.Item, in store: Store) {
        let following = !store.followedShows.contains(item.id)
        withAnimation(.snappy(duration: 0.2)) { store.followedShows.toggle(item) }
        DiscoverToast.shared.show(following: following)
    }

    @MainActor static func unfollow(_ id: Int, in store: Store) {
        withAnimation(.snappy(duration: 0.25)) { store.followedShows.unfollow(id) }
        DiscoverToast.shared.show(following: false)
    }

    /// Opens or closes the air calendar card without the cover's slide: the card fades and springs by itself.
    @MainActor static func present(_ change: () -> Void) {
        #if os(tvOS)
        change()
        #else
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
        #endif
    }
}

/// The note after following or unfollowing a series: a glass capsule that springs in at the bottom, stays about two
/// seconds, and never moves or blocks what is under it. VoiceOver reads it out.
@MainActor @Observable final class DiscoverToast {
    static let shared = DiscoverToast()

    struct Note: Equatable {
        let id = UUID()
        let following: Bool
    }

    private(set) var note: Note?

    func show(following: Bool) {
        note = Note(following: following)
        var text = L10n.text(following ? "Following Show" : "Unfollowed Show")
        if following { text += ". " + L10n.text("New episodes show up in Following Calendar") }
        AccessibilityNotification.Announcement(text).post()
    }

    func clear(_ value: Note) { if note == value { note = nil } }
}

/// Shows `DiscoverToast`'s note over a page; off while something above the page shows it instead.
struct DiscoverToastHost: ViewModifier {
    var active = true
    @State private var toast = DiscoverToast.shared

    #if os(tvOS)
    private static let inset: CGFloat = 70
    #elseif os(macOS)
    private static let inset: CGFloat = 28
    #else
    private static let inset: CGFloat = 20
    #endif

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            ZStack {
                if active, let note = toast.note {
                    DiscoverToastLabel(following: note.following)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.85, anchor: .bottom)),
                                                removal: .opacity.combined(with: .scale(scale: 0.92, anchor: .bottom))))
                        .task(id: note.id) {
                            try? await Task.sleep(for: .seconds(2.2))
                            guard !Task.isCancelled else { return }
                            withAnimation(.smooth(duration: 0.3)) { toast.clear(note) }
                        }
                }
            }
            .padding(.bottom, Self.inset)
            .animation(.spring(duration: 0.45, bounce: 0.3), value: toast.note)
            .allowsHitTesting(false)
        }
    }
}

private struct DiscoverToastLabel: View {
    let following: Bool

    #if os(tvOS)
    private static let icon: CGFloat = 40, title: CGFloat = 28, hint: CGFloat = 24, height: CGFloat = 76, spacing: CGFloat = 14
    #else
    private static let icon: CGFloat = 24, title: CGFloat = 15, hint: CGFloat = 13, height: CGFloat = 46, spacing: CGFloat = 9
    #endif

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: following ? "checkmark" : "minus")
                .font(.system(size: Self.icon * 0.5, weight: .heavy))
                .frame(width: Self.icon, height: Self.icon)
                .background(Circle().fill(following ? Color.green : Color.white.opacity(0.3)))
            Text(L10n.text(following ? "Following Show" : "Unfollowed Show")).font(.system(size: Self.title, weight: .semibold))
            if following {
                Text(L10n.text("New episodes show up in Following Calendar")).font(.system(size: Self.hint)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .foregroundStyle(.white)
        .padding(.leading, Self.height * 0.22).padding(.trailing, Self.height * 0.42)
        .frame(height: Self.height)
        .background(Capsule().fill(following ? Color.green.opacity(0.18) : Color.black.opacity(0.25)))
        .glassSurface(.regular, in: Capsule())
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .accessibilityHidden(true)
    }
}

// MARK: - Air calendar

/// Opens the air calendar: a floating card over the blurred title page, full screen on the TV.
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
        #elseif os(iOS)
        content.fullScreenCover(isPresented: $isPresented) {
            if let schedule {
                DiscoverAirCalendarCard(schedule: schedule, show: show, isPresented: $isPresented).environment(store)
                    .presentationBackground(.clear)
            }
        }
        #else
        content.overlay {
            if isPresented, let schedule {
                DiscoverAirCalendarCard(schedule: schedule, show: show, isPresented: $isPresented).environment(store)
            }
        }
        #endif
    }
}

#if !os(tvOS)
/// A season's air calendar as a dark floating card: the series, then a month at a time with the air days painted under
/// their numbers, and the follow action beside Done. A tap outside closes it.
struct DiscoverAirCalendarCard: View {
    @Environment(Store.self) private var store
    let schedule: AirSchedule
    let show: TMDBCatalog.Item
    @Binding var isPresented: Bool
    @State private var shown = false
    @State private var month: Int
    @State private var forward = true
    private let months: [String]
    private let today = DiscoverFollowing.today
    private static let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

    init(schedule: AirSchedule, show: TMDBCatalog.Item, isPresented: Binding<Bool>) {
        self.schedule = schedule
        self.show = show
        _isPresented = isPresented
        let today = DiscoverFollowing.today
        let months = DiscoverAirMonth.months(schedule, today: today)
        self.months = months
        let focus = String((schedule.next(today: today)?.date ?? schedule.days.last?.date ?? today).prefix(7))
        _month = State(initialValue: months.firstIndex(of: focus) ?? 0)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.3)).background(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
                .onTapGesture(perform: close)
                .accessibilityLabel(L10n.text("Done"))
                .accessibilityAddTraits(.isButton)
            VStack(spacing: 12) {
                card
                bar
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 16)
            .scaleEffect(shown ? 1 : 0.94)
            .offset(y: shown ? 0 : 30)
            .opacity(shown ? 1 : 0)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .modifier(DiscoverToastHost())
        .onAppear { withAnimation(.spring(duration: 0.42, bounce: 0.18)) { shown = true } }
    }

    private func close() {
        guard shown else { return }
        withAnimation(.smooth(duration: 0.22)) { shown = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(230))
            DiscoverFollowing.present { isPresented = false }
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            header
            calendar
        }
        .padding(18)
        .fixedSize(horizontal: false, vertical: true)
        .background { Self.shape.fill(Color(white: 0.08).opacity(0.72)).background(.regularMaterial, in: Self.shape) }
        .overlay { Self.shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.4), radius: 34, y: 14)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(url: show.poster, symbol: "tv")
                .frame(width: 90, height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(show.name).font(.system(size: 19, weight: .bold)).lineLimit(2)
                    Spacer(minLength: 0)
                    if let network = schedule.networks.first {
                        Text(network).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).fixedSize()
                    }
                }
                Text(L10n.text("%@ · %@ Episodes", schedule.seasonTitle, String(schedule.total)))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                if !show.overview.isEmpty {
                    Text(show.overview).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if let rating = show.rating, rating > 0 {
                        Text("TMDB").font(.system(size: 11, weight: .heavy)).foregroundStyle(.cyan)
                        Text(String(format: "%.1f", rating)).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text("·").foregroundStyle(.white.opacity(0.35))
                    }
                    Text(L10n.text("%@ of %@ aired", String(schedule.aired(today: today)), String(schedule.total)))
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                }
                .monospacedDigit().lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 135, alignment: .topLeading)
        }
    }

    private var days: [String: AirSchedule.Day] { Dictionary(schedule.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first }) }

    private var calendar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                pager(-1)
                hairline
                Text(DiscoverAirMonth.title(months[month])).font(.system(size: 15, weight: .semibold)).fixedSize()
                hairline
                pager(1)
            }
            ZStack {
                DiscoverAirMonth(month: months[month], days: days, today: today)
                    .id(months[month])
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .clipped()
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 24).onEnded { value in
            if value.translation.width < -40 { page(1) } else if value.translation.width > 40 { page(-1) }
        }, including: months.count > 1 ? .all : .subviews)
    }

    private var hairline: some View { Rectangle().fill(.white.opacity(0.18)).frame(height: 0.5).frame(maxWidth: .infinity) }

    private func pager(_ step: Int) -> some View {
        let enabled = months.indices.contains(month + step)
        return Button { page(step) } label: {
            Image(systemName: step < 0 ? "chevron.backward" : "chevron.forward").font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(months.count > 1 ? (enabled ? 0.85 : 0.2) : 0)
        .disabled(!enabled)
        .accessibilityHidden(months.count < 2)
        .accessibilityLabel(L10n.text(step < 0 ? "Previous Month" : "Next Month"))
    }

    private func page(_ step: Int) {
        guard months.indices.contains(month + step) else { return }
        forward = step > 0
        withAnimation(.smooth(duration: 0.3)) { month += step }
    }

    private var bar: some View {
        let following = store.followedShows.contains(show.id)
        return HStack(spacing: 12) {
            Button { DiscoverFollowing.toggle(show, in: store) } label: {
                HStack(spacing: 8) {
                    Image(systemName: following ? "calendar.badge.minus" : "calendar.badge.plus").font(.system(size: 16, weight: .semibold))
                    Text(L10n.text(following ? "Unfollow Show" : "Follow Show")).font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(following ? Color(red: 1, green: 0.45, blue: 0.42) : .white)
                .padding(.horizontal, 20).frame(height: 50)
                .glassSurface(.regular, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("discover.airCalendar.follow")
            Spacer(minLength: 0)
            Button(action: close) {
                Text(L10n.text("Done")).font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 24).frame(height: 50)
                    .glassSurface(.regular, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("discover.airCalendar.done")
        }
    }
}
#else
/// A season's air calendar on the TV: the series on the left, its months stacked on the right.
struct DiscoverAirCalendarView: View {
    @Environment(Store.self) private var store
    let schedule: AirSchedule
    let show: TMDBCatalog.Item
    private let today = DiscoverFollowing.today

    var body: some View {
        let following = store.followedShows.contains(show.id)
        let days = Dictionary(schedule.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        ZStack(alignment: .topLeading) {
            Color.black
            if let backdrop = show.backdrop { TMDBArtwork(url: backdrop, maxPixels: 2400).opacity(0.25) }
            HStack(alignment: .top, spacing: 90) {
                VStack(alignment: .leading, spacing: 24) {
                    PosterImage(url: show.poster, symbol: "tv").frame(width: 300, height: 450)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(show.name).font(.system(size: 48, weight: .bold)).lineLimit(2)
                        Text(L10n.text("%@ · %@ Episodes", schedule.seasonTitle, String(schedule.total))).font(.system(size: 28)).opacity(0.75)
                        if !schedule.networks.isEmpty {
                            Text(schedule.networks.prefix(3).joined(separator: " / ")).font(.system(size: 26, weight: .semibold)).opacity(0.6)
                        }
                        Text(L10n.text("%@ of %@ aired", String(schedule.aired(today: today)), String(schedule.total)))
                            .font(.system(size: 26, design: .rounded)).monospacedDigit().opacity(0.75)
                    }
                    Button { DiscoverFollowing.toggle(show, in: store) } label: {
                        Label(L10n.text(following ? "Unfollow Show" : "Follow Show"), systemImage: following ? "calendar.badge.minus" : "calendar.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DiscoverTVActionStyle(height: 82, font: 30)).frame(width: 420)
                    .accessibilityIdentifier("discover.airCalendar.follow")
                }
                .frame(width: 520, alignment: .leading).focusSection()
                ScrollView {
                    VStack(spacing: 60) {
                        ForEach(DiscoverAirMonth.months(schedule, today: today), id: \.self) { month in
                            DiscoverAirMonth(month: month, days: days, today: today, showsTitle: true).focusable()
                        }
                    }
                    .padding(.vertical, 20)
                }
                .scrollClipDisabled().focusSection()
            }
            .padding(96)
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
        .modifier(DiscoverToastHost())
    }
}
#endif

/// One month of the air calendar, weeks starting on the viewer's first weekday: plain day numbers, a stroke of paint
/// under the days that bring episodes (fainter once aired) with the episodes beneath, and a green dot on today.
struct DiscoverAirMonth: View {
    /// "yyyy-MM"
    let month: String
    let days: [String: AirSchedule.Day]
    let today: String
    var showsTitle = false

    static let paint = Color(red: 0.95, green: 0.45, blue: 0.33)

    #if os(tvOS)
    private static let cell: CGFloat = 104, number: CGFloat = 32, small: CGFloat = 20, titleSize: CGFloat = 36, dot: CGFloat = 10
    private static let brush = CGSize(width: 80, height: 52)
    #else
    private static let cell: CGFloat = 46, number: CGFloat = 16, small: CGFloat = 9.5, titleSize: CGFloat = 15, dot: CGFloat = 5
    private static let brush = CGSize(width: 36, height: 25)
    #endif

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: L10n.resolvedLanguage())
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }

    /// "2026年11月", "November 2026".
    static func title(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1, hour: 12)) else { return month }
        return date.formatted(Date.FormatStyle(locale: calendar.locale ?? .current).year().month(.wide))
    }

    /// "yyyy-MM" from the first air date's month to the last's (this month when nothing is dated), at most a year.
    static func months(_ schedule: AirSchedule, today: String) -> [String] {
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
        return result.isEmpty ? [String(today.prefix(7))] : result
    }

    var body: some View {
        let calendar = Self.calendar
        let parts = month.split(separator: "-").compactMap { Int($0) }
        let first = parts.count == 2 ? calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1, hour: 12)) : nil
        let count = first.flatMap { calendar.range(of: .day, in: .month, for: $0)?.count } ?? 30
        let leading = first.map { (calendar.component(.weekday, from: $0) - calendar.firstWeekday + 7) % 7 } ?? 0
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let weekdays = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        #if os(tvOS)
        let slots = leading + count
        #else
        // Always six weeks, so paging months never changes the card's height.
        let slots = 42
        #endif
        VStack(spacing: 10) {
            if showsTitle { Text(Self.title(month)).font(.system(size: Self.titleSize, weight: .semibold)).frame(maxWidth: .infinity) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdays[index]).font(.system(size: Self.small + 1.5, weight: .medium)).foregroundStyle(.white.opacity(0.42))
                        .padding(.bottom, 4)
                }
                ForEach(0..<slots, id: \.self) { slot in
                    let day = slot - leading + 1
                    if day >= 1 && day <= count { cell(day) } else { Color.clear.frame(height: Self.cell) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func cell(_ day: Int) -> some View {
        let date = month + String(format: "-%02d", day)
        let episodes = days[date]
        let past = date < today
        return VStack(spacing: Self.cell * 0.04) {
            Text("\(day)")
                .font(.system(size: Self.number, weight: episodes == nil ? .regular : .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(episodes == nil ? (past ? 0.32 : 0.92) : (past ? 0.7 : 1)))
                .overlay(alignment: .topTrailing) {
                    if date == today {
                        Circle().fill(Color.green).frame(width: Self.dot, height: Self.dot).offset(x: Self.dot + 1, y: -1)
                    }
                }
                .frame(width: Self.brush.width, height: Self.brush.height)
                .background {
                    if episodes != nil {
                        DiscoverBrushStroke(seed: day * 31 + (Int(month.suffix(2)) ?? 0)).fill(Self.paint.opacity(past ? 0.28 : 0.82))
                    }
                }
            Text(episodes?.range ?? " ").font(.system(size: Self.small, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(past ? 0.38 : 0.7)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity).frame(height: Self.cell)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(episodes.map { "\(date) " + DiscoverFollowing.episodes($0) } ?? date)
    }
}

/// A band whose edges wander a little and that leans a touch, like one pass of a broad brush; the seed keeps each
/// day's stroke the same from one drawing to the next.
struct DiscoverBrushStroke: Shape {
    var seed: Int

    func path(in rect: CGRect) -> Path {
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ 0x2545_F491_4F6C_DD1D
        func random() -> CGFloat {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return CGFloat(state % 10_000) / 10_000
        }
        let count = 20
        var points: [CGPoint] = []
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(count) * 2 * .pi
            let x = cos(angle), y = sin(angle)
            // A squircle rather than an ellipse, so it reads as a broad band of paint.
            let sx = copysign(pow(abs(x), 0.6), x), sy = copysign(pow(abs(y), 0.7), y)
            let wobble = 1 + (random() - 0.5) * 0.2
            points.append(CGPoint(x: rect.midX + sx * rect.width / 2 * wobble, y: rect.midY + sy * rect.height / 2 * wobble))
        }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        var path = Path()
        path.move(to: middle(points[count - 1], points[0]))
        for index in 0..<count { path.addQuadCurve(to: middle(points[index], points[(index + 1) % count]), control: points[index]) }
        path.closeSubpath()
        let tilt = (random() - 0.5) * 0.16
        return path.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: tilt).translatedBy(x: -rect.midX, y: -rect.midY))
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
            Button(role: .destructive) { DiscoverFollowing.unfollow(show.id, in: store) } label: {
                SwiftUI.Label(L10n.text("Unfollow Show"), systemImage: "calendar.badge.minus")
            }
        }
        .accessibilityIdentifier("discover.following.\(show.id)")
    }
}

#if os(tvOS)
/// The Following Calendar's page on the TV: the followed series' episodes for the next four weeks, day by day, then
/// the series with nothing coming.
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
        .modifier(DiscoverToastHost())
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
#endif

#if !os(tvOS)
extension DiscoverFollowing {
    /// A week of the Following Calendar page: `offset` -1 is last week, 0 this week.
    struct Week: Identifiable {
        let start: String
        let end: String
        let offset: Int
        var id: String { start }
    }

    /// Last week, this week and the four after, each starting on the viewer's first weekday.
    static func weeks(today: String) -> [Week] {
        guard let now = AirSchedule.date(today) else { return [] }
        let calendar = Calendar.current
        let back = (calendar.component(.weekday, from: now) - calendar.firstWeekday + 7) % 7
        let start = now.addingTimeInterval(-Double(back) * 86_400)
        return (-1...4).map { offset in
            let first = start.addingTimeInterval(Double(offset * 7) * 86_400)
            return Week(start: AirSchedule.day(first), end: AirSchedule.day(first.addingTimeInterval(6 * 86_400)), offset: offset)
        }
    }

    static func weekName(_ offset: Int) -> String? {
        switch offset {
        case -1: L10n.text("Last Week")
        case 0: L10n.text("This Week")
        case 1: L10n.text("Next Week")
        default: nil
        }
    }

    private static func shifted(_ date: String, _ days: Int) -> String? {
        AirSchedule.date(date).map { AirSchedule.day($0.addingTimeInterval(Double(days) * 86_400)) }
    }

    /// "今天", "明天", "昨天", else the week the day is in.
    static func relative(_ date: String, week: Int, today: String) -> String {
        if date == today { return L10n.text("Today") }
        if date == shifted(today, 1) { return L10n.text("Tomorrow") }
        if date == shifted(today, -1) { return L10n.text("Yesterday") }
        return weekName(week) ?? ""
    }

    /// The card's timing pill: aired, today, tomorrow, or in how many days.
    static func timing(_ date: String, today: String) -> String {
        if date < today { return L10n.text("Aired") }
        if date == today { return L10n.text("Today") }
        guard let from = AirSchedule.date(today), let to = AirSchedule.date(date) else { return monthDay(date) }
        let days = Int((to.timeIntervalSince(from) / 86_400).rounded())
        return days == 1 ? L10n.text("Tomorrow") : L10n.text("In %@ days", String(days))
    }

    static func format(_ date: String, _ style: Date.FormatStyle) -> String {
        AirSchedule.date(date).map { $0.formatted(style.locale(Locale(identifier: L10n.resolvedLanguage()))) } ?? date
    }
}

/// The Following Calendar's page (#1186): last week to four weeks on, a week at a time under a header that stays at
/// the top, each day's shows as cards with the day beside the first; then the followed shows with nothing dated.
struct DiscoverFollowingView: View {
    @Environment(Store.self) private var store
    @State private var schedules: [Int: AirSchedule]
    @State private var loading = false
    /// Opened at this week, last week's episodes just above it.
    @State private var placed = false

    init(initial: [Int: AirSchedule] = [:]) { _schedules = State(initialValue: initial) }

    var body: some View {
        let shows = store.followedShows.shows
        let today = DiscoverFollowing.today
        let weeks = DiscoverFollowing.weeks(today: today)
        let agenda = AirSchedule.agenda(shows, schedules: schedules, today: today, from: weeks.first?.start, days: weeks.count * 7)
        let listed = Set(agenda.flatMap { $0.entries.map(\.show.id) })
        let quiet = shows.filter { !listed.contains($0.id) }.map { AirSchedule.Upcoming(show: $0, schedule: schedules[$0.id], day: nil) }
        let thisWeek = weeks.first { $0.offset == 0 }
        let pastShown = agenda.contains { $0.date < (thisWeek?.start ?? today) }
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if shows.isEmpty {
                    EmptyResults(symbol: "calendar.badge.plus", title: L10n.text("No Shows Followed"),
                                 message: L10n.text("Open a series in Discover and tap Follow Show to see when its new episodes air."))
                        .frame(maxWidth: .infinity).padding(.top, 80)
                }
                ForEach(weeks) { week in
                    let days = agenda.filter { $0.date >= week.start && $0.date <= week.end }
                    if !days.isEmpty {
                        Section {
                            VStack(spacing: 14) {
                                ForEach(days) { day in dayGroup(day, week: week.offset, today: today) }
                            }
                            .padding(.top, 8).padding(.bottom, 26)
                            .id(week.start)
                        } header: {
                            heading(DiscoverFollowing.weekName(week.offset),
                                    DiscoverFollowing.format(week.start, Date.FormatStyle().month(.abbreviated).day()) + "–"
                                        + DiscoverFollowing.format(week.end, Date.FormatStyle().month(.abbreviated).day()))
                        }
                    }
                }
                if !quiet.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            ForEach(quiet) { entry in
                                DiscoverFollowingLink(show: entry.show) { DiscoverFollowingCard(entry: entry, date: nil, today: today) }
                            }
                        }
                        .padding(.leading, Self.column + 12).padding(.top, 8).padding(.bottom, 26)
                    } header: {
                        heading(L10n.text("No upcoming episodes"), nil)
                    }
                }
                if loading, agenda.isEmpty, !shows.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40) }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, DiscoverLayout.gutter)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 40)
        }
        .onChange(of: pastShown, initial: true) {
            guard pastShown, !placed, let target = weeks.first(where: { week in week.offset >= 0 && agenda.contains { $0.date >= week.start && $0.date <= week.end } }) else { return }
            placed = true
            Task { @MainActor in proxy.scrollTo(target.start, anchor: .top) }
        }
        }
        .navigationTitle(L10n.text("Following Calendar"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        #endif
        .background { DiscoverCanvas(poster: shows.first?.poster) }
        .foregroundStyle(.white).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
        .modifier(DiscoverToastHost())
        .task(id: shows.map(\.id)) {
            loading = true
            let fresh = await AirSchedules.shared.schedules(shows.map(\.id))
            if !Task.isCancelled { schedules.merge(fresh) { _, new in new }; loading = false }
        }
    }

    private static let column: CGFloat = 50

    /// The week's name and dates in a glass capsule that stays at the top while its week scrolls by.
    private func heading(_ name: String?, _ detail: String?) -> some View {
        HStack(spacing: 7) {
            if let name { Text(name).font(.system(size: 15, weight: .bold)) }
            if let detail { Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)) }
        }
        .lineLimit(1)
        .padding(.horizontal, 14).frame(height: 34)
        .glassSurface(.regular, in: Capsule())
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayGroup(_ day: AirSchedule.AgendaDay, week: Int, today: String) -> some View {
        let isToday = day.date == today
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Text(DiscoverFollowing.format(day.date, Date.FormatStyle().weekday(.abbreviated))).font(.system(size: 17, weight: .bold))
                Text(DiscoverFollowing.format(day.date, Date.FormatStyle().month(.defaultDigits).day())).font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(.white.opacity(0.75))
                Text(DiscoverFollowing.relative(day.date, week: week, today: today)).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isToday ? AnyShapeStyle(Color.green) : AnyShapeStyle(.white.opacity(0.45)))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.vertical, 9)
            .frame(width: Self.column)
            .background {
                if isToday { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1)) }
            }
            .padding(.top, 6)
            VStack(spacing: 10) {
                ForEach(day.entries) { entry in
                    DiscoverFollowingLink(show: entry.show) { DiscoverFollowingCard(entry: entry, date: day.date, today: today) }
                }
            }
        }
        .opacity(day.date < today ? 0.7 : 1)
    }
}

/// A followed series in the Following Calendar: cover, name, year and genres, the network at the corner, then the season
/// and the day's episodes over a bar of aired episodes, and when the day is.
struct DiscoverFollowingCard: View {
    let entry: AirSchedule.Upcoming
    /// The agenda day the card is listed under; nil in "No upcoming episodes".
    let date: String?
    let today: String
    private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        let schedule = entry.schedule
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: entry.show.poster, symbol: "tv")
                .frame(width: 66, height: 99)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.show.name).font(.system(size: 16, weight: .bold)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let network = schedule?.networks.first {
                        Text(network).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).fixedSize()
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let schedule {
                    Text(episodeLine(schedule)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().lineLimit(1)
                    HStack(spacing: 10) {
                        DiscoverEpisodeBar(schedule: schedule, highlight: entry.day?.episodes ?? [], today: today)
                        if let date {
                            Text(DiscoverFollowing.timing(date, today: today)).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                                .foregroundStyle(date == today ? AnyShapeStyle(Color.green) : AnyShapeStyle(.white.opacity(0.85)))
                                .padding(.horizontal, 9).frame(height: 22)
                                .glassSurface(.regular, in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 99, alignment: .topLeading)
        }
        .padding(10)
        .glassSurface(.regular, in: Self.shape)
        .overlay { Self.shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        .contentShape(Self.shape)
    }

    /// "2026 · 剧情, 古装"
    private var subtitle: String {
        let genres = (entry.schedule?.genres ?? []).prefix(3).joined(separator: ", ")
        return [entry.show.year.map(String.init), genres.isEmpty ? nil : genres].compactMap { $0 }.joined(separator: " · ")
    }

    /// "第 1 季 · 第 8-9 集", or how many aired once nothing is coming: "第 1 季 · 第 9/30 集".
    private func episodeLine(_ schedule: AirSchedule) -> String {
        let episodes = entry.day.map { DiscoverFollowing.episodes($0) }
            ?? L10n.text("Episode %@ / %@", String(schedule.aired(today: today)), String(schedule.total))
        return "\(schedule.seasonTitle) · \(episodes)"
    }
}

/// Aired against all the season's episodes: a segment an episode up to 40, else one bar; the card's day is painted.
struct DiscoverEpisodeBar: View {
    let schedule: AirSchedule
    let highlight: [Int]
    let today: String

    var body: some View {
        let aired = Set(schedule.episodes.filter { ($0.airDate ?? "9999") <= today }.map(\.number))
        let total = schedule.total
        Group {
            if total > 0, total <= 40 {
                HStack(spacing: 2) {
                    ForEach(1...total, id: \.self) { number in Capsule().fill(color(number, aired: aired)) }
                }
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(.white.opacity(0.8)).frame(width: proxy.size.width * CGFloat(aired.count) / CGFloat(max(total, 1)))
                    }
                }
            }
        }
        .frame(height: 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(L10n.text("%@ of %@ aired", String(aired.count), String(total)))
    }

    private func color(_ number: Int, aired: Set<Int>) -> Color {
        if highlight.contains(number) { return DiscoverAirMonth.paint }
        return aired.contains(number) ? .white.opacity(0.8) : .white.opacity(0.16)
    }
}
#endif
