import SwiftUI
import TVCore

/// Settings › Subtitle Sources (#576 M2): the services subtitle search asks, each switched on or off, with the key
/// it needs; and scripts added by address. Keys go to the Keychain, never to the app's files or its logs.
struct SubtitleSourcesView: View {
    @State private var items: [SubtitleSourceItem] = []
    @State private var address = ""
    @State private var adding = false
    @State private var failure: String?
    @AppStorage(SubtitleSearchPolicy.timeLimitKey) private var timeLimit = SubtitleSearchPolicy.defaultTimeLimit

    var body: some View {
        page
            .task { await reload() }
    }

    @ViewBuilder private var page: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "captions.bubble", title: L10n.text("Subtitle Sources"), subtitle: Self.note) {
            TVSettingsSection {
                ForEach(items) { item in
                    TVSettingsLink(title: item.name, value: status(item), warning: item.enabled && missingKey(item)) { SubtitleSourcePage(item: item) }
                }
            }
            TVSettingsSection(footer: Self.timeLimitNote) {
                TVSettingsAction(title: L10n.text("Search Time Limit"), value: Self.seconds(timeLimit)) {
                    let limits = SubtitleSearchPolicy.timeLimits
                    timeLimit = limits[((limits.firstIndex(of: timeLimit) ?? 0) + 1) % limits.count]
                }
            }
            TVSettingsSection(title: L10n.text("Add a Source"), footer: failure ?? Self.addNote) {
                TVSettingsField(title: L10n.text("Script Address"), text: $address)
                TVSettingsAction(title: L10n.text("Add"), busy: adding) { add() }
                    .disabled(address.isEmpty || adding)
            }
        }
        #else
        Form {
            Section {
                ForEach(items) { item in
                    RouteLink { SubtitleSourcePage(item: item) } label: {
                        LabeledContent {
                            Text(status(item)).foregroundStyle(item.enabled && missingKey(item) ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                if !item.builtIn, let host = item.origin?.host() { Text(host).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            } footer: {
                Text(Self.note)
            }
            Section {
                Picker(L10n.text("Search Time Limit"), selection: $timeLimit) {
                    ForEach(SubtitleSearchPolicy.timeLimits, id: \.self) { Text(Self.seconds($0)).tag($0) }
                }
            } footer: {
                Text(Self.timeLimitNote)
            }
            Section {
                TextField(L10n.text("Script Address"), text: $address, prompt: Text("https://…"))
                    #if os(iOS)
                    .keyboardType(.URL).textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .onSubmit(add)
                Button { add() } label: {
                    HStack {
                        Text(L10n.text("Add"))
                        if adding { Spacer(); ProgressView().appControlSize(.small) }
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || adding)
            } header: {
                Text(L10n.text("Add a Source"))
            } footer: {
                if let failure { Text(failure).foregroundStyle(Brand.rose) } else { Text(Self.addNote) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("Subtitle Sources"))
        #endif
    }

    static let note = L10n.text("Search Online in the player's subtitle menu asks the sources that are on. Most need a free key from their site.")
    static let timeLimitNote = L10n.text("How long Search Online waits for the sources. Results show as each source answers, so a longer limit only waits longer for slow ones.")
    static func seconds(_ value: Double) -> String { L10n.text("%@ seconds", String(Int(value))) }
    static let addNote = L10n.text("A source script reaches only the sites it lists, and can't read your files or other sources' keys.")

    private func status(_ item: SubtitleSourceItem) -> String {
        guard item.enabled else { return L10n.text("Off") }
        return missingKey(item) ? L10n.text("Needs a Key") : L10n.text("On")
    }

    private func missingKey(_ item: SubtitleSourceItem) -> Bool {
        let values = SubtitleSourceKeys.values[item.id] ?? [:]
        return item.credentials.contains { $0.required && (values[$0.key] ?? "").isEmpty }
    }

    private func reload() async {
        let library = SubtitleSourceLibrary.shared
        let listed = await library.items()
        var keys: [String: [String: String]] = [:]
        for item in listed { keys[item.id] = await library.values(for: item.id) }
        SubtitleSourceKeys.values = keys
        items = listed
    }

    private func add() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            failure = L10n.text("Enter an address that starts with http:// or https://.")
            return
        }
        adding = true; failure = nil
        Task {
            do {
                try await SubtitleSourceLibrary.shared.add(address: url)
                address = ""
            } catch {
                failure = L10n.text("The source wasn't added. %@", error.localizedDescription)
            }
            adding = false
            await reload()
        }
    }
}

/// The keys read for the list, so a row can say one is missing without reading the Keychain while drawing.
@MainActor enum SubtitleSourceKeys {
    static var values: [String: [String: String]] = [:]
}

/// One source: on or off, its key, what it reaches; an added one can be removed.
struct SubtitleSourcePage: View {
    let item: SubtitleSourceItem
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var values: [String: String] = [:]
    @State private var loaded = false

    var body: some View {
        page
            .task {
                guard !loaded else { return }
                enabled = item.enabled
                values = await SubtitleSourceLibrary.shared.values(for: item.id)
                loaded = true
            }
            .onChange(of: enabled) { _, on in
                guard loaded else { return }
                Task { await SubtitleSourceLibrary.shared.setEnabled(item.id, on) }
            }
            .onChange(of: values) { _, new in
                guard loaded else { return }
                SubtitleSourceKeys.values[item.id] = new
                Task { await SubtitleSourceLibrary.shared.setValues(new, for: item.id) }
            }
    }

    private var reaches: String { L10n.text("Reaches %@.", item.domains.joined(separator: ", ")) }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    @ViewBuilder private var page: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "captions.bubble", title: item.name, subtitle: reaches) {
            TVSettingsSection {
                TVSettingsToggle(title: L10n.text("Search This Source"), isOn: $enabled)
            }
            if !item.credentials.isEmpty {
                TVSettingsSection(title: L10n.text("Account"), footer: item.credentials.compactMap(\.note).joined(separator: "\n")) {
                    ForEach(item.credentials) { field in
                        TVSettingsField(title: Self.title(field), text: binding(field.key), secret: field.secret)
                    }
                }
            }
            if !item.builtIn {
                TVSettingsSection {
                    TVSettingsAction(title: L10n.text("Remove Source"), destructive: true) { remove() }
                }
            }
        }
        #else
        Form {
            Section {
                Toggle(L10n.text("Search This Source"), isOn: $enabled)
                    .settingsSwitch()
            } footer: {
                Text(reaches)
            }
            if !item.credentials.isEmpty {
                Section {
                    ForEach(item.credentials) { field in
                        // The name on the leading edge, the value on the trailing one, as in the Settings app.
                        LabeledContent(Self.title(field)) {
                            let prompt = Text(field.required ? L10n.text("Required") : L10n.text("Optional"))
                            Group {
                                if field.secret {
                                    SecureField(Self.title(field), text: binding(field.key), prompt: prompt)
                                } else {
                                    TextField(Self.title(field), text: binding(field.key), prompt: prompt)
                                        #if os(iOS)
                                        .textInputAutocapitalization(.never)
                                        #endif
                                        .autocorrectionDisabled()
                                }
                            }
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text(L10n.text("Account"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.credentials.compactMap(\.note), id: \.self) { Text($0) }
                        if let homepage = item.homepage { Link(L10n.text("Get a Key"), destination: homepage) }
                    }
                }
            }
            if !item.builtIn {
                Section {
                    Button(L10n.text("Remove Source"), role: .destructive) { remove() }
                } footer: {
                    if let origin = item.origin { Text(origin.absoluteString) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.name)
        #endif
    }

    /// The field's name as the source gives it, in the viewer's language when it is one the app knows.
    static func title(_ field: SubtitleProviderManifest.Credential) -> String { L10n.text(field.title) }

    private func remove() {
        Task {
            await SubtitleSourceLibrary.shared.remove(item.id)
            dismiss()
        }
    }
}

#if !os(tvOS)
/// The player's Search Online sheet on iPhone, iPad and the Mac: the video's title, season and episode (editable),
/// each source's progress, and the results best first with why they rank there. Choosing one downloads it and shows it.
struct SubtitleSearchSheet: View {
    let subtitles: ExternalSubtitles
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var season = ""
    @State private var episode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.text("Title"), text: $title)
                        .onSubmit(search)
                        .autocorrectionDisabled()
                    HStack {
                        TextField(L10n.text("Season"), text: $season)
                        TextField(L10n.text("Episode"), text: $episode)
                    }
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    Button(L10n.text("Search"), action: search)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                results
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.text("Search Subtitles"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Done")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    // Value links only: a value link on a page pushed by a destination link doesn't push.
                    RouteLink { SubtitleSourcesView() } label: { Label(L10n.text("Subtitle Sources"), systemImage: "gearshape") }
                }
            }
            .routeDestinations()
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .onAppear {
            let hint = subtitles.hint
            title = hint?.title ?? ""
            season = hint?.season.map(String.init) ?? ""
            episode = hint?.episode.map(String.init) ?? ""
            if subtitles.onlineState == .idle || subtitles.onlineState == .noSources { search() }
        }
    }

    @ViewBuilder private var results: some View {
        switch subtitles.onlineState {
        case .idle:
            EmptyView()
        case .noSources:
            Section {
                Text(L10n.text("No subtitle sources are on."))
                RouteLink { SubtitleSourcesView() } label: { Text(L10n.text("Subtitle Sources")) }
            } footer: {
                Text(SubtitleSourcesView.note)
            }
        case .searching, .done:
            Section {
                ForEach(subtitles.sourceNames, id: \.id) { source in
                    LabeledContent(source.name) { status(subtitles.online.statuses[source.id]) }
                }
            }
            Section {
                if subtitles.online.candidates.isEmpty {
                    if subtitles.online.finished { Text(L10n.text("No subtitles found.")).foregroundStyle(.secondary) }
                } else {
                    ForEach(subtitles.online.candidates.prefix(60)) { candidate in
                        Button { subtitles.download(candidate); dismiss() } label: { SubtitleCandidateRow(candidate: candidate, chosen: subtitles.selected == candidate.id) }
                            .buttonStyle(.plain)
                    }
                }
            } header: {
                if !subtitles.online.candidates.isEmpty { Text(L10n.text("Results")) }
            }
        }
    }

    @ViewBuilder private func status(_ status: SubtitleSearchProgress.Status?) -> some View {
        switch status {
        case .searching?, nil: ProgressView().appControlSize(.small)
        case .found(let count)?: Text(count == 0 ? L10n.text("None") : L10n.text("%@ found", String(count))).foregroundStyle(.secondary)
        case .failed(let error)?: Text(error.localizedDescription).foregroundStyle(Brand.amber).multilineTextAlignment(.trailing).lineLimit(3)
        }
    }

    private func search() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var hint = subtitles.hint ?? SubtitleHint(title: trimmed)
        if hint.title != trimmed { hint.fileName = nil; hint.tmdbID = nil; hint.imdbID = nil }
        hint.title = trimmed
        hint.episode = Int(episode)
        hint.season = Int(season) ?? (hint.episode == nil ? nil : 1)
        subtitles.search(hint)
    }
}

/// A search result: its name, then language, source and format, then why it ranks where it does.
struct SubtitleCandidateRow: View {
    let candidate: SubtitleCandidate
    var chosen = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.title).lineLimit(2)
                Text(candidate.detail).font(.caption).foregroundStyle(.secondary)
                if !candidate.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(candidate.tags, id: \.self) { tag in
                            Text(tag).font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if chosen { Image(systemName: "checkmark").foregroundStyle(.tint) }
        }
        .contentShape(Rectangle())
    }
}
#endif

extension SubtitleCandidate {
    /// "Chinese (Simplified) · OpenSubtitles · SRT"
    var detail: String {
        var parts: [String] = []
        if !language.isEmpty { parts.append(Locale.current.localizedString(forIdentifier: language) ?? language) }
        parts.append(providerName.isEmpty ? provider : providerName)
        if let format, !format.isEmpty { parts.append(format.uppercased()) }
        return parts.joined(separator: " · ")
    }

    /// Why it ranks where it does, then what kind of subtitles they are.
    var tags: [String] {
        reasons.map(\.title) + (forced ? [L10n.text("Forced")] : []) + (hearingImpaired ? [L10n.text("SDH")] : [])
    }
}
