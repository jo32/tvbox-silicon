import ImageIO
import SwiftUI
import TVCore

/// Settings › Live Plugins: live platforms added as AngelLive plugins. A source (an index address, an
/// `angellive://install-source` link or a short key from plugins.carsonn.works) lists plugins; installed ones are
/// platforms in the Live tab beside the built-in ones.
struct LivePluginsView: View {
    /// A source to open at once (a `yingxia://install-source` link).
    var initialSource: String? = nil
    @State private var installed = LivePlugins.shared.installed
    @State private var sources = LivePlugins.shared.sources
    @State private var address = ""
    @State private var adding = false
    @State private var failure: String?
    /// The source just added, its plugins listed for installing.
    @State private var offered: Offer?
    @State private var updates: [String: LivePlugins.Entry] = [:]
    @State private var updating = false

    struct Offer: Equatable { var address: URL; var name: String; var entries: [LivePlugins.Entry] }

    static let note = L10n.text("Live plugins add platforms to Live TV, such as Huya, Douyu, Twitch and YouTube. They use the AngelLive plugin format: add a source by its address, its install link, or its short key.")
    static let addNote = L10n.text("A plugin's scripts run inside Yingxia and reach only the internet. Add sources you trust.")

    var body: some View {
        page
            .task {
                if let initialSource, offered == nil { address = initialSource; add() }
                await checkUpdates()
            }
            .onReceive(NotificationCenter.default.publisher(for: LivePlugins.changed).receive(on: RunLoop.main)) { _ in
                installed = LivePlugins.shared.installed; sources = LivePlugins.shared.sources
            }
    }

    @ViewBuilder private var page: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "puzzlepiece.extension", title: L10n.text("Live Plugins"), subtitle: Self.note) {
            if let offered { offerSection(offered) }
            if !installed.isEmpty {
                TVSettingsSection(title: L10n.text("Installed")) {
                    if !updates.isEmpty {
                        TVSettingsAction(title: L10n.text("Update All (%lld)", updates.count), busy: updating) { updateAll() }
                    }
                    ForEach(installed) { plugin in
                        TVSettingsLink(title: plugin.name, value: version(plugin), warning: updates[plugin.pluginId] != nil) { LivePluginPage(plugin: plugin) }
                    }
                }
            }
            if !sources.isEmpty {
                TVSettingsSection(title: L10n.text("Sources")) {
                    ForEach(sources) { source in
                        TVSettingsLink(title: source.name, value: source.url.host()) { LivePluginSourcePage(source: source) }
                    }
                }
            }
            TVSettingsSection(title: L10n.text("Add a Source"), footer: failure ?? Self.addNote) {
                TVSettingsField(title: L10n.text("Source Address or Key"), text: $address)
                TVSettingsAction(title: L10n.text("Add"), busy: adding) { add() }
                    .disabled(address.isEmpty || adding)
            }
        }
        #else
        Form {
            if let offered { offerSection(offered) }
            if !installed.isEmpty {
                Section {
                    if !updates.isEmpty {
                        Button { updateAll() } label: {
                            HStack {
                                Text(L10n.text("Update All (%lld)", updates.count))
                                if updating { Spacer(); ProgressView().appControlSize(.small) }
                            }
                        }
                        .disabled(updating)
                    }
                    ForEach(installed) { plugin in
                        RouteLink { LivePluginPage(plugin: plugin) } label: { LivePluginRow(name: plugin.name, icon: LivePlugins.shared.iconFile(plugin),
                                                                                            detail: version(plugin), needsSignIn: plugin.requiresLogin,
                                                                                            highlighted: updates[plugin.pluginId] != nil) }
                    }
                } header: {
                    Text(L10n.text("Installed"))
                } footer: {
                    Text(Self.note)
                }
            }
            if !sources.isEmpty {
                Section(L10n.text("Sources")) {
                    ForEach(sources) { source in
                        RouteLink { LivePluginSourcePage(source: source) } label: {
                            LabeledContent(source.name) { Text(source.url.host() ?? "").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section {
                TextField(L10n.text("Source Address or Key"), text: $address, prompt: Text("https://… · angellive://…"))
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
                if let failure { Text(failure).foregroundStyle(Brand.rose) } else { Text(installed.isEmpty ? Self.note + "\n\n" + Self.addNote : Self.addNote) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("Live Plugins"))
        #endif
    }

    @ViewBuilder private func offerSection(_ offer: Offer) -> some View {
        LivePluginOfferSection(title: offer.name, address: offer.address, entries: offer.entries)
    }

    private func version(_ plugin: LivePlugins.Installed) -> String {
        if let update = updates[plugin.pluginId] { return "\(plugin.version) → \(update.version)" }
        return plugin.version
    }

    private func add() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        guard let url = LivePlugins.sourceAddress(text) else { failure = LivePlugins.Failure.notASource.localizedDescription; return }
        adding = true; failure = nil
        Task {
            do {
                let (name, entries) = try await LivePlugins.shared.index(url)
                LivePlugins.shared.addSource(url, name: name)
                offered = Offer(address: url, name: name, entries: entries)
                address = ""
            } catch {
                failure = L10n.text("The source wasn't added. %@", error.localizedDescription)
            }
            adding = false
        }
    }

    private func checkUpdates() async {
        guard !LivePlugins.shared.installed.isEmpty else { return }
        let found = await LivePlugins.shared.updates()
        updates = Dictionary(found.map { ($0.installed.pluginId, $0.entry) }, uniquingKeysWith: { first, _ in first })
    }

    private func updateAll() {
        guard !updating else { return }
        updating = true
        Task {
            for (id, entry) in updates {
                do {
                    try await LivePlugins.shared.install(entry, from: LivePlugins.shared.installed(id)?.source)
                    updates[id] = nil
                } catch {
                    failure = L10n.text("%@ wasn't updated. %@", entry.name, error.localizedDescription)
                }
            }
            updating = false
        }
    }
}

/// A source's plugins, each installed (or updated) with one press, or all at once.
struct LivePluginOfferSection: View {
    let title: String
    let address: URL
    let entries: [LivePlugins.Entry]
    @State private var busy: Set<String> = []
    @State private var failures: [String: String] = [:]
    @State private var revision = 0

    var body: some View {
        content
            #if DEBUG
            // `-qaInstallAll 1` with `-qaPage live-plugins -qaQuery <key>` installs the source's plugins without a tap.
            .task { if UserDefaults.standard.bool(forKey: "qaInstallAll") { install(entries.filter { state($0) != .installed }) } }
            #endif
    }

    @ViewBuilder private var content: some View {
        let missing = entries.filter { state($0) != .installed }
        #if os(tvOS)
        TVSettingsSection(title: title, footer: failures.values.first) {
            if missing.count > 1 {
                TVSettingsAction(title: L10n.text("Install All (%lld)", missing.count), busy: !busy.isEmpty) { install(missing) }
            }
            ForEach(entries) { entry in
                TVSettingsAction(title: entry.name, value: label(entry), busy: busy.contains(entry.pluginId)) { install([entry]) }
                    .disabled(state(entry) == .installed)
            }
        }
        .id(revision)
        #else
        Section {
            if missing.count > 1 {
                Button { install(missing) } label: {
                    HStack {
                        Text(L10n.text("Install All (%lld)", missing.count))
                        if !busy.isEmpty { Spacer(); ProgressView().appControlSize(.small) }
                    }
                }
                .disabled(!busy.isEmpty)
            }
            ForEach(entries) { entry in
                HStack(spacing: 12) {
                    LivePluginRow(name: entry.name, icon: LivePlugins.shared.installed(entry.pluginId).flatMap(LivePlugins.shared.iconFile), detail: failures[entry.pluginId] ?? (entry.summary.isEmpty ? entry.version : entry.summary),
                                  needsSignIn: entry.requiresLogin, highlighted: failures[entry.pluginId] != nil, placeholder: entry.name)
                    Spacer(minLength: 8)
                    if busy.contains(entry.pluginId) { ProgressView().appControlSize(.small) }
                    else {
                        Button(label(entry)) { install([entry]) }
                            .buttonStyle(.bordered).appControlSize(.small)
                            .disabled(state(entry) == .installed)
                    }
                }
            }
        } header: {
            Text(title)
        }
        .id(revision)
        #endif
    }

    private enum State { case available, update, installed }

    private func state(_ entry: LivePlugins.Entry) -> State {
        guard let current = LivePlugins.shared.installed(entry.pluginId) else { return .available }
        return current.version == entry.version && (entry.sha256.isEmpty || entry.sha256 == current.sha256) ? .installed : .update
    }

    private func label(_ entry: LivePlugins.Entry) -> String {
        switch state(entry) {
        case .available: L10n.text("Install")
        case .update: L10n.text("Update")
        case .installed: L10n.text("Installed")
        }
    }

    private func install(_ list: [LivePlugins.Entry]) {
        let list = list.filter { !busy.contains($0.pluginId) }
        guard !list.isEmpty else { return }
        list.forEach { busy.insert($0.pluginId); failures[$0.pluginId] = nil }
        Task {
            // One after another: a failure leaves the rest to install.
            for entry in list {
                do { try await LivePlugins.shared.install(entry, from: address) }
                catch { failures[entry.pluginId] = error.localizedDescription }
                busy.remove(entry.pluginId)
                revision += 1
            }
        }
    }
}

/// A source: its plugins to install or update, and removing it (with the plugins it installed).
struct LivePluginSourcePage: View {
    let source: LivePlugins.Source
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LivePlugins.Entry]?
    @State private var failure: String?

    var body: some View {
        content
            .task { await load() }
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "shippingbox", title: source.name, subtitle: source.url.absoluteString) {
            if let entries { LivePluginOfferSection(title: L10n.text("Plugins"), address: source.url, entries: entries) }
            else if let failure { TVSettingsSection(footer: failure) { TVSettingsAction(title: L10n.text("Try Again")) { Task { await load() } } } }
            TVSettingsSection {
                TVSettingsAction(title: L10n.text("Remove Source"), destructive: true) { remove() }
            }
        }
        #else
        Form {
            if let entries { LivePluginOfferSection(title: L10n.text("Plugins"), address: source.url, entries: entries) }
            else if let failure {
                Section { Button(L10n.text("Try Again")) { Task { await load() } } } footer: { Text(failure).foregroundStyle(Brand.rose) }
            } else {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            Section {
                Button(L10n.text("Remove Source"), role: .destructive) { remove() }
            } footer: {
                Text(L10n.text("Removing the source also removes the plugins installed from it."))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(source.name)
        #endif
    }

    private func load() async {
        failure = nil
        do { entries = try await LivePlugins.shared.index(source.url).plugins }
        catch { failure = error.localizedDescription }
    }

    private func remove() {
        LivePlugins.shared.removeSource(source.url)
        dismiss()
    }
}

/// One installed plugin: what it is, updating it and removing it.
struct LivePluginPage: View {
    let plugin: LivePlugins.Installed
    @Environment(\.dismiss) private var dismiss
    @State private var update: LivePlugins.Entry?
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        content
            .task {
                update = await LivePlugins.shared.updates().first { $0.installed.pluginId == plugin.pluginId }?.entry
            }
    }

    private var details: String {
        [plugin.summary, L10n.text("Version %@", plugin.version), plugin.source?.host()].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "puzzlepiece.extension", title: plugin.name, subtitle: details) {
            LivePluginAccountSection(plugin: plugin)
            TVSettingsSection(footer: failure) {
                if let update {
                    TVSettingsAction(title: L10n.text("Update to %@", update.version), busy: busy) { install(update) }
                }
                TVSettingsAction(title: L10n.text("Remove Plugin"), destructive: true) { remove() }
            }
        }
        #else
        Form {
            Section {
                LivePluginRow(name: plugin.name, icon: LivePlugins.shared.iconFile(plugin), detail: plugin.summary, needsSignIn: plugin.requiresLogin, large: true)
                LabeledContent(L10n.text("Version"), value: plugin.version)
                if let host = plugin.source?.host() { LabeledContent(L10n.text("Source"), value: host) }
            }
            LivePluginAccountSection(plugin: plugin)
            Section {
                if let update {
                    Button { install(update) } label: {
                        HStack {
                            Text(L10n.text("Update to %@", update.version))
                            if busy { Spacer(); ProgressView().appControlSize(.small) }
                        }
                    }
                    .disabled(busy)
                }
                Button(L10n.text("Remove Plugin"), role: .destructive) { remove() }
            } footer: {
                if let failure { Text(failure).foregroundStyle(Brand.rose) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(plugin.name)
        #endif
    }

    private func install(_ entry: LivePlugins.Entry) {
        busy = true; failure = nil
        Task {
            do { try await LivePlugins.shared.install(entry, from: plugin.source); update = nil }
            catch { failure = error.localizedDescription }
            busy = false
        }
    }

    private func remove() {
        LivePlugins.shared.uninstall(plugin.pluginId)
        dismiss()
    }
}

/// A plugin as a row: its icon, name, a detail line, and a "Sign In" tag when the platform needs an account.
struct LivePluginRow: View {
    let name: String
    let icon: URL?
    var detail: String = ""
    var needsSignIn = false
    var highlighted = false
    var placeholder: String? = nil
    var large = false

    var body: some View {
        HStack(spacing: 12) {
            PluginIconView(file: icon, fallback: placeholder ?? name, size: large ? 52 : 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // A short name next to the tag shrank to nothing (快手) without the priority.
                    Text(name).lineLimit(1).layoutPriority(1)
                    if needsSignIn {
                        Text(L10n.text("Sign-In Needed"))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.15), in: Capsule())
                            .fixedSize()
                    }
                }
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(highlighted ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.secondary)).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A plugin's icon file on a white rounded tile, or its initial while there is none.
struct PluginIconView: View {
    let file: URL?
    var fallback = ""
    var size: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let image = file.flatMap(PluginIcons.image) {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit().padding(size * 0.12)
            } else {
                Text(String(fallback.prefix(1))).font(.system(size: size * 0.5, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(.white, in: shape)
        .overlay { shape.strokeBorder(.black.opacity(0.08), lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// Decoded plugin icons, kept while the app runs (a handful of 128-pixel images).
@MainActor enum PluginIcons {
    private static var cache: [URL: CGImage] = [:]
    static func image(_ file: URL) -> CGImage? {
        if let image = cache[file] { return image }
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache[file] = image
        return image
    }
}
