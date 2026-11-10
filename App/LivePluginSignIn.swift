import SwiftUI
import TVCore
#if !os(tvOS)
import WebKit
#endif

/// A live plugin's account, on its page in Settings › Live Plugins: signed in or not, signing in on the
/// platform's own web page (iPhone, iPad, Mac), pasting a cookie (any device, the only way on Apple TV),
/// and signing out. The cookie stays in the Keychain; the plugin gets it only on requests to its own sites.
struct LivePluginAccountSection: View {
    let plugin: LivePlugins.Installed
    @State private var signedIn = false
    @State private var flow: LivePluginLoginFlow?
    @State private var checking = false
    /// What `validateCredential` said about the saved cookie: nil until asked, or when the plugin can't tell.
    @State private var valid: Bool?
    @State private var webSignIn = false

    var body: some View {
        Group {
            // Platforms that use no account (Huya, YouTube) show none.
            if flow != nil || plugin.requiresLogin || signedIn { content }
        }
            .task { await refresh(check: true) }
            .onReceive(NotificationCenter.default.publisher(for: LivePluginAccounts.changed).receive(on: RunLoop.main)) { note in
                if note.object as? String == plugin.pluginId { Task { await refresh(check: true) } }
            }
            #if !os(tvOS)
            .sheet(isPresented: $webSignIn) {
                if let flow { LivePluginWebSignIn(plugin: plugin, flow: flow) }
            }
            #endif
    }

    private var status: String {
        guard signedIn else { return L10n.text("Not Signed In") }
        if checking { return L10n.text("Checking…") }
        return valid == false ? L10n.text("Sign-In Expired") : L10n.text("Signed In")
    }

    private var footer: String {
        [flow?.hint, L10n.text("Some platforms show more, or better quality, once you sign in. The sign-in stays on this device.")]
            .compactMap { $0 }.joined(separator: "\n")
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        TVSettingsSection(title: L10n.text("Account"), footer: footer) {
            TVSettingsRowLabel(title: L10n.text("Status"), value: status, warning: valid == false) { EmptyView() }
            TVSettingsLink(title: L10n.text("Paste a Cookie")) { LivePluginCookiePage(plugin: plugin) }
            if signedIn { TVSettingsAction(title: L10n.text("Sign Out"), destructive: true) { LivePluginAccounts.setCookie(plugin.pluginId, nil) } }
        }
        #else
        Section {
            LabeledContent(L10n.text("Status")) {
                Text(status).foregroundStyle(valid == false ? Brand.amber : .secondary)
            }
            if flow != nil {
                Button(signedIn ? L10n.text("Sign In Again") : L10n.text("Sign In")) { webSignIn = true }
            }
            RouteLink { LivePluginCookiePage(plugin: plugin) } label: { Text(L10n.text("Paste a Cookie")) }
            if signedIn {
                Button(L10n.text("Sign Out"), role: .destructive) { LivePluginAccounts.setCookie(plugin.pluginId, nil) }
            }
        } header: {
            Text(L10n.text("Account"))
        } footer: {
            Text(footer)
        }
        #endif
    }

    private func refresh(check: Bool) async {
        signedIn = LivePluginAccounts.isSignedIn(plugin.pluginId)
        if flow == nil { flow = await LivePlugins.shared.loginFlow(plugin.pluginId) }
        guard check, signedIn else { valid = nil; return }
        checking = true
        valid = await LivePlugins.shared.checkSignIn(plugin.pluginId)
        checking = false
    }
}

/// A cookie copied from a signed-in browser, for platforms (and devices) without a web sign-in here.
struct LivePluginCookiePage: View {
    let plugin: LivePlugins.Installed
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""

    private var trimmed: String { cookie.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static let note = L10n.text("In a browser signed in to the platform, copy the Cookie header of one of its requests and paste it here.")

    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "key", title: L10n.text("Paste a Cookie"), subtitle: plugin.name) {
            TVSettingsSection(footer: Self.note) {
                TVSettingsField(title: L10n.text("Cookie"), text: $cookie)
                TVSettingsAction(title: L10n.text("Save")) { save() }.disabled(trimmed.isEmpty)
            }
        }
        #else
        Form {
            Section {
                TextField(L10n.text("Cookie"), text: $cookie, prompt: Text("name=value; name2=value2"), axis: .vertical)
                    .lineLimit(3...8)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button(L10n.text("Save")) { save() }.disabled(trimmed.isEmpty)
            } footer: {
                Text(Self.note)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.text("Paste a Cookie"))
        #endif
    }

    private func save() {
        // People paste the whole header line too.
        var value = trimmed
        if value.lowercased().hasPrefix("cookie:") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        LivePluginAccounts.setCookie(plugin.pluginId, value)
        dismiss()
    }
}

#if !os(tvOS)
/// Signs in on the platform's own page in a private web view, and keeps its cookies once they show a sign-in
/// (`loginFlow.authSignalCookies`). The sheet closes by itself then.
struct LivePluginWebSignIn: View {
    let plugin: LivePlugins.Installed
    let flow: LivePluginLoginFlow
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        #if os(iOS)
        configuration.ignoresViewportScaleLimits = true
        #endif
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    @State private var loading = true

    var body: some View {
        NavigationStack {
            LivePluginBrowser(webView: webView, flow: flow, loading: $loading)
                .overlay(alignment: .top) { if loading { ProgressView().padding(12) } }
                .navigationTitle(L10n.text("Sign In to %@", plugin.name))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 720, minHeight: 600, idealHeight: 760)
        #endif
        .task { await watch() }
    }

    /// Checks the page's cookies every second until they show a sign-in.
    private func watch() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard let header = flow.header(from: cookies) else { continue }
            Diagnostics.shared.record(.info, "plugins", "\(plugin.pluginId) signed in on its page (\(cookies.count) cookies)")
            LivePluginAccounts.setCookie(plugin.pluginId, header)
            dismiss()
            return
        }
    }
}

#if os(iOS)
private typealias Representable = UIViewRepresentable
#else
private typealias Representable = NSViewRepresentable
#endif

private struct LivePluginBrowser: Representable {
    let webView: WKWebView
    let flow: LivePluginLoginFlow
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(loading: $loading) }
    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    #endif

    private func make(_ context: Context) -> WKWebView {
        if let agent = flow.userAgent, !agent.isEmpty { webView.customUserAgent = agent }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.load(URLRequest(url: flow.page))
        return webView
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var loading: Bool
        init(loading: Binding<Bool>) { _loading = loading }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // The pages offer to open their own apps (bilibili://, kwai://); signing in stays here.
            if let scheme = navigationAction.request.url?.scheme?.lowercased(), !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
        /// Sign-in pop-ups (QR codes, third-party accounts) open in the same view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false }
    }
}
#endif
