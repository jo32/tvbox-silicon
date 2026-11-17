import SwiftUI
import TVCore
#if !os(tvOS)
import WebKit
#endif

/// Settings › Book Sources: the subscribed Legado lists, and how many of their sources are on.
struct NovelSourcesView: View {
    @State private var store = NovelStore.shared
    @State private var refreshing = false
    @State private var adding: Set<URL> = []
    @State private var offerErrors: [URL: String] = [:]

    private let about = L10n.text("Book sources are Legado (阅读) sources. Add a list as a subscription in Settings › Subscriptions. Each source reads a website; the website's content is its own.")

    var body: some View {
        #if os(tvOS)
        SettingsPage(title: L10n.text("Book Sources"), symbol: "text.book.closed", subtitle: about) {
            SettingsGroup(title: L10n.text("Source Lists"), footer: store.lists.isEmpty ? L10n.text("No book source lists yet.") : nil) {
                ForEach(store.lists) { list in
                    TVSettingsLink(title: NovelSources.title(of: list.address), value: count(list)) { NovelListView(url: list.address) }
                }
            }
            if !store.lists.isEmpty {
                SettingsGroup {
                    TVSettingsAction(title: L10n.text("Refresh All"), busy: refreshing) { refresh() }.disabled(refreshing)
                }
            }
            if !store.offers.isEmpty {
                SettingsGroup(title: L10n.text("Lists You Can Add"), footer: offersFooter) {
                    ForEach(store.offers) { offer in
                        let added = isAdded(offer)
                        Button { if !added { add(offer) } } label: {
                            TVSettingsRowLabel(title: offer.name, detail: offerErrors[offer.address] ?? offer.address.lastPathComponent,
                                               value: added ? L10n.text("Added") : adding.contains(offer.address) ? L10n.text("Adding…") : L10n.text("Add"))
                        }
                        .glassRow()
                    }
                }
                SettingsGroup {
                    TVSettingsAction(title: L10n.text("Clear Lists You Can Add")) { store.offer([]) }
                }
            }
        }
        .onAppear { store.reloadSources() }
        #else
        List {
            Section {
                if store.lists.isEmpty { Text(L10n.text("No book source lists yet.")).foregroundStyle(.secondary) }
                ForEach(store.lists) { list in
                    RouteLink { NovelListView(url: list.address) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NovelSources.title(of: list.address)).lineLimit(1)
                                Text(L10n.text("Updated %@", list.updated.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(count(list)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .contextMenu {
                        Button(L10n.text("Remove Source List"), role: .destructive) { store.removeList(list.address) }
                    }
                }
                .onDelete { offsets in
                    let urls = offsets.map { store.lists[$0].address }
                    for url in urls { store.removeList(url) }
                }
            } header: {
                HStack {
                    Text(L10n.text("Source Lists"))
                    Spacer()
                    if refreshing { ProgressView().appControlSize(.small) }
                    else if !store.lists.isEmpty {
                        Button { refresh() } label: { Label(L10n.text("Refresh All"), systemImage: "arrow.clockwise") }
                            .font(.footnote.weight(.semibold)).textCase(nil).tint(.secondary)
                    }
                }
            } footer: { Text(about) }
            if !store.offers.isEmpty {
                Section {
                    ForEach(store.offers) { offer in offerRow(offer) }
                } header: {
                    HStack {
                        Text(L10n.text("Lists You Can Add"))
                        Spacer()
                        Button(L10n.text("Clear")) { store.offer([]) }
                            .font(.footnote.weight(.semibold)).textCase(nil).tint(.secondary)
                    }
                } footer: { Text(offersFooter) }
            }
        }
        .screenTitle(L10n.text("Book Sources"))
        .onAppear { store.reloadSources() }
        #endif
    }

    #if !os(tvOS)
    private func offerRow(_ offer: NovelSourceOffer) -> some View {
        let error = offerErrors[offer.address]
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.name).lineLimit(1)
                Text(error ?? offer.address.lastPathComponent).font(.caption).foregroundStyle(error == nil ? Color.secondary : Brand.amber).lineLimit(2)
            }
            Spacer()
            if isAdded(offer) {
                // Not a Label: a Label would move the row's separator to its title.
                (Text(Image(systemName: "checkmark")) + Text(" " + L10n.text("Added"))).font(.callout).foregroundStyle(.secondary)
            } else if adding.contains(offer.address) {
                ProgressView().appControlSize(.small)
            } else {
                Button(L10n.text("Add")) { add(offer) }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            }
        }
    }
    #endif

    private var offersFooter: String {
        L10n.text("Found on %@. Lists you add appear under Source Lists.", store.offers.first?.address.host() ?? "")
    }
    private func isAdded(_ offer: NovelSourceOffer) -> Bool { store.lists.contains { $0.address == offer.address } }
    private func add(_ offer: NovelSourceOffer) {
        guard !adding.contains(offer.address) else { return }
        adding.insert(offer.address); offerErrors[offer.address] = nil
        Task {
            defer { adding.remove(offer.address) }
            do { try await store.add(offer) } catch { offerErrors[offer.address] = error.novelMessage }
        }
    }

    /// "12 of 340 on".
    private func count(_ list: NovelSourceList) -> String {
        // Read the store first: saved lists load in the background, and an empty list never reads `enabledKeys` in the
        // filter, so the row would not update when they arrive.
        let keys = store.enabledKeys
        let sources = NovelSources.shared.sources(in: list.address)
        return L10n.text("%lld of %lld on", sources.filter { keys.contains($0.key) }.count, sources.count)
    }

    private func refresh() {
        refreshing = true
        Task { await store.refreshLists(); refreshing = false }
    }
}

/// One list's sources, each switched on or off; search and explore use the ones that are on.
struct NovelListView: View {
    let url: URL
    @State private var store = NovelStore.shared
    @State private var filter = ""
    @State private var working = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    private var sources: [NovelSource] {
        _ = store.sources
        let all = NovelSources.shared.sources(in: url)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.group.localizedCaseInsensitiveContains(filter) || $0.key.localizedCaseInsensitiveContains(filter) }
    }

    /// The sources that sign in (#970), whichever are on.
    private var signing: [NovelSource] { sources.filter(\.signsIn) }

    private func detail(_ source: NovelSource) -> String {
        var parts: [String] = []
        if !source.group.isEmpty { parts.append(source.group) }
        if !source.searchable { parts.append(L10n.text("No search")) }
        if source.explorable { parts.append(L10n.text("Explore")) }
        parts.append(URL(string: source.key)?.host() ?? source.key)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "text.book.closed", title: NovelSources.title(of: url), subtitle: L10n.text("%lld sources", sources.count)) {
            SettingsGroup(footer: message) {
                TVSettingsAction(title: L10n.text("Turn All On")) { store.setEnabled(true, sources.map(\.key)) }
                TVSettingsAction(title: L10n.text("Turn All Off")) { store.setEnabled(false, sources.map(\.key)) }
                TVSettingsAction(title: L10n.text("Refresh List"), busy: working) { refresh() }.disabled(working)
            }
            if !signing.isEmpty {
                SettingsGroup(title: L10n.text("Sign In"), footer: L10n.text("These sources can sign in to an account on their website.")) {
                    ForEach(signing) { source in TVSettingsLink(title: source.name) { NovelSignInView(source: source) } }
                }
            }
            SettingsGroup {
                ForEach(sources) { source in
                    let on = store.enabledKeys.contains(source.key)
                    Button { store.setEnabled(!on, [source.key]) } label: {
                        TVSettingsRowLabel(title: source.name, detail: detail(source), value: on ? L10n.text("On") : L10n.text("Off"))
                    }
                    .glassRow()
                }
            }
            SettingsGroup {
                TVSettingsAction(title: L10n.text("Remove Source List"), destructive: true) { store.removeList(url); dismiss() }
            }
        }
        #else
        List {
            Section {
                HStack {
                    Button(L10n.text("Turn All On")) { store.setEnabled(true, sources.map(\.key)) }
                    Spacer()
                    Button(L10n.text("Turn All Off")) { store.setEnabled(false, sources.map(\.key)) }
                }
                .buttonStyle(.borderless)
            } footer: {
                Text(L10n.text("Search asks every source that is on. Turn off the ones that never answer to make it faster.") + " "
                     + L10n.text("Turn All On and Turn All Off change only the sources the filter shows, such as one group."))
            }
            if !signing.isEmpty {
                Section {
                    ForEach(signing) { source in
                        RouteLink { NovelSignInView(source: source) } label: { Label(source.name, systemImage: "person.crop.circle") }
                    }
                } header: { Text(L10n.text("Sign In")) } footer: {
                    Text(L10n.text("These sources can sign in to an account on their website."))
                }
            }
            Section {
                ForEach(sources) { source in
                    Toggle(isOn: Binding(get: { store.enabledKeys.contains(source.key) }, set: { store.setEnabled($0, [source.key]) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).lineLimit(1)
                            Text(detail(source)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            } header: { Text(L10n.text("%lld sources", sources.count)) }
            Section {
                Button { refresh() } label: {
                    HStack { Text(L10n.text("Refresh List")); if working { Spacer(); ProgressView() } }
                }
                .disabled(working)
                Button(L10n.text("Remove Source List"), role: .destructive) { store.removeList(url); dismiss() }
            } footer: {
                if let message { Text(message) } else { Text(url.absoluteString).textSelection(.enabled) }
            }
        }
        .searchable(text: $filter, prompt: Text(L10n.text("Filter sources")))
        .screenTitle(NovelSources.title(of: url))
        #endif
    }

    private func refresh() {
        working = true; message = nil
        Task {
            defer { working = false }
            do { try await store.refresh(url); message = L10n.text("Refreshed.") }
            catch { message = error.novelMessage }
        }
    }
}

/// A Legado source's sign-in (#970), as Legado's SourceLoginDialog: its form (`loginUi`), whose values are kept as the
/// source's login info for its login script, and the form's buttons. A source with no form signs in on its website
/// (iPhone, iPad, Mac), whose cookies then go with its requests.
struct NovelSignInView: View {
    let source: NovelSource
    @State private var form: NovelSignInForm?
    @State private var values: [String: String] = [:]
    @State private var loadError: String?
    @State private var working = false
    /// What the source said (its toasts), or what went wrong.
    @State private var message: String?
    #if !os(tvOS)
    @State private var website: NovelSignInPage?
    @Environment(\.openURL) private var openURL
    #endif

    private let privacy = L10n.text("Your account and password are sent only to this book source's website, and kept on this device.")

    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "person.crop.circle", title: source.name, subtitle: URL(string: source.key)?.host() ?? source.key) {
            if let form { tvForm(form) }
            else if let loadError { SettingsGroup(footer: loadError) { TVSettingsAction(title: L10n.text("Retry")) { Task { await load() } } } }
            else { ProgressView() }
        }
        .task { await load() }
        #else
        List {
            if let form { formSections(form) }
            else if let loadError {
                Section { Button(L10n.text("Retry")) { Task { await load() } } } footer: { Text(loadError) }
            } else { HStack { Spacer(); ProgressView(); Spacer() } }
        }
        .screenTitle(source.name)
        .task { await load() }
        .sheet(item: $website) { page in
            NovelWebSignIn(source: source, page: page.url) { message = L10n.text("Signed in."); Task { await refresh() } }
        }
        #endif
    }

    private var status: String { form?.signedIn == true ? L10n.text("Signed In") : L10n.text("Not Signed In") }

    private func binding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    #if !os(tvOS)
    @ViewBuilder private func formSections(_ form: NovelSignInForm) -> some View {
        if !form.rows.isEmpty {
            Section {
                ForEach(Array(form.rows.enumerated()), id: \.offset) { _, row in field(row) }
            } header: { Text(status) } footer: {
                // What the source said goes here, by the fields, where the keyboard leaves it in view.
                VStack(alignment: .leading, spacing: 6) {
                    if let message { Text(message).foregroundStyle(.primary) }
                    Text(privacy)
                }
            }
            Section {
                Button { signIn() } label: { HStack { Text(L10n.text("Sign In")); if working { Spacer(); ProgressView() } } }
                    .disabled(working)
                if form.signedIn { Button(L10n.text("Sign Out"), role: .destructive) { signOut() }.disabled(working) }
            }
        } else if let page = form.web.flatMap(URL.init(string:)) {
            Section {
                Button { website = NovelSignInPage(url: page) } label: { Label(L10n.text("Sign In on the Website"), systemImage: "safari") }
                if form.signedIn { Button(L10n.text("Sign Out"), role: .destructive) { signOut() }.disabled(working) }
            } header: { Text(status) } footer: {
                Text([message, L10n.text("Sign in on the page, then tap Done. This source then reads the website as you.")].compactMap { $0 }.joined(separator: "\n"))
            }
        } else {
            Section { Text(L10n.text("This source has nothing to fill in to sign in.")).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func field(_ row: NovelSignInForm.Field) -> some View {
        switch row.type {
        case "password":
            SecureField(row.name, text: binding(row.name))
        case "select", "toggle":
            Picker(row.name, selection: binding(row.name)) {
                ForEach(row.chars, id: \.self) { Text($0).tag($0) }
            }
            .onChange(of: values[row.name]) { old, new in
                // A toggle's script runs when it changes, as a tap on it does in Legado.
                if row.type == "toggle", old != nil, old != new, let action = row.action { press(action) }
            }
        case "button":
            Button(row.name) { if let action = row.action { press(action) } }.disabled(working || row.action == nil)
        case "label":
            Text(row.name).font(.footnote).foregroundStyle(.secondary)
        default:
            TextField(row.name, text: binding(row.name))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        }
    }
    #else
    @ViewBuilder private func tvForm(_ form: NovelSignInForm) -> some View {
        if !form.rows.isEmpty {
            SettingsGroup(title: status, footer: privacy) {
                ForEach(Array(form.rows.enumerated()), id: \.offset) { _, row in
                    switch row.type {
                    case "text", "password":
                        TVSettingsField(title: row.name, text: binding(row.name), secret: row.type == "password")
                    case "select", "toggle":
                        // Each press moves to the next choice, as Legado's toggle does.
                        TVSettingsAction(title: row.name, value: values[row.name] ?? "") {
                            guard !row.chars.isEmpty else { return }
                            let at = row.chars.firstIndex(of: values[row.name] ?? "") ?? -1
                            values[row.name] = row.chars[(at + 1) % row.chars.count]
                            if row.type == "toggle", let action = row.action { press(action) }
                        }
                    case "button":
                        TVSettingsAction(title: row.name) { if let action = row.action { press(action) } }.disabled(working || row.action == nil)
                    default:
                        Text(row.name).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 28)
                    }
                }
            }
            SettingsGroup(footer: message) {
                TVSettingsAction(title: L10n.text("Sign In"), busy: working) { signIn() }.disabled(working)
                if form.signedIn { TVSettingsAction(title: L10n.text("Sign Out"), destructive: true) { signOut() }.disabled(working) }
            }
        } else {
            SettingsGroup(title: status, footer: form.web != nil ? L10n.text("This source signs in on its website, which Apple TV can't open.")
                                                              : L10n.text("This source has nothing to fill in to sign in.")) {
                if form.signedIn { TVSettingsAction(title: L10n.text("Sign Out"), destructive: true) { signOut() }.disabled(working) }
            }
        }
    }
    #endif

    private func load() async {
        loadError = nil
        do {
            let shown = try await NovelRuntime.shared.signInForm(source)
            values = shown.values; form = shown
        } catch { loadError = error.novelMessage }
    }

    /// The signed-in state again, keeping what was typed.
    private func refresh() async {
        if let shown = try? await NovelRuntime.shared.signInForm(source) { form = shown }
    }

    private func signIn() {
        let typed = values
        run(done: L10n.text("Signed in.")) { try await NovelRuntime.shared.signIn(source, values: typed) }
    }

    private func press(_ action: String) {
        let typed = values
        run(done: nil) { try await NovelRuntime.shared.signInAction(source, values: typed, action: action) }
    }

    private func signOut() {
        working = true; message = nil
        Task {
            defer { working = false }
            do { try await NovelRuntime.shared.signOut(source); await load() } catch { message = error.novelMessage }
        }
    }

    private func run(done: String?, _ work: @escaping () async throws -> NovelSignInOutcome) {
        working = true; message = nil
        Task {
            defer { working = false }
            do {
                let outcome = try await work()
                if let changed = outcome.values { values.merge(changed) { $1 } }
                #if !os(tvOS)
                if let open = outcome.open, let url = URL(string: open) { openURL(url) }
                #endif
                message = outcome.said.isEmpty ? done : outcome.said.joined(separator: "\n")
                if done != nil { await refresh() }
            } catch { message = error.novelMessage }
        }
    }
}

#if !os(tvOS)
private struct NovelSignInPage: Identifiable { let url: URL; var id: String { url.absoluteString } }

/// A source's website in a sheet, to sign in on; Done keeps the site's cookies for the source's requests.
private struct NovelWebSignIn: View {
    let source: NovelSource
    let page: URL
    let signedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            NovelSignInBrowser(webView: webView, page: page)
                .overlay(alignment: .bottom) { if let failure { Text(failure).font(.footnote).padding(10).background(.regularMaterial, in: Capsule()).padding() } }
                .navigationTitle(L10n.text("Sign In to %@", source.name))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { Task { await keep() } } }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 720, minHeight: 600, idealHeight: 760)
        #endif
    }

    /// The cookies of the page's site (any of its subdomains), as one Cookie header.
    private func keep() async {
        let host = page.host()?.lowercased() ?? ""
        let site = host.split(separator: ".").suffix(2).joined(separator: ".")
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == site || domain.hasSuffix("." + site)
        }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard !header.isEmpty else { failure = L10n.text("Not signed in yet."); return }
        do {
            try await NovelRuntime.shared.keepSignInCookies(source, page: page.absoluteString, cookies: header)
            signedIn(); dismiss()
        } catch { failure = error.novelMessage }
    }
}

#if os(iOS)
private typealias NovelBrowserRepresentable = UIViewRepresentable
#else
private typealias NovelBrowserRepresentable = NSViewRepresentable
#endif

private struct NovelSignInBrowser: NovelBrowserRepresentable {
    let webView: WKWebView
    let page: URL
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { make() }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { make() }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #endif
    private func make() -> WKWebView {
        // As the source's own requests: a phone's browser, so the site serves the pages the source reads.
        webView.customUserAgent = NovelRuntime.userAgent
        webView.load(URLRequest(url: page))
        return webView
    }
}
#endif
