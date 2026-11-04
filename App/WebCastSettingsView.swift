import SwiftUI
import TVCore
import CoreImage.CIFilterBuiltins

/// The Settings page for Web Cast: the on/off switch, the port, and the address a computer opens.
/// Shown only when the feature was compiled in (`WEBCAST`); the Settings list hides it otherwise.
struct WebCastSettingsView: View {
    @Environment(Store.self) private var store
    @State private var enabled: Bool = WebCastSettings.shared.enabled
    @State private var portText: String = String(WebCastSettings.shared.port)
    @State private var requiresToken: Bool = WebCastSettings.shared.requiresToken
    @State private var token: String = WebCastSettings.shared.token
    @State private var proxyMedia: Bool = WebCastSettings.shared.proxyMedia
    @State private var copied = false

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

        SettingsGroup(footer: L10n.text("When on, opening the address asks for this password before showing anything. Leave it off to let anyone on the network in.")) {
            Toggle(isOn: $requiresToken) {
                FormLabel(symbol: "lock", tint: .orange, title: L10n.text("Login Password"), subtitle: L10n.text("Protect the web page with a password."))
            }
            .settingsSwitch()
            .onChange(of: requiresToken) { _, on in Task { await apply() } }

            if requiresToken {
                SettingsRow(symbol: "key", tint: .purple, title: L10n.text("Password"), subtitle: L10n.text("Entered in the browser to log in.")) {
                    SecureField(L10n.text("Password"), text: $token)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 140)
                        .onSubmit { Task { await apply() } }
                }
            }
        }

        SettingsGroup(footer: L10n.text("On by default: streams go through the phone so Referer and HTTPS work, but this uses the phone's upload bandwidth. Turn it off to let the browser fetch streams directly, which is lighter on the phone but only works for sources that allow it.")) {
            Toggle(isOn: $proxyMedia) {
                FormLabel(symbol: "arrow.left.arrow.right", tint: .indigo, title: L10n.text("Relay Playback"), subtitle: L10n.text("Route video through the phone's proxy."))
            }
            .settingsSwitch()
            .onChange(of: proxyMedia) { _, on in Task { await apply() } }
        }

        if let address = controller.address, enabled {
            SettingsGroup(footer: L10n.text("Open this address in a browser on your computer or tablet. If you set a password, the page will ask for it. Scan the code with another phone to open it instantly.")) {
                SettingsRow(symbol: "link", tint: .green, title: L10n.text("Address"), subtitle: address) {
                    Button {
                        #if os(iOS)
                        UIPasteboard.general.string = address
                        #endif
                        copied = true
                        Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.borderless)
                }
                if let qr = QRCode.image(address, scale: 10) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
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
        settings.requiresToken = requiresToken
        settings.token = token
        settings.proxyMedia = proxyMedia
        if let port = Int(portText), (1...65535).contains(port) { settings.port = port }
        await controller.apply()
        // Show the new port in the field after the server reports its actual value.
        portText = String(settings.port)
    }
}
