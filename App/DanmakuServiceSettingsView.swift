#if !os(tvOS)
import SwiftUI
import TVCore

/// The service and display controls over the playing video, and the service ones on Settings › Danmaku.
/// Sections rather than another form, so playback can add matching, timing and file controls.
struct DanmakuServiceSettings: View {
    /// Settings › Danmaku has its own Show Danmaku switch at the top and its own display rows.
    var showsSwitch = true
    var showsDisplay = true
    @AppStorage(DanmakuPreference.key) private var enabled = true
    @AppStorage(DanmakuService.serverKey) private var server = CatalogDanmakuClient.defaultServer
    @AppStorage(DanmakuService.automaticKey) private var automatic = true
    @AppStorage(DanmakuService.preferredSourceKey) private var preferredSource = ""
    @AppStorage(DanmakuService.officialLookupKey) private var officialLookup = true
    @State private var address = DanmakuService.server()
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
        if !DanmakuService.isCustomServer(server) {
            Section {
                Toggle(L10n.text("Find official episodes for dmku"), isOn: $officialLookup)
                    .settingsSwitch().accessibilityIdentifier("danmaku.officialLookup")
            } footer: { Text(DanmakuService.officialLookupNote) }
        }

        Section {
            TextField(L10n.text("Danmaku server URL"), text: $address,
                      prompt: Text(L10n.text("Danmaku server URL")))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
                .onSubmit(saveAddress)
                .accessibilityIdentifier("danmaku.server")
            HStack {
                Button(L10n.text("Save"), action: saveAddress)
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("danmaku.server.save")
                Button(L10n.text("Use Official URL")) {
                    address = CatalogDanmakuClient.defaultServer
                    saveAddress()
                }
                .accessibilityIdentifier("danmaku.server.reset")
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("danmaku.server.error")
            } else if saved {
                Text(L10n.text("Danmaku service settings saved."))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("danmaku.server.saved")
            }
        } footer: {
            Text(L10n.text("Enter a Dandanplay-compatible server root or an API prefix ending in /api/v2. A token in the path is supported. The URL is saved only on this device."))
        }

        if showsDisplay {
            Section {
                DanmakuDisplaySettings()
            } header: { Text(L10n.text("Danmaku Display")) }
        }
        }
        .onChange(of: address) { _, _ in failure = nil; saved = false }
        .onChange(of: server) { _, value in address = value }
    }

    private var source: DanmakuProvider { DanmakuProvider(rawValue: preferredSource) ?? .automatic }

    private func saveAddress() {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        save(server: address, source: source, automatic: automatic)
        if failure == nil { address = server }
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
