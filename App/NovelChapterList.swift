import SwiftUI
import TVCore

/// A table of contents row, worked out once: the chapter's number in Arabic digits (from "第一百二十章"), and its title
/// without that part, so numbers line up in a column of their own.
struct NovelChapterRow: Identifiable {
    let index: Int
    let number: String?
    let title: String
    let isVip: Bool
    var id: Int { index }
}

/// The chapters under one volume heading (or under none, before the first).
struct NovelChapterSection: Identifiable {
    let id: Int
    let title: String?
    var rows: [NovelChapterRow]
}

enum NovelChapterNumbers {
    static func sections(_ chapters: [NovelChapter]) -> [NovelChapterSection] {
        var sections: [NovelChapterSection] = []
        var open = NovelChapterSection(id: -1, title: nil, rows: [])
        for chapter in chapters {
            if chapter.isVolume {
                if open.title != nil || !open.rows.isEmpty { sections.append(open) }
                open = NovelChapterSection(id: -2 - chapter.index, title: chapter.title, rows: [])
                continue
            }
            let opening = NovelTypeStyle.opening(chapter.title)
            let number = opening.kicker.flatMap(value(of:)).map(String.init)
            open.rows.append(NovelChapterRow(index: chapter.index, number: number, title: opening.title, isVip: chapter.isVip))
        }
        if open.title != nil || !open.rows.isEmpty { sections.append(open) }
        return sections
    }

    /// "第一千零二十章" → 1020, "第12章" → 12.
    static func value(of kicker: String) -> Int? {
        let body = kicker.dropFirst().dropLast()
        guard !body.isEmpty else { return nil }
        let digits = body.compactMap { character -> Int? in
            guard let scalar = character.unicodeScalars.first else { return nil }
            if (0x30...0x39).contains(scalar.value) { return Int(scalar.value - 0x30) }
            if (0xFF10...0xFF19).contains(scalar.value) { return Int(scalar.value - 0xFF10) }
            return nil
        }
        if digits.count == body.count { return digits.reduce(0) { $0 * 10 + $1 } }
        let numerals: [Character: Int] = ["〇": 0, "零": 0, "一": 1, "壹": 1, "二": 2, "两": 2, "贰": 2, "三": 3, "叁": 3, "四": 4, "肆": 4,
                                          "五": 5, "伍": 5, "六": 6, "陆": 6, "七": 7, "柒": 7, "八": 8, "捌": 8, "九": 9, "玖": 9]
        let units: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000, "万": 10000]
        var total = 0, section = 0, number = 0, lastWasDigit = false
        for character in body {
            if let digit = numerals[character] {
                // "一二三" written digit by digit.
                number = lastWasDigit ? number * 10 + digit : digit
                lastWasDigit = true
            } else if let unit = units[character] {
                if unit == 10000 {
                    total += (section + number) * unit; section = 0
                } else {
                    section += (number == 0 ? 1 : number) * unit
                }
                number = 0; lastWasDigit = false
            } else {
                return nil
            }
        }
        let value = total + section + number
        return value > 0 ? value : nil
    }
}

/// The colours a table of contents is drawn in: the app's on the book's page, the reader's theme in the reader.
struct NovelListColors {
    var background: Color?
    var text: Color
    var accent: Color
    static let standard = NovelListColors(background: nil, text: .primary, accent: Brand.accent)
}

/// The table of contents, for the book's page and the reader: the book at the top with the order and a jump to the
/// chapter being read, a search, volume headings, and rows with the chapter's number in a column of its own. Chapters
/// before the one being read are dimmed.
struct NovelChapterList: View {
    let book: NovelBook
    let chapters: [NovelChapter]
    /// The chapter being read, or last read.
    let current: Int?
    var colors: NovelListColors = .standard
    let open: (Int) -> Void

    @State private var sections: [NovelChapterSection] = []
    @State private var query = ""
    @State private var newestFirst = false
    @State private var scrolled = false

    private var count: Int { sections.reduce(0) { $0 + $1.rows.count } }
    #if os(tvOS)
    private let digitWidth: CGFloat = 17
    #else
    private let digitWidth: CGFloat = 8.5
    #endif
    private var numberWidth: CGFloat {
        let longest = sections.lazy.flatMap(\.rows).compactMap(\.number).map(\.count).max() ?? 0
        return longest == 0 ? 0 : CGFloat(max(2, longest)) * digitWidth + 4
    }

    /// The sections as shown: searched and in the chosen order.
    private var shown: [NovelChapterSection] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var list = sections
        if !needle.isEmpty {
            list = list.compactMap { section in
                var section = section
                section.rows = section.rows.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.number == needle }
                return section.rows.isEmpty ? nil : section
            }
        }
        if newestFirst {
            list = list.reversed().map { section in var section = section; section.rows.reverse(); return section }
        }
        return list
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        listBody
        #endif
    }

    #if os(tvOS)
    @FocusState private var focusedRow: Int?

    /// Apple TV, as its Settings: the book at the left with the order and a jump to the chapter being read, the chapters
    /// as glass rows filling the right. No search: the system's search line and keyboard took half the screen.
    private var tvBody: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 60) {
                VStack(alignment: .leading, spacing: 28) {
                    NovelCover(book: book)
                        .frame(width: 240, height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.name).font(.title3.weight(.bold)).lineLimit(2)
                        if !book.author.isEmpty { Text(book.author).font(.callout).foregroundStyle(colors.text.opacity(0.6)).lineLimit(1) }
                        Text(L10n.text("%lld chapters", count)).font(.callout).foregroundStyle(colors.text.opacity(0.45))
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        Button { withAnimation(.smooth) { newestFirst.toggle() } } label: {
                            Label(newestFirst ? L10n.text("Newest First") : L10n.text("Oldest First"), systemImage: "arrow.up.arrow.down")
                        }
                        .controlButton()
                        if let current, chapters.indices.contains(current) {
                            Button {
                                withAnimation(.smooth) { proxy.scrollTo(current, anchor: .center) }
                                focusedRow = current
                            } label: { Label(L10n.text("Current Chapter"), systemImage: "book") }
                            .controlButton()
                        }
                    }
                }
                .frame(width: 420, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 30)
                .tvFocusSection()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown) { section in
                            if let title = section.title {
                                Text(title).font(.headline).foregroundStyle(colors.text.opacity(0.5))
                                    .padding(.leading, 28).padding(.top, 34).padding(.bottom, 8)
                            }
                            ForEach(section.rows) { row in
                                Button { open(row.index) } label: { tvLabel(row) }
                                    .glassRow()
                                    .focused($focusedRow, equals: row.index)
                                    .id(row.index)
                            }
                        }
                    }
                    .glassRowInsets()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tvFocusSection()
            }
            .padding(.leading, 80).padding(.trailing, 40)
            .task(id: chapters.count) {
                sections = NovelChapterNumbers.sections(chapters)
                guard !scrolled, let current else { return }
                scrolled = true
                await Task.yield()
                proxy.scrollTo(current, anchor: .center)
                focusedRow = current
            }
        }
        .foregroundStyle(colors.text)
    }

    private func tvLabel(_ row: NovelChapterRow) -> some View {
        let isCurrent = row.index == current
        let isRead = current.map { row.index < $0 } ?? false
        return HStack(spacing: 0) {
            if numberWidth > 0 {
                Text(row.number ?? "").font(.callout.monospacedDigit()).foregroundStyle(colors.text.opacity(0.4))
                    .frame(width: numberWidth, alignment: .trailing).padding(.trailing, 24)
            }
            Text(row.title).font(.body.weight(isCurrent ? .bold : .regular)).lineLimit(1)
                .foregroundStyle(colors.text.opacity(isRead && !isCurrent ? 0.5 : 1))
            Spacer(minLength: 20)
            if row.isVip { Image(systemName: "lock.fill").font(.callout).foregroundStyle(colors.text.opacity(0.4)) }
            if isCurrent { Image(systemName: "book.fill").font(.callout).padding(.leading, 12) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent ? L10n.text("%@, last read", row.title) : row.title)
    }
    #endif

    private var listBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.isEmpty { header(proxy) }
                    let shown = shown
                    if shown.isEmpty, !query.isEmpty {
                        ContentUnavailableView.search(text: query).padding(.top, 40)
                    }
                    ForEach(shown) { section in
                        if let title = section.title { volume(title) }
                        ForEach(section.rows) { row in
                            Button { open(row.index) } label: { label(row) }
                                .novelChapterButton()
                                .id(row.index)
                        }
                    }
                }
                .padding(.horizontal, Layout.gutter)
                .padding(.bottom, 30)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .catalogSearchable(text: $query, prompt: L10n.text("Search Chapters"))
            .task(id: chapters.count) {
                sections = NovelChapterNumbers.sections(chapters)
                guard !scrolled, let current else { return }
                scrolled = true
                await Task.yield()
                proxy.scrollTo(current, anchor: .center)
            }
        }
        .foregroundStyle(colors.text)
    }

    // MARK: Parts

    private func header(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                NovelCover(book: book)
                    .frame(width: coverSize.width, height: coverSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.name).font(.headline).lineLimit(2)
                    if !book.author.isEmpty {
                        Text(book.author).font(.subheadline).foregroundStyle(colors.text.opacity(0.6)).lineLimit(1)
                    }
                    Text(L10n.text("%lld chapters", count)).font(.footnote).foregroundStyle(colors.text.opacity(0.45))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                pill(newestFirst ? L10n.text("Newest First") : L10n.text("Oldest First"), symbol: "arrow.up.arrow.down") {
                    withAnimation(.smooth) { newestFirst.toggle() }
                }
                .accessibilityHint(L10n.text("Reverse Order"))
                Spacer(minLength: 0)
                if let current, chapters.indices.contains(current) {
                    pill(L10n.text("Current Chapter"), symbol: "book") {
                        withAnimation(.smooth) { proxy.scrollTo(current, anchor: .center) }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12).padding(.bottom, 10)
        .tvFocusSection()
    }

    private var coverSize: CGSize {
        #if os(tvOS)
        CGSize(width: 110, height: 147)
        #else
        CGSize(width: 60, height: 80)
        #endif
    }

    private func pill(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                #if !os(tvOS)
                .background(colors.text.opacity(0.07), in: Capsule())
                #endif
        }
        #if os(tvOS)
        .buttonStyle(.bordered)
        #else
        .buttonStyle(.plain)
        #endif
    }

    private func volume(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.footnote.weight(.semibold)).tracking(0.6).lineLimit(1)
            Rectangle().fill(colors.text.opacity(0.12)).frame(height: 0.5)
        }
        .foregroundStyle(colors.text.opacity(0.5))
        .padding(.horizontal, 14)
        .padding(.top, 26).padding(.bottom, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private func label(_ row: NovelChapterRow) -> some View {
        let isCurrent = row.index == current
        let isRead = current.map { row.index < $0 } ?? false
        return HStack(spacing: 0) {
            if numberWidth > 0 {
                Text(row.number ?? "")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(colors.text.opacity(isCurrent ? 0.75 : 0.38))
                    .frame(width: numberWidth, alignment: .trailing)
                    .padding(.trailing, 14)
            }
            Text(row.title)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? colors.accent : colors.text.opacity(isRead ? 0.45 : 0.92))
                .lineLimit(1)
            Spacer(minLength: 10)
            if row.isVip { Image(systemName: "lock.fill").font(.caption).foregroundStyle(colors.text.opacity(0.35)) }
            if isCurrent { Image(systemName: "book.fill").font(.caption).foregroundStyle(colors.accent).padding(.leading, 6) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isCurrent { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(colors.accent.opacity(0.11)) }
        }
        .overlay(alignment: .bottom) {
            if !isCurrent {
                Rectangle().fill(colors.text.opacity(0.07)).frame(height: 0.5)
                    .padding(.leading, 14 + (numberWidth > 0 ? numberWidth + 14 : 0)).padding(.trailing, 14)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent ? L10n.text("%@, last read", row.title) : row.title)
    }
}

extension View {
    @ViewBuilder fileprivate func novelChapterButton() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}

#if !os(tvOS)
/// The book page's chapters on the Mac and iPad, under the hero as the comic page's are: a heading with the count, the order and a
/// search, then the chapters in as many columns as the window holds, their numbers in a column of their own. Plain
/// cells, not glass: a novel can have thousands.
struct NovelChapterGrid: View {
    let chapters: [NovelChapter]
    /// The chapter last read.
    let current: Int?
    let open: (Int) -> Void

    @State private var sections: [NovelChapterSection] = []
    @State private var query = ""
    @State private var newestFirst = false
    @State private var searching = false
    @FocusState private var searchFocused: Bool

    private var count: Int { sections.reduce(0) { $0 + $1.rows.count } }
    private var numberWidth: CGFloat {
        let longest = sections.lazy.flatMap(\.rows).compactMap(\.number).map(\.count).max() ?? 0
        return longest == 0 ? 0 : CGFloat(max(2, longest)) * 8 + 4
    }
    private var shown: [NovelChapterSection] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var list = sections
        if !needle.isEmpty {
            list = list.compactMap { section in
                var section = section
                section.rows = section.rows.filter { $0.title.localizedCaseInsensitiveContains(needle) || $0.number == needle }
                return section.rows.isEmpty ? nil : section
            }
        }
        if newestFirst { list = list.reversed().map { var section = $0; section.rows.reverse(); return section } }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading
            let shown = shown
            if shown.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxWidth: .infinity).padding(.vertical, 30)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 0) {
                ForEach(shown) { section in
                    Section {
                        ForEach(section.rows) { row in
                            NovelChapterCell(row: row, numberWidth: numberWidth, isCurrent: row.index == current,
                                             isRead: current.map { row.index < $0 } ?? false) { open(row.index) }
                        }
                    } header: {
                        if let title = section.title {
                            HStack(spacing: 10) {
                                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 22).padding(.bottom, 6)
                        }
                    }
                }
            }
        }
        .task(id: chapters.count) {
            sections = NovelChapterNumbers.sections(chapters)
            #if DEBUG
            // `-qaNovelChapterSearch <text>` opens the search with that text.
            if let text = UserDefaults.standard.string(forKey: "qaNovelChapterSearch") { searching = true; query = text }
            #endif
        }
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(L10n.text("Chapters")).font(.title3.weight(.bold))
            Text("\(count)").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            if count > 1 {
                Button { withAnimation(.smooth(duration: 0.4)) { newestFirst.toggle() } } label: {
                    Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30)
                        .glassOrFill(.regular.interactive(), Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(newestFirst ? L10n.text("Newest First") : L10n.text("Oldest First"))
                .accessibilityLabel(L10n.text("Reverse Order"))
                .accessibilityAddTraits(newestFirst ? .isSelected : [])
            }
            // Search is a round button beside the order one, the same glass; it opens into a field in place.
            if searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    TextField(L10n.text("Search Chapters"), text: $query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        #if os(macOS)
                        .onExitCommand { closeSearch() }
                        #endif
                    Button { closeSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel(L10n.text("Clear"))
                }
                .font(.callout)
                .padding(.horizontal, 11).frame(width: 230, height: 30)
                .glassOrFill(.regular.interactive(), Color.primary.opacity(0.07), in: Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
            } else {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { searching = true }
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 30, height: 30)
                        .glassOrFill(.regular.interactive(), Color.primary.opacity(0.07), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .help(L10n.text("Search Chapters"))
                .accessibilityLabel(L10n.text("Search Chapters"))
            }
            Spacer(minLength: 0)
        }
    }

    private func closeSearch() {
        query = ""
        withAnimation(.smooth(duration: 0.3)) { searching = false }
    }
}

/// One chapter in the grid: number, title, a lock for paid ones; the one last read filled with the accent.
private struct NovelChapterCell: View {
    let row: NovelChapterRow
    let numberWidth: CGFloat
    let isCurrent: Bool
    let isRead: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if numberWidth > 0 {
                    Text(row.number ?? "").font(.callout.monospacedDigit())
                        .foregroundStyle(isCurrent ? AnyShapeStyle(Brand.onAccent.opacity(0.75)) : AnyShapeStyle(.tertiary))
                        .frame(width: numberWidth, alignment: .trailing)
                        .padding(.trailing, 12)
                }
                Text(row.title).font(.body.weight(isCurrent ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Brand.onAccent) : AnyShapeStyle(Color.primary.opacity(isRead ? 0.5 : 0.92)))
                Spacer(minLength: 8)
                if row.isVip { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary) }
                if isCurrent { Image(systemName: "book.fill").font(.caption).foregroundStyle(Brand.onAccent) }
            }
            .padding(.horizontal, 12).frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.08 : 0)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.title)
        .accessibilityLabel(isCurrent ? L10n.text("%@, last read", row.title) : row.title)
    }
}
#endif

#if os(tvOS)
/// Apple TV's book page chapters, under the hero as the Mac's: a glass pill with the count that turns the order around,
/// then the chapters in columns as glass rows, their numbers in a column of their own.
struct NovelChapterTVGrid: View {
    let chapters: [NovelChapter]
    /// The chapter last read.
    let current: Int?
    let open: (Int) -> Void

    @State private var sections: [NovelChapterSection] = []
    @State private var newestFirst = false

    private var count: Int { sections.reduce(0) { $0 + $1.rows.count } }
    private var numberWidth: CGFloat {
        let longest = sections.lazy.flatMap(\.rows).compactMap(\.number).map(\.count).max() ?? 0
        return longest == 0 ? 0 : CGFloat(max(2, longest)) * 15 + 6
    }
    private var shown: [NovelChapterSection] {
        newestFirst ? sections.reversed().map { var section = $0; section.rows.reverse(); return section } : sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Button { withAnimation(.smooth) { newestFirst.toggle() } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: newestFirst ? "arrow.down" : "arrow.up").contentTransition(.symbolEffect(.replace))
                        Text(L10n.text("Chapters"))
                        Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .glassPill()
                .accessibilityLabel(L10n.text("Reverse Order"))
                .accessibilityAddTraits(newestFirst ? .isSelected : [])
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 540), spacing: 24, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(shown) { section in
                    Section {
                        ForEach(section.rows) { row in
                            Button { open(row.index) } label: { label(row) }
                                .glassRow()
                                .accessibilityLabel(row.index == current ? L10n.text("%@, last read", row.title) : row.title)
                        }
                    } header: {
                        if let title = section.title {
                            HStack(spacing: 16) {
                                Text(title).font(.headline).lineLimit(1)
                                Rectangle().fill(.primary.opacity(0.15)).frame(height: 1)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28).padding(.top, 30).padding(.bottom, 8)
                        }
                    }
                }
            }
        }
        .tvFocusSection()
        .task(id: chapters.count) { sections = NovelChapterNumbers.sections(chapters) }
    }

    private func label(_ row: NovelChapterRow) -> some View {
        let isCurrent = row.index == current
        let isRead = current.map { row.index < $0 } ?? false
        return HStack(spacing: 0) {
            if numberWidth > 0 {
                Text(row.number ?? "").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
                    .frame(width: numberWidth, alignment: .trailing).padding(.trailing, 20)
            }
            Text(row.title).font(.callout.weight(isCurrent ? .bold : .regular)).lineLimit(1)
                .foregroundStyle(Color.primary.opacity(isRead && !isCurrent ? 0.5 : 1))
            Spacer(minLength: 16)
            if row.isVip { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary) }
            if isCurrent { Image(systemName: "book.fill").font(.caption).padding(.leading, 10) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
