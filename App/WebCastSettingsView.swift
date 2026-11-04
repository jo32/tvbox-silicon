import SwiftUI
import TVCore

/// The Settings page for Web Cast: the on/off switch, the port, and the address a computer opens.
/// Shown only when the feature was compiled in (`WEBCAST`); the Settings list hides it otherwise.
struct WebCastSettingsView: View {
    @Environment(Store.self) private var store
    @State private var enabled: Bool = WebCastSettings.shared.enabled
    @State private var portText: String = String(WebCastSettings.shared.port)

    private var controller: WebCastController { store.webCast }

    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "globe", title: L10n.text("Web Cast")) {
            content
        }
        #else
        Form {
            content
        }
        .navigationTitle(L10n.text("Web Cast"))
        .task { await controller.start(with: store) }
        #endif
    }

    @ViewBuilder private var content: some View {
        SettingsGroup(footer: L10n.text("When on, a computer on the same network opens the address below and gets a web version of Yingxia.")) {
            Toggle(isOn: $enabled) {
                FormLabel(symbol: "globe", tint: .blue, title: L10n.text("Web Cast"), subtitle: L10n.text("Drive Yingxia from a browser on the same Wi-Fi."))
            }
            .settingsSwitch()
            .onChange(of: enabled) { _, on in Task { await apply() } }
        }

        SettingsGroup(footer: L10n.text("Default %lld. Change it only if another app uses that port.", WebCastSettings.defaultPort)) {
            SettingsRow(symbol: "number", tint: .teal, title: L10n.text("Port"), subtitle: L10n.text("The TCP port the web server listens on.")) {
                TextField("", text: $portText)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onSubmit { Task { await apply() } }
            }
        }

        if let address = controller.address, enabled {
            SettingsGroup(footer: L10n.text("Open this address in a browser on your computer or tablet. The token keeps other devices on the network from driving your app.")) {
                SettingsRow(symbol: "link", tint: .green, title: L10n.text("Address"), subtitle: address)
            }
        } else if let error = controller.errorMessage, enabled {
            SettingsGroup(footer: L10n.text("The server could not start. Check the port and try again.")) {
                SettingsRow(symbol: "exclamationmark.triangle", tint: .red, title: L10n.text("Not Running"), subtitle: error)
            }
        }
    }

    private func apply() async {
        let settings = WebCastSettings.shared
        settings.enabled = enabled
        if let port = Int(portText), (1...65535).contains(port) { settings.port = port }
        await controller.apply()
        // Show the new port in the field after the server reports its actual value.
        portText = String(settings.port)
    }
}
