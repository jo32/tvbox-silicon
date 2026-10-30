import SwiftUI
import TVCore

/// Catalog search with a bottom input bar, persistent filters,
/// 30-point section headers, horizontal 136-point cards and circular people rails.
struct DiscoverSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = DiscoverSearchModel()
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var feed: TMDBCatalog.SearchFeed = .popular
    @State private var filter: TMDBCatalog.Filter?
    @State private var filterSection: DiscoverFilterSection?
    @State private var expanded: Set<TMDBCatalog.SearchKind> = []
    @State private var focused = false
    @State private var revision = 0
    private var keyword: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var request: DiscoverSearchRequest { .init(keyword: keyword, feed: feed, filter: filter, revision: revision) }
    private let sections: [DiscoverFilterSection] = [.type, .genres, .years, .sort, .platform, .language, .region, .keywords]

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if keyword.isEmpty && filter == nil && !model.history.isEmpty { history.padding(.bottom, 12) }
                            if model.loading && model.groups.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 50) }
                            ForEach([TMDBCatalog.SearchKind.person, .movie, .tv], id: \.self) { kind in
                                if let group = model.groups[kind], group.count > 0 || (filter != nil && group.hasMore) { results(group, kind: kind, width: geometry.size.width) }
                            }
                            if model.isEmpty && !model.loading && !model.failed {
                                ContentUnavailableView(L10n.text("No Results"), systemImage: "magnifyingglass", description: Text(L10n.text("Try another title or change your filters.")))
                                    .accessibilityIdentifier("discover.search.empty")
                            }
                            if model.failed {
                                Button(L10n.text("Try Again")) { revision += 1 }.frame(maxWidth: .infinity).padding(24)
                            }
                        }.padding(.top, 4).padding(.bottom, 16)
                    }
                    .scrollIndicators(.hidden)
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    #endif
                    .safeAreaInset(edge: .top, spacing: 0) { topChrome }
                    .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
                    if let section = filterSection {
                        Color.clear.contentShape(Rectangle()).onTapGesture { filterSection = nil }
                            .padding(.top, 122)
                        DiscoverSearchFilters(filter: Binding(get: { filter ?? .init() }, set: { filter = $0 }), section: section)
                            .frame(maxHeight: max(150, geometry.size.height - 190))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16).padding(.top, 132)
                            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipShape(DiscoverSearchHorizontalClip())
            }
            .background { DiscoverSearchAtmosphere() }
            #if !os(macOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .routeDestinations()
            .navigationDestination(for: TMDBCatalog.Item.self) { DiscoverDetailView(item: $0) }
            .navigationDestination(for: TMDBCatalog.SearchPerson.self) { DiscoverSearchPersonView(person: $0) }
        }
        .environment(\.openRoute) { path.append($0) }
        .tint(.primary)
        .task(id: request) { expanded.removeAll(); await model.load(request) }
        .onChange(of: path.count) { _, value in if value > 0 { focused = false; filterSection = nil } }
    }

    private var topChrome: some View {
        VStack(spacing: 19) {
            Text(L10n.text("Search")).font(.system(size: 17, weight: .semibold)).frame(height: 44).frame(maxWidth: .infinity)
            ScrollView(.horizontal) {
                GlassGroup(spacing: 8) { HStack(spacing: 8) {
                    ForEach(sections, id: \.self) { section in
                        if section == .type {
                            Menu {
                                Button(L10n.text("Any")) { filter = nil; filterSection = nil }
                                ForEach([TMDBCatalog.SearchKind.movie, .tv], id: \.self) { kind in
                                    Button(kind.title) {
                                        var next = filter ?? .init()
                                        if next.kind != kind { next = .init(); next.kind = kind }
                                        filter = next; filterSection = nil; focused = false
                                    }
                                }
                            } label: { filterChip(section) }
                                .accessibilityIdentifier("discover.filter.section.type")
                        } else {
                            Button {
                                focused = false
                                withAnimation(.easeInOut(duration: 0.2)) { filterSection = filterSection == section ? nil : section }
                            } label: { filterChip(section) }
                                .accessibilityIdentifier("discover.filter.section.\(section.rawValue)")
                        }
                    }
                    if filter != nil {
                        Button { filter = nil; filterSection = nil } label: { Image(systemName: "xmark").frame(width: 38, height: 38).glassSurface(.regular, in: Circle()) }
                            .accessibilityLabel(L10n.text("Reset Filters")).accessibilityIdentifier("discover.search.resetFilters")
                    }
                } }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden).scrollClipDisabled().frame(height: 38)
        }.padding(.top, 16).padding(.bottom, 5)
    }
    private func filterChip(_ section: DiscoverFilterSection) -> some View {
        HStack(spacing: 8) {
            Text(section.chipTitle(filter)).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold))
        }.font(.system(size: 15)).padding(.horizontal, 14).frame(height: 38).glassSurface(.regular, in: Capsule())
    }
    private var bottomChrome: some View {
        HStack(spacing: 8) {
            if !focused && filter == nil {
                Button { dismiss() } label: { Image(systemName: "safari.fill").font(.system(size: 26)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle()) }
                    .accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("discover.search.close")
            }
            HStack(spacing: 12) {
                if filter == nil {
                    Menu {
                        ForEach(TMDBCatalog.SearchFeed.allCases, id: \.self) { value in
                            Button { feed = value } label: { if feed == value { Label(value.title, systemImage: "checkmark") } else { Text(value.title) } }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 23)).foregroundStyle(.secondary) }
                        .accessibilityLabel(L10n.text("Discover More")).accessibilityIdentifier("discover.search.feed")
                } else { Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(.secondary) }
                DiscoverSearchInput(text: $query, focused: $focused) { model.remember(keyword); focused = false }
                    .frame(height: 44)
                if focused && !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel(L10n.text("Clear")).accessibilityIdentifier("discover.search.clear")
                }
            }.padding(.horizontal, 18).frame(height: 48).glassSurface(.regular, in: Capsule())
            if focused || filter != nil {
                Button {
                    if focused { focused = false } else { filter = nil; filterSection = nil }
                } label: { Image(systemName: "xmark").font(.system(size: 23)).frame(width: 48, height: 48).glassSurface(.regular, in: Circle()) }
                    .accessibilityLabel(L10n.text("Close")).accessibilityIdentifier("discover.search.cancel")
            }
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Recent Searches")).font(.system(size: 16, weight: .semibold)); Spacer()
                Button { model.clearHistory() } label: { Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(.secondary) }
                    .accessibilityLabel(L10n.text("Clear Search History"))
            }.padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(model.history, id: \.self) { text in
                        Button { query = text; focused = false } label: { Text(text).font(.system(size: 13)).padding(.horizontal, 14).frame(height: 34).glassSurface(.regular, in: Capsule()) }
                    }
                }.padding(.horizontal, 16)
            }.scrollIndicators(.hidden)
        }
    }
    @ViewBuilder private func results(_ group: DiscoverSearchGroup, kind: TMDBCatalog.SearchKind, width: CGFloat) -> some View {
        // Expanded rows remain direct lazy children, avoiding a tall nested stack that
        // repeatedly changes its estimated height during pagination.
        Section {
            if kind == .person {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(group.people) { person in
                            Button { model.remember(keyword); focused = false; path.append(person) } label: { DiscoverSearchPersonRow(person: person) }
                                .buttonStyle(.plain).accessibilityIdentifier("discover.search.person.\(person.id)")
                        }
                    }.padding(.horizontal, 16)
                }.scrollIndicators(.hidden).frame(height: 124).padding(.bottom, 12)
            } else if expanded.contains(kind) || filter != nil {
                ForEach(group.items, id: \.key) { item in titleButton(item).padding(.horizontal, 16).padding(.bottom, 10) }
                if group.hasMore {
                    Button { Task { await model.more(kind, request: request) } } label: {
                        Group { if group.loadingMore { ProgressView() } else { Text(L10n.text(group.failedMore ? "Try Again" : "Load More")) } }
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }.disabled(group.loadingMore).accessibilityIdentifier("discover.search.more.\(kind.rawValue)")
                }
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(group.items, id: \.key) { item in titleButton(item).frame(width: min(265.333, width - 32)) }
                    }.padding(.horizontal, 16)
                }.scrollIndicators(.hidden).frame(height: 136).padding(.bottom, 12)
            }
        } header: {
            Button {
                guard kind != .person, filter == nil else { return }
                focused = false
                withAnimation(.easeInOut(duration: 0.22)) {
                    if expanded.contains(kind) { expanded.remove(kind) } else { expanded.insert(kind) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(filter == nil ? kind.title : L10n.text("Filtered Results")).font(.system(size: 16, weight: .semibold))
                    if kind != .person && filter == nil { Image(systemName: expanded.contains(kind) ? "rectangle.compress.vertical" : "rectangle.expand.vertical").font(.system(size: 18)) }
                    Spacer()
                }.frame(height: 30).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("discover.search.expand.\(kind.rawValue)")
                .padding(.horizontal, 16).padding(.bottom, 4)
        }
    }
    private func titleButton(_ item: TMDBCatalog.Item) -> some View {
        Button { model.remember(keyword); model.rememberOpened(item); focused = false; path.append(item) } label: { DiscoverSearchRow(item: item) }
            .buttonStyle(.plain).accessibilityIdentifier("discover.search.result.\(item.key)")
    }
}

struct DiscoverSearchRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: TMDBCatalog.Item
    var body: some View {
        HStack(spacing: 10) {
            PosterImage(url: item.poster).frame(width: 80, height: 120).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(([L10n.text(item.mediaType == .tv ? "Series" : "Movies"), item.year.map(String.init), item.genreNames.isEmpty ? nil : item.genreNames.replacingOccurrences(of: " / ", with: " · ")]).compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                if let rating = item.rating {
                    HStack(spacing: 5) {
                        HStack(spacing: 1) {
                            ForEach(0..<5) { index in
                                Image(systemName: rating / 2 >= Double(index + 1) ? "star.fill" : rating / 2 > Double(index) ? "star.leadinghalf.filled" : "star")
                                    .font(.system(size: 11)).frame(width: 12).foregroundStyle(rating / 2 > Double(index) ? Color.yellow : .secondary)
                            }
                        }
                        Text(rating, format: .number.precision(.fractionLength(1))).font(.system(size: 13)).foregroundStyle(.yellow)
                    }.frame(height: 18).accessibilityElement(children: .ignore).accessibilityLabel("TMDB \(rating.formatted(.number.precision(.fractionLength(1))))")
                }
                Text(item.overview.isEmpty ? " " : item.overview).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2).lineSpacing(2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
        }.padding(8).frame(height: 136)
            .background(.white.opacity(colorScheme == .dark ? 0.10 : 0.54), in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(colorScheme == .dark ? 0.07 : 0.45), lineWidth: 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}
private struct DiscoverSearchPersonRow: View {
    let person: TMDBCatalog.SearchPerson
    var body: some View {
        VStack(spacing: 0) {
            PosterImage(url: person.profile, symbol: "person.fill").frame(width: 83, height: 83).clipShape(Circle())
            Text(person.name).font(.system(size: 13)).lineLimit(1).padding(.top, 8)
            Text(L10n.text(person.department == "Acting" ? "Actor" : person.department ?? "People"))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
        }.frame(width: 83)
    }
}
private struct DiscoverSearchPersonView: View {
    let person: TMDBCatalog.SearchPerson
    @State private var items: [TMDBCatalog.Item] = []
    @State private var failed = false
    @State private var loading = true
    @State private var revision = 0
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                PosterImage(url: person.profile, symbol: "person.fill").frame(width: 116, height: 116).clipShape(Circle()).padding(.top, 20)
                Text(person.name).font(.title.bold())
                if let department = person.department { Text(L10n.text(department == "Acting" ? "Actor" : department)).foregroundStyle(.secondary) }
                if loading { ProgressView().padding(30) }
                if failed { Button(L10n.text("Try Again")) { revision += 1 } }
                ForEach(items, id: \.key) { item in NavigationLink(value: item) { DiscoverSearchRow(item: item) }.buttonStyle(.plain) }
            }.padding(.horizontal, 16).padding(.bottom, 30)
        }.background { DiscoverSearchAtmosphere() }.navigationTitle(L10n.text("Filmography"))
            #if !os(macOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
            .task(id: revision) {
                loading = true; failed = false
                do { let page = try await TMDBCatalog.search(personID: person.id); try Task.checkCancellation(); items = page.items; loading = false }
                catch { if !Task.isCancelled { failed = true; loading = false } }
            }
    }
}
/// Keep Duo's side display clear while allowing glass shadows through the vertical safe areas.
private struct DiscoverSearchHorizontalClip: Shape {
    func path(in rect: CGRect) -> Path { Path(CGRect(x: rect.minX, y: rect.minY - 1000, width: rect.width, height: rect.height + 2000)) }
}
struct DiscoverSearchAtmosphere: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shifted = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                (scheme == .dark ? Color(red: 0.22, green: 0.19, blue: 0.26) : Color(red: 0.96, green: 0.95, blue: 0.99))
                Ellipse().fill(Color(red: 0.60, green: 0.52, blue: 0.77).opacity(scheme == .dark ? 0.18 : 0.22))
                    .frame(width: geometry.size.width * 1.8, height: geometry.size.height * 0.95)
                    .blur(radius: 90).offset(x: shifted ? 70 : -90, y: shifted ? -170 : -50)
                Ellipse().fill(Color(red: 1, green: 0.62, blue: 0.70).opacity(scheme == .dark ? 0.10 : 0.20))
                    .frame(width: geometry.size.width * 1.3, height: geometry.size.height * 0.8)
                    .blur(radius: 100).offset(x: shifted ? -100 : 90, y: shifted ? 110 : 270)
            }
        }.ignoresSafeArea().allowsHitTesting(false)
            .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 16).repeatForever(autoreverses: true)) { shifted = true } }
    }
}
struct DiscoverSearchRequest: Equatable {
    let keyword: String
    let feed: TMDBCatalog.SearchFeed
    let filter: TMDBCatalog.Filter?
    let revision: Int
}
struct DiscoverSearchGroup {
    var items: [TMDBCatalog.Item] = []
    var people: [TMDBCatalog.SearchPerson] = []
    var page = 0
    var totalPages = 0
    var loadingMore = false
    var failedMore = false
    var count: Int { items.count + people.count }
    var hasMore: Bool { page < totalPages }
}
@MainActor @Observable final class DiscoverSearchModel {
    var groups: [TMDBCatalog.SearchKind: DiscoverSearchGroup] = [:]
    var loading = false
    var failed = false
    var history: [String] = UserDefaults.standard.stringArray(forKey: "discover.search.keywords") ?? []
    var opened: [TMDBCatalog.Item] = (UserDefaults.standard.data(forKey: "discover.search.opened").flatMap { try? JSONDecoder().decode([TMDBCatalog.Item].self, from: $0) }) ?? []
    private var generation = 0
    var isEmpty: Bool { groups.values.allSatisfy { $0.count == 0 } }
    func load(_ request: DiscoverSearchRequest) async {
        generation += 1
        let token = generation
        loading = true; failed = false; groups = [:]
        guard request.filter?.isValid != false else { loading = false; return }
        do {
            if !request.keyword.isEmpty { try await Task.sleep(for: .milliseconds(350)) }
            try Task.checkCancellation()
            let kinds = request.filter.map { [$0.kind] } ?? TMDBCatalog.SearchKind.allCases
            await withTaskGroup(of: (TMDBCatalog.SearchKind, TMDBCatalog.SearchPage?).self) { group in
                for kind in kinds {
                    group.addTask {
                        do { return (kind, try await TMDBCatalog.search(query: request.keyword, kind: kind, feed: request.feed, filter: request.filter)) }
                        catch { return (kind, nil) }
                    }
                }
                for await (kind, page) in group {
                    guard token == generation, !Task.isCancelled else { continue }
                    if let page { groups[kind] = DiscoverSearchGroup(items: page.items, people: page.people, page: page.page, totalPages: page.totalPages) }
                    else { failed = true }
                }
            }
            guard token == generation, !Task.isCancelled else { return }
            loading = false
        } catch { /* A new input owns the state after cancellation. */ }
    }
    func more(_ kind: TMDBCatalog.SearchKind, request: DiscoverSearchRequest) async {
        guard var group = groups[kind], group.hasMore, !group.loadingMore else { return }
        let token = generation
        group.loadingMore = true; group.failedMore = false; groups[kind] = group
        do {
            let page = try await TMDBCatalog.search(query: request.keyword, kind: kind, page: group.page + 1, feed: request.feed, filter: request.filter)
            guard token == generation, !Task.isCancelled else { return }
            var titleKeys = Set(group.items.map(\.key)), peopleKeys = Set(group.people.map(\.id))
            group.items += page.items.filter { titleKeys.insert($0.key).inserted }
            group.people += page.people.filter { peopleKeys.insert($0.id).inserted }
            group.page = page.page; group.totalPages = page.totalPages; group.loadingMore = false; groups[kind] = group
        } catch {
            guard token == generation else { return }
            group.loadingMore = false; group.failedMore = true; groups[kind] = group
        }
    }
    func remember(_ keyword: String) {
        guard !keyword.isEmpty else { return }
        history.removeAll { $0.caseInsensitiveCompare(keyword) == .orderedSame }; history.insert(String(keyword.prefix(100)), at: 0)
        history = Array(history.prefix(12)); UserDefaults.standard.set(history, forKey: "discover.search.keywords")
    }
    func clearHistory() { history = []; UserDefaults.standard.removeObject(forKey: "discover.search.keywords") }
    func rememberOpened(_ item: TMDBCatalog.Item) {
        opened.removeAll { $0.key == item.key }; opened.insert(item, at: 0); opened = Array(opened.prefix(12)); saveOpened()
    }
    func clearOpened() { opened = []; saveOpened() }
    func removeOpened(_ item: TMDBCatalog.Item) { opened.removeAll { $0.key == item.key }; saveOpened() }
    private func saveOpened() { UserDefaults.standard.set(try? JSONEncoder().encode(opened), forKey: "discover.search.opened") }
}
extension TMDBCatalog.SearchKind {
    var title: String { L10n.text(self == .movie ? "Movies" : self == .tv ? "Catalog Series" : "People") }
}
extension TMDBCatalog.SearchFeed {
    var title: String { L10n.text(self == .day ? "Trending Today" : self == .week ? "Trending This Week" : "Popular") }
}

#if os(iOS)
import UIKit
/// Do not submit marked text while a Chinese/Japanese IME is still composing.
private struct DiscoverSearchInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.tintColor = .label
        field.placeholder = L10n.text("Search")
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.accessibilityIdentifier = "discover.search.input"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.markedTextRange == nil && field.text != text { field.text = text }
        if !focused && field.isFirstResponder {
            field.window?.endEditing(true)
        } else if focused && !field.isFirstResponder {
            DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
                guard let field, let coordinator, coordinator.parent.focused, field.window != nil else { return }
                field.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: DiscoverSearchInput
        init(_ parent: DiscoverSearchInput) { self.parent = parent }
        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            parent.text = String((field.text ?? "").prefix(100))
        }
        func textFieldDidBeginEditing(_ field: UITextField) { if !parent.focused { parent.focused = true } }
        func textFieldDidEndEditing(_ field: UITextField) { changed(field); if parent.focused { parent.focused = false } }
        func textFieldShouldReturn(_ field: UITextField) -> Bool { changed(field); field.window?.endEditing(true); parent.submit(); return true }
    }
}
#else
private struct DiscoverSearchInput: View {
    @Binding var text: String
    @Binding var focused: Bool
    let submit: () -> Void
    @FocusState private var hasFocus: Bool
    var body: some View {
        TextField(L10n.text("Search"), text: $text)
            .font(.system(size: 16)).focused($hasFocus).autocorrectionDisabled().onSubmit(submit)
            .onChange(of: focused) { _, value in hasFocus = value }
            .onChange(of: hasFocus) { _, value in focused = value }
            .accessibilityIdentifier("discover.search.input")
    }
}
#endif
