#if !os(tvOS)
import SwiftUI
import TVCore

/// The service and display controls over the playing video, and the service ones on Settings › Danmaku.
/// Sections rather than another form, so playback can add matching, timing and file controls.
struct DanmakuServiceSettings: View {
    /// Settings › Danmaku Settings has its own display rows, and Show Danmaku is the switch right above its link (#1117).
    var showsSwitch = true
    var showsDisplay = true
    @AppStorage(DanmakuPreference.key) private var enabled = true
    @AppStorage(DanmakuService.serverKey) private var server = CatalogDanmakuClient.defaultServer
    @AppStorage(DanmakuService.automaticKey) private var automatic = true
    @AppStorage(DanmakuService.preferredSourceKey) private var preferredSource = ""
    @AppStorage(DanmakuService.officialLookupKey) private var officialLookup = true
    /// The servers asked in order (#1408), and an address being added (tested first).
    @State private var servers = DanmakuService.servers()
    @State private var address = ""
    @State private var checking = false
    @State private var failure: String?
    @State private var saved = false

    var body: some View {
        Group {
        Section {
            if showsSwitch {
                Toggle(L10n.text("Show Danmaku"), isOn: $enabled)
                    .settingsSwitch().accessibilityIdentifier("danmaku.enabled")
            }
            Toggle(L10n.text("Automatically match the current episode"), isOn: Binding(
                get: { automatic },
                set: { save(server: server, source: source, automatic: $0) }))
                .settingsSwitch().accessibilityIdentifier("danmaku.automatic")
            Picker(L10n.text("Preferred Source Platform"), selection: Binding(
                get: { source },
                set: { save(server: server, source: $0, automatic: automatic) })) {
                ForEach(DanmakuProvider.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityIdentifier("danmaku.preferredSource")
        } header: { Text(L10n.text("Danmaku Service")) }
          footer: { Text(L10n.text("Matching comments appear automatically. If none match or the service is unavailable, the video stays clear.")) }

        // The official server's fallback sends episode pages to other services; say so, and let it be turned off.
        if servers.contains(CatalogDanmakuClient.defaultServer) {
            Section {
                Toggle(L10n.text("Find official episodes for dmku"), isOn: $officialLookup)
                    .settingsSwitch().accessibilityIdentifier("danmaku.officialLookup")
            } footer: { Text(DanmakuService.officialLookupNote) }
        }

        Section {
            ForEach(Array(servers.enumerated()), id: \.element) { index, server in
                HStack {
                    Text(DanmakuService.title(for: server))
                    Spacer()
                    if servers.count > 1 {
                        Menu {
                            Button(L10n.text("Move Up")) { change { try DanmakuService.move(server, to: index - 1) } }.disabled(index == 0)
                            Button(L10n.text("Move Down")) { change { try DanmakuService.move(server, to: index + 1) } }.disabled(index == servers.count - 1)
                            Button(L10n.text("Remove"), role: .destructive) { change { try DanmakuService.remove(server) } }
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel(L10n.text("Order"))
                        }
                        #if os(macOS)
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        #endif
                        .accessibilityIdentifier("danmaku.server.menu.\(index)")
                    }
                }
            }
            TextField(L10n.text("Danmaku server URL"), text: $address,
                      prompt: Text(L10n.text("Danmaku server URL")))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
                .onSubmit(add)
                .accessibilityIdentifier("danmaku.server")
            HStack {
                Button(L10n.text("Add Server"), action: add)
                    .disabled(checking || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("danmaku.server.save")
                if !servers.contains(CatalogDanmakuClient.defaultServer) {
                    Button(L10n.text("Add Built-in Services")) {
                        change { try DanmakuService.save(servers: servers + [CatalogDanmakuClient.defaultServer]) }
                    }
                    .accessibilityIdentifier("danmaku.server.reset")
                }
                if checking { ProgressView().controlSize(.small) }
            }
            #if os(iOS)
            // Two buttons in one form row: with the row's default style a tap anywhere in it ran both (#1053).
            // Borderless buttons each take only their own taps.
            .buttonStyle(.borderless)
            #endif
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("danmaku.server.error")
            } else if saved {
                Text(L10n.text("Danmaku service settings saved."))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("danmaku.server.saved")
            }
        } header: { Text(L10n.text("Danmaku Servers")) }
          footer: { Text(DanmakuService.serversNote) }

        if showsDisplay {
            Section {
                DanmakuDisplaySettings()
            } header: { Text(L10n.text("Danmaku Display")) }
        }
        }
        .onChange(of: address) { _, _ in failure = nil; saved = false }
        .onReceive(NotificationCenter.default.publisher(for: DanmakuService.changed)) { _ in servers = DanmakuService.servers() }
    }

    private var source: DanmakuProvider { DanmakuProvider(rawValue: preferredSource) ?? .automatic }

    /// Asks the server first: one that doesn't answer as Dandanplay does, or refuses its token, isn't added.
    private func add() {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !checking else { return }
        checking = true; failure = nil; saved = false
        Task {
            do {
                let added = try await DanmakuService.check(typed)
                try DanmakuService.save(servers: DanmakuService.servers() + [added])
                address = ""; saved = true
            } catch {
                failure = error.localizedDescription
            }
            checking = false
        }
    }

    private func change(_ edit: () throws -> Void) {
        do { try edit(); failure = nil; saved = true } catch { failure = error.localizedDescription; saved = false }
    }

    private func save(server address: String, source: DanmakuProvider, automatic: Bool) {
        do {
            try DanmakuService.save(server: address, preferredSource: source, automatic: automatic)
            failure = nil; saved = true
        } catch {
            failure = error.localizedDescription; saved = false
        }
    }
}
#endif
