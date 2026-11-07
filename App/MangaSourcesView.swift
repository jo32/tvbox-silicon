import SwiftUI
import TVCore

/// Installed comic sources, the source lists they come from, and adding one by its address.
struct MangaSourcesView: View {
    @State private var store = MangaStore.shared
    @State private var address = ""
    @State private var repository = ""
    @State private var working = false
    @State private var message: String?

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        listBody
        #endif
    }

    #if os(tvOS)
    /// Apple TV: a Settings subpage like the others under Settings, with glass rows rather than the system's list.
    private var tvBody: some View {
        SettingsPage(title: L10n.text("Comic Sources"), symbol: "books.vertical",
                     subtitle: L10n.text("Comic sources are Venera scripts (venera-configs). Each one reads a website; the website's content is its own.")) {
            SettingsGroup(title: L10n.text("Installed"),
                          footer: store.sources.isEmpty ? L10n.text("No comic sources yet. Open a comic source list in Subscriptions and install the sources you want.") : nil) {
                ForEach(store.sources) { source in
                    RouteLink { MangaSourceSettingsView(key: source.key) } label: {
                        TVSettingsRowLabel(title: source.name, detail: source.version.isEmpty ? nil : source.version,
                                           value: MangaSourceData.shared.isSignedIn(source.key) ? L10n.text("Signed In") : nil, chevron: true)
                    }
                    .glassRow()
                }
            }
            if !store.repositories.isEmpty {
                SettingsGroup(title: L10n.text("Install From")) {
                    ForEach(store.repositories, id: \.self) { url in
                        TVSettingsLink(title: MangaSources.title(of: url)) { MangaRepositoryView(url: url) }
                    }
                }
            }
            SettingsGroup(title: L10n.text("Add by Address"), footer: message) {
                // A plain field: an alert or sheet on a pushed page hangs tvOS 27 (#272).
                TextField(L10n.text("Source address (.js)"), text: $address)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(installAddress)
                    .padding(.horizontal, 12)
                TVSettingsAction(title: L10n.text("Install"), busy: working, action: installAddress)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .onAppear { store.reloadSources() }
    }
    #endif

    private var listBody: some View {
        List {
            Section {
                if store.sources.isEmpty {
                    Text(L10n.text("No comic sources yet. Open a comic source list in Subscriptions and install the sources you want.")).foregroundStyle(.secondary)
                }
                ForEach(store.sources) { source in
                    RouteLink { MangaSourceSettingsView(key: source.key) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(source.version.isEmpty ? source.key : "\(source.key) · \(source.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if MangaSourceData.shared.isSignedIn(source.key) {
                                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
                                    .accessibilityLabel(L10n.text("Signed In"))
                            }
                        }
                    }
                    #if !os(tvOS)
                    .contextMenu { Button(L10n.text("Remove"), role: .destructive) { Task { await store.remove(source.key) } } }
                    #endif
                }
                #if !os(tvOS)
                .onDelete { offsets in
                    let keys = offsets.map { store.sources[$0].key }
                    Task { for key in keys { await store.remove(key) } }
                }
                .onMove { store.move($0, $1) }
                #endif
            } header: { Text(L10n.text("Installed")) } footer: {
                #if !os(tvOS)
                if store.sources.count > 1 { Text(L10n.text("Drag to reorder. Search lists sources in this order.")) }
                #endif
            }

            if !store.repositories.isEmpty {
                Section {
                    ForEach(store.repositories, id: \.self) { url in
                        RouteLink { MangaRepositoryView(url: url) } label: { Text(MangaSources.title(of: url)) }
                    }
                } header: { Text(L10n.text("Install From")) } footer: {
                    Text(L10n.text("Comic sources are Venera scripts (venera-configs). Each one reads a website; the website's content is its own."))
                }
            }

            Section {
                TextField(L10n.text("Source address (.js)"), text: $address)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                    .onSubmit(installAddress)
                Button(action: installAddress) {
                    HStack { Text(L10n.text("Install")); if working { Spacer(); ProgressView() } }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || working)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text(L10n.text("Add by Address")) }
        }
        .screenTitle(L10n.text("Comic Sources"))
        .onAppear { store.reloadSources() }
    }

    private func addRepository() {
        guard let url = URL(string: repository.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            message = L10n.text("Enter a web address that starts with http:// or https://."); return
        }
        store.addRepository(url)
        repository = ""
    }

    private func installAddress() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            message = L10n.text("Enter a web address that starts with http:// or https://."); return
        }
        working = true; message = nil
        Task {
            defer { working = false }
            do {
                try await store.install(url)
                message = L10n.text("Installed."); address = ""
            } catch { message = error.mangaMessage }
        }
    }
}

/// The sources one list offers, each with Install, Update or Installed.
struct MangaRepositoryView: View {
    let url: URL
    @State private var store = MangaStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [MangaRepositoryEntry]?
    @State private var failure: String?
    @State private var busy: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var filter = ""

    private var shown: [MangaRepositoryEntry] {
        let all = entries ?? []
        guard !filter.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.description.localizedCaseInsensitiveContains(filter) || ($0.key ?? "").localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        listBody
        #endif
    }

    #if os(tvOS)
    /// Apple TV: every source as a glass row; selecting one installs or updates it.
    private var tvBody: some View {
        TVSettingsSubpage(symbol: "books.vertical", title: MangaSources.title(of: url),
                          subtitle: entries.map { L10n.text("%lld sources", $0.count) }) {
            if let entries, !entries.isEmpty {
                SettingsGroup { ForEach(entries) { tvRow($0) } }
                SettingsGroup {
                    TVSettingsAction(title: L10n.text("Remove Source List"), destructive: true) { store.removeRepository(url); dismiss() }
                }
            } else if entries != nil {
                EmptyResults(symbol: "tray", title: L10n.text("This list has no sources."))
            } else if let failure {
                EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure, action: L10n.text("Try Again")) {
                    Task { await load() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .task { if entries == nil { await load() } }
    }

    private func tvRow(_ entry: MangaRepositoryEntry) -> some View {
        let installed = entry.key.flatMap { key in store.sources.first { $0.key == key } } != nil
        let update = MangaSources.shared.hasUpdate(entry)
        let working = busy.contains(entry.id)
        let error = errors[entry.id]
        let status = update ? L10n.text("Update") : installed ? L10n.text("Installed") : L10n.text("Install")
        let symbol = update ? "arrow.triangle.2.circlepath" : installed ? "checkmark" : "arrow.down.circle"
        let detail = error ?? [entry.version, entry.description].filter { !$0.isEmpty }.joined(separator: " · ")
        return Button { if !installed || update { install(entry) } } label: {
            TVSettingsRowLabel(title: entry.name, detail: detail.isEmpty ? nil : detail, value: working ? nil : status,
                               warning: error != nil, busy: working) {
                if !working {
                    Image(systemName: symbol).font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(installed && !update ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                }
            }
        }
        .glassRow()
        .accessibilityValue(status)
    }
    #endif

    private var listBody: some View {
        Group {
            if let entries, !entries.isEmpty {
                List {
                    ForEach(shown) { entry in row(entry) }
                    Section {
                        Button(L10n.text("Remove Source List"), role: .destructive) { store.removeRepository(url); dismiss() }
                    }
                }
                    #if !os(tvOS)
                    .searchable(text: $filter, prompt: Text(L10n.text("Filter sources")))
                    #endif
            } else if entries != nil {
                EmptyResults(symbol: "tray", title: L10n.text("This list has no sources."))
            } else if let failure {
                EmptyResults(symbol: "exclamationmark.triangle", title: L10n.text("Unable to Load"), message: failure, action: L10n.text("Try Again")) {
                    Task { await load() }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .screenTitle(MangaSources.title(of: url))
        .task { if entries == nil { await load() } }
    }

    private func row(_ entry: MangaRepositoryEntry) -> some View {
        let installed = entry.key.flatMap { key in store.sources.first { $0.key == key } }
        let update = MangaSources.shared.hasUpdate(entry)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.semibold))
                    if !entry.version.isEmpty { Text(entry.version).font(.caption).foregroundStyle(.secondary) }
                }
                if !entry.description.isEmpty { Text(entry.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                if let error = errors[entry.id] { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            }
            Spacer(minLength: 8)
            if busy.contains(entry.id) {
                ProgressView()
            } else if installed != nil, !update {
                Label(L10n.text("Installed"), systemImage: "checkmark").font(.callout).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            } else {
                Button(update ? L10n.text("Update") : L10n.text("Install")) { install(entry) }
                    #if os(tvOS)
                    .buttonStyle(.bordered)
                    #else
                    .buttonStyle(.borderedProminent).appControlSize(.small)
                    #endif
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func install(_ entry: MangaRepositoryEntry) {
        busy.insert(entry.id); errors[entry.id] = nil
        Task {
            defer { busy.remove(entry.id) }
            do { try await store.install(entry.address) }
            catch { errors[entry.id] = error.mangaMessage }
        }
    }

    private func load() async {
        failure = nil
        do { entries = try await MangaSources.shared.entries(of: url) }
        catch { failure = error.mangaMessage }
    }
}

/// One source: its settings, its account, and removing it.
struct MangaSourceSettingsView: View {
    let key: String
    @State private var store = MangaStore.shared
    @State private var info: MangaSourceInfo?
    @State private var failure: String?
    @State private var signedIn = false
    @State private var account = ""
    @State private var password = ""
    @State private var cookies: [String] = []
    @State private var working = false
    @State private var message: String?
    @State private var revision = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        listBody
        #endif
    }

    #if os(tvOS)
    /// Apple TV: the source's settings, account and removal as glass rows; choices step through on each press.
    private var tvBody: some View {
        let source = store.sources.first { $0.key == key }
        return TVSettingsSubpage(symbol: "book", title: store.name(of: key),
                                 subtitle: source.map { $0.version.isEmpty ? $0.key : L10n.text("Version %@", $0.version) }) {
            if let info {
                if !info.settings.isEmpty {
                    SettingsGroup(title: L10n.text("Settings")) {
                        ForEach(info.settings, id: \.key) { setting in tvSettingRow(setting, info: info) }
                    }
                }
                if info.canSignIn || !info.cookieFields.isEmpty { tvAccount(info) }
            } else if let failure {
                SettingsGroup(footer: failure) { EmptyView() }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            SettingsGroup(footer: message ?? source?.origin?.absoluteString) {
                TVSettingsAction(title: L10n.text("Remove Source"), destructive: true) { Task { await store.remove(key); dismiss() } }
            }
        }
        .task(id: revision) { await loadInfo() }
    }

    @ViewBuilder private func tvSettingRow(_ setting: MangaSourceInfo.Setting, info: MangaSourceInfo) -> some View {
        let title = info.text(setting.title)
        let saved = MangaSourceData.shared.setting(key, setting.key)
        switch setting.type {
        case "select":
            let current = (saved as? String) ?? (saved.map { "\($0)" }) ?? setting.defaultValue ?? setting.options.first ?? ""
            let index = setting.options.firstIndex(of: current) ?? 0
            let shown = info.text(setting.optionTexts.indices.contains(index) ? setting.optionTexts[index] : current)
            TVSettingsAction(title: title, value: shown) {
                guard !setting.options.isEmpty else { return }
                change(setting.key, setting.options[(index + 1) % setting.options.count])
            }
        case "switch":
            TVSettingsToggle(title: title, isOn: Binding(
                get: { (saved as? Bool) ?? (setting.defaultValue.map { $0 == "true" || $0 == "1" }) ?? false },
                set: { change(setting.key, $0) }))
        case "callback":
            TVSettingsAction(title: title) {
                Task {
                    do { try await MangaRuntime.shared.runSettingCallback(key, setting: setting.key) }
                    catch { message = error.mangaMessage }
                }
            }
        default:
            MangaSettingField(title: title, value: (saved as? String) ?? (saved.map { "\($0)" }) ?? setting.defaultValue ?? "") { change(setting.key, $0) }
        }
    }

    @ViewBuilder private func tvAccount(_ info: MangaSourceInfo) -> some View {
        SettingsGroup(title: L10n.text("Account"),
                      footer: L10n.text("Your account and password are sent only to this source's website, and kept on this device.")) {
            if signedIn {
                SettingsRow(symbol: "person.crop.circle", title: L10n.text("Signed In")) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
                }
                TVSettingsAction(title: L10n.text("Sign Out"), destructive: true) {
                    Task { await MangaRuntime.shared.signOut(key); signedIn = false; message = nil }
                }
            } else {
                if info.canSignIn {
                    TextField(L10n.text("Account"), text: $account)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, 12)
                    SecureField(L10n.text("Password"), text: $password).textContentType(.password)
                        .padding(.horizontal, 12)
                    TVSettingsAction(title: L10n.text("Sign In"), busy: working) {
                        signIn { try await MangaRuntime.shared.signIn(key, account: account, password: password) }
                    }
                    .disabled(account.isEmpty || password.isEmpty || working)
                }
                if !info.cookieFields.isEmpty {
                    ForEach(Array(info.cookieFields.enumerated()), id: \.offset) { index, field in
                        TextField(field, text: Binding(get: { cookies.indices.contains(index) ? cookies[index] : "" },
                                                       set: { if cookies.indices.contains(index) { cookies[index] = $0 } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(.horizontal, 12)
                    }
                    TVSettingsAction(title: L10n.text("Sign In with Cookies"), busy: working) {
                        signIn { try await MangaRuntime.shared.signIn(key, cookies: cookies) }
                    }
                    .disabled(cookies.contains(where: \.isEmpty) || working)
                }
            }
        }
    }
    #endif

    private var listBody: some View {
        List {
            if let info {
                if !info.settings.isEmpty {
                    Section(L10n.text("Settings")) {
                        ForEach(info.settings, id: \.key) { setting in settingRow(setting, info: info) }
                    }
                }
                if info.canSignIn || !info.cookieFields.isEmpty { accountSection(info) }
            } else if let failure {
                Section { Text(failure).foregroundStyle(.secondary) }
            } else {
                Section { ProgressView() }
            }
            Section {
                if let source = store.sources.first(where: { $0.key == key }) {
                    LabeledContent(L10n.text("Version"), value: source.version.isEmpty ? "–" : source.version)
                    if let origin = source.origin { LabeledContent(L10n.text("Address"), value: origin.absoluteString).lineLimit(1) }
                }
                Button(L10n.text("Remove Source"), role: .destructive) {
                    Task { await store.remove(key); dismiss() }
                }
            }
            if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
        }
        .screenTitle(store.name(of: key))
        .task(id: revision) { await loadInfo() }
    }

    private func loadInfo() async {
        do {
            info = try await MangaRuntime.shared.info(key)
            signedIn = MangaSourceData.shared.isSignedIn(key)
            if cookies.count != info?.cookieFields.count { cookies = Array(repeating: "", count: info?.cookieFields.count ?? 0) }
        } catch { failure = error.mangaMessage }
    }

    @ViewBuilder private func settingRow(_ setting: MangaSourceInfo.Setting, info: MangaSourceInfo) -> some View {
        let title = info.text(setting.title)
        let saved = MangaSourceData.shared.setting(key, setting.key)
        switch setting.type {
        case "select":
            Picker(title, selection: Binding(
                get: { (saved as? String) ?? (saved.map { "\($0)" }) ?? setting.defaultValue ?? setting.options.first ?? "" },
                set: { change(setting.key, $0) })) {
                ForEach(Array(setting.options.enumerated()), id: \.offset) { index, value in
                    Text(info.text(setting.optionTexts.indices.contains(index) ? setting.optionTexts[index] : value)).tag(value)
                }
            }
        case "switch":
            Toggle(title, isOn: Binding(
                get: { (saved as? Bool) ?? (setting.defaultValue.map { $0 == "true" || $0 == "1" }) ?? false },
                set: { change(setting.key, $0) }))
        case "callback":
            Button(title) {
                Task {
                    do { try await MangaRuntime.shared.runSettingCallback(key, setting: setting.key) }
                    catch { message = error.mangaMessage }
                }
            }
        default:
            MangaSettingField(title: title, value: (saved as? String) ?? (saved.map { "\($0)" }) ?? setting.defaultValue ?? "") { change(setting.key, $0) }
        }
    }

    private func change(_ name: String, _ value: Any) {
        MangaSourceData.shared.setSetting(key, name, value)
        // Sources read some settings once, when they load (a site's address, a language): start them again.
        Task { await MangaRuntime.shared.reset(key); revision += 1 }
    }

    @ViewBuilder private func accountSection(_ info: MangaSourceInfo) -> some View {
        Section {
            if signedIn {
                Label(L10n.text("Signed In"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button(L10n.text("Sign Out"), role: .destructive) {
                    Task { await MangaRuntime.shared.signOut(key); signedIn = false; message = nil }
                }
            } else {
                if info.canSignIn {
                    TextField(L10n.text("Account"), text: $account)
                        .textContentType(.username)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    SecureField(L10n.text("Password"), text: $password).textContentType(.password)
                    Button { signIn { try await MangaRuntime.shared.signIn(key, account: account, password: password) } } label: {
                        HStack { Text(L10n.text("Sign In")); if working { Spacer(); ProgressView() } }
                    }
                    .disabled(account.isEmpty || password.isEmpty || working)
                }
                if !info.cookieFields.isEmpty {
                    ForEach(Array(info.cookieFields.enumerated()), id: \.offset) { index, field in
                        TextField(field, text: Binding(get: { cookies.indices.contains(index) ? cookies[index] : "" },
                                                       set: { if cookies.indices.contains(index) { cookies[index] = $0 } }))
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                    }
                    Button(L10n.text("Sign In with Cookies")) { signIn { try await MangaRuntime.shared.signIn(key, cookies: cookies) } }
                        .disabled(cookies.contains(where: \.isEmpty) || working)
                }
                #if !os(tvOS)
                if let page = info.signInPage, let url = URL(string: page) {
                    Link(destination: url) { Label(L10n.text("Open the Website to Sign Up"), systemImage: "safari") }
                }
                #endif
            }
        } header: { Text(L10n.text("Account")) } footer: {
            Text(L10n.text("Your account and password are sent only to this source's website, and kept on this device."))
        }
    }

    private func signIn(_ action: @escaping () async throws -> Void) {
        working = true; message = nil
        Task {
            defer { working = false }
            do {
                try await action()
                signedIn = true; password = ""
                message = L10n.text("Signed in.")
            } catch { message = error.mangaMessage }
        }
    }
}

/// A text setting, saved when editing ends rather than on every key.
private struct MangaSettingField: View {
    let title: String
    let value: String
    let save: (String) -> Void
    @State private var draft: String?
    var body: some View {
        #if os(tvOS)
        // The title over a plain field: a focused tvOS field draws its own white platter.
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 25, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 28)
            TextField(title, text: Binding(get: { draft ?? value }, set: { draft = $0 }))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { if let draft, draft != value { save(draft) } }
                .padding(.horizontal, 12)
        }
        #else
        LabeledContent(title) {
            TextField(title, text: Binding(get: { draft ?? value }, set: { draft = $0 }))
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                #endif
                .onSubmit { if let draft, draft != value { save(draft) } }
        }
        #endif
    }
}

extension MangaSources {
    /// A source list's name in Settings: Venera's by name, any other by its host.
    static func title(of url: URL) -> String {
        url == veneraRepository ? L10n.text("Venera Source List") : (url.host() ?? url.absoluteString)
    }
}
