import SwiftUI
import TVCore
#if os(macOS)
import WebKit

struct CloudDriveView: View {
    @Environment(Store.self) private var store
    @State private var accounts = CloudDriveAccounts()
    @State private var login: CloudProvider?
    /// Baidu and Aliyun sign in with a code to scan, as on Apple TV.
    @State private var scan: CloudProvider?
    /// Xunlei signs in with a code texted to the phone.
    @State private var texting = false
    @State private var notice: String?
    @State private var error: String?
    @State private var saving = false
    @State private var showsManual = false
    var body: some View {
        SettingsPage(title: L10n.text("Cloud Drive Accounts"), symbol: "externaldrive") {
            SettingsGroup(footer: store.extrasUnlocked ? L10n.text("Sign in to Quark and UC on their official page, and to Baidu and Aliyun by scanning a code with their phone app. Yingxia stores the login on this Mac and supplies it to the plugins you run.")
                            : L10n.text("Sign in to Quark and UC on their official page. Yingxia stores the login on this Mac.")) {
                ForEach(CloudProvider.shown(store)) { provider in
                    let signedIn = provider.isSignedIn(accounts)
                    SettingsRow(symbol: provider.symbol, tint: provider.tint, title: provider.name,
                                subtitle: L10n.text(signedIn ? "Signed In" : "Not Signed In")) {
                        if signedIn {
                            Button(L10n.text("Sign Out")) {
                                provider.clear(&accounts)
                                EmbeddedJarHost.forgetPluginSignIns(provider.pluginFiles)
                                save()
                            }.settingsButton()
                        } else {
                            Button(L10n.text("Sign In")) {
                                if provider == .xunlei { texting = true } else if provider.signsInOnWeb { login = provider } else { scan = provider }
                            }.settingsButton(prominent: true)
                        }
                    }
                }
            }
            if store.extrasUnlocked {
            SettingsGroup(title: L10n.text("Advanced"),
                          footer: L10n.text("You can also paste existing credentials. They are stored locally and supplied to the subscription plugins you run. Saving restarts plugin sessions.")) {
                DisclosureGroup(isExpanded: $showsManual) {
                    SecureField(L10n.text("Quark Cookie"), text: $accounts.quarkCookie)
                    SecureField(L10n.text("Quark Mobile Ticket (optional)"), text: Binding(get: { accounts.quarkServiceTicket ?? "" }, set: { accounts.quarkServiceTicket = $0.isEmpty ? nil : $0 }))
                    SecureField(L10n.text("UC Cookie"), text: $accounts.ucCookie)
                    SecureField(L10n.text("UC Token (optional)"), text: $accounts.ucToken)
                    SecureField(L10n.text("Aliyun Refresh Token"), text: $accounts.token)
                    SecureField(L10n.text("Baidu Cookie (BDUSS, STOKEN)"), text: Binding(get: { accounts.baiduCookie ?? "" }, set: { accounts.baiduCookie = $0.isEmpty ? nil : $0 }))
                    HStack { Spacer(); Button(L10n.text("Save Accounts")) { save() }.settingsButton(prominent: true).disabled(saving) }
                } label: {
                    Text(L10n.text("Paste Credentials Manually"))
                }
            }
            }
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.rose) }
        }
        .task { do { accounts = try CloudDriveAccounts.load() } catch { self.error = error.localizedDescription } }
        .sheet(item: $login) { provider in
            CloudLoginView(provider: provider) { cookie, ticket in
                try await provider.saveLogin(cookie, ticket: ticket)
                accounts = (try? CloudDriveAccounts.load()) ?? accounts
                notice = L10n.text("Accounts saved. Retry the video source.")
                error = nil
            }
        }
        .sheet(item: $scan) { provider in
            CloudQRLoginView(drive: provider.qrDrive) {
                accounts = (try? CloudDriveAccounts.load()) ?? accounts
                save()
            }
        }
        .sheet(isPresented: $texting) {
            XunleiSignInView {
                accounts = (try? CloudDriveAccounts.load()) ?? accounts
                notice = L10n.text("Accounts saved. Retry the video source.")
                error = nil
            }
        }
    }
    private func save() {
        saving = true; notice = nil; error = nil
        Task {
            defer { saving = false }
            do {
                try accounts.save()
                await LocalJarHost.shared.reloadCloudAccounts()
                await EmbeddedJarHost.shared.reloadCloudAccounts()
                notice = L10n.text("Accounts saved. Retry the video source.")
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct CloudLoginView: View {
    let provider: CloudProvider
    /// Cookie text, and Quark's approved sign-in ticket when the page opened one.
    let save: (String, String?) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    /// Quark's approved sign-in ticket. FTY's player needs the mobile ticket derived from it.
    @State private var ticket: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: provider.symbol)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(provider.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text(provider == .quark ? "Sign In to Quark" : "Sign In to UC")).font(.headline)
                    Text(provider.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                }
                if loading {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                    ElapsedTime().font(.caption)
                }
                Spacer()
                Button { error = nil; loading = true; ticket = nil; webView.load(URLRequest(url: provider.url)) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .settingsButton().help(L10n.text("Retry")).accessibilityLabel(L10n.text("Retry"))
                Button(L10n.text("Cancel")) { dismiss() }.settingsButton().keyboardShortcut(.cancelAction)
                Button(L10n.text("Save Login")) { Task { await commit() } }
                .settingsButton(prominent: true).keyboardShortcut(.defaultAction).disabled(saving)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            CloudLoginBrowser(webView: webView, provider: provider, error: $error, loading: $loading, ticket: $ticket)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 680)
    }

    /// Saves once the page has a drive cookie. Quark also waits briefly for the sign-in ticket the page
    /// sends in the background. Without it the cookie still saves; only FTY asks to sign in again.
    private func commit() async {
        saving = true
        defer { saving = false }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let now = Date()
        let selected = cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return (domain == provider.domain || domain.hasSuffix("." + provider.domain)) && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        }
        guard selected.contains(where: { $0.name == "__pus" && !$0.value.isEmpty }) else {
            error = L10n.text("Finish signing in before saving the login.")
            return
        }
        var found = ticket
        if provider == .quark, found == nil {
            for _ in 0..<4 {
                try? await Task.sleep(for: .seconds(1))
                if let ticket { found = ticket; break }
            }
        }
        var fields: [String: String] = [:]
        for cookie in selected where !cookie.value.isEmpty { fields[cookie.name] = cookie.value }
        let cookie = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        do {
            try await save(cookie, found)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
private struct CloudLoginBrowser: NSViewRepresentable {
    let webView: WKWebView
    let provider: CloudProvider
    @Binding var error: String?
    @Binding var loading: Bool
    @Binding var ticket: String?
    func makeCoordinator() -> Coordinator { Coordinator(provider: provider, error: $error, loading: $loading, ticket: $ticket) }
    func makeNSView(context: Context) -> WKWebView {
        webView.customUserAgent = provider.webSignIn.userAgent
        if provider == .quark {
            let content = webView.configuration.userContentController
            content.add(context.coordinator, name: Self.ticketMessage)
            content.addUserScript(WKUserScript(source: Self.catchTicket, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: provider.url))
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}

    static let ticketMessage = "signInTicket"

    /// Reports Quark's sign-in ticket from the sign-in frame, or from the page's request to /account/info?st=.
    static let catchTicket = """
    (function () {
      function report(st) { if (st) window.webkit.messageHandlers.\(ticketMessage).postMessage(String(st)); }
      function check(address) {
        try { var url = new URL(String(address), location.href); if (/\\/account\\/info$/.test(url.pathname)) report(url.searchParams.get('st')); } catch (e) {}
      }
      var open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, address) { check(address); return open.apply(this, arguments); };
      if (window.fetch) {
        var fetch = window.fetch;
        window.fetch = function (input) { check(typeof input === 'string' ? input : input && input.url); return fetch.apply(this, arguments); };
      }
      window.addEventListener('message', function (event) {
        if (event.data && typeof event.data === 'object' && typeof event.data.st === 'string') report(event.data.st);
      });
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let provider: CloudProvider
        @Binding var error: String?
        @Binding var loading: Bool
        @Binding var ticket: String?
        init(provider: CloudProvider, error: Binding<String?>, loading: Binding<Bool>, ticket: Binding<String?>) {
            self.provider = provider; _error = error; _loading = loading; _ticket = ticket
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, let found = WebSignIn.quark.serviceTicket(in: url) { ticket = found }
            decisionHandler(.allow)
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == CloudLoginBrowser.ticketMessage, let found = message.body as? String, !found.isEmpty, found != ticket else { return }
            ticket = found
            Diagnostics.shared.record(.info, "cloud.signin", "\(provider.rawValue) page passed its sign-in ticket")
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { loading = false; error = failure.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { loading = false; error = failure.localizedDescription }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
                loading = false
                error = L10n.text("The source %@ returned HTTP %lld.", response.url?.host ?? "", response.statusCode)
            }
            decisionHandler(.allow)
        }
    }
}
#else
/// Cloud drive sign-ins on iPhone, iPad and Apple TV. Apple TV has no browser: it shows a code to
/// scan with the drive's phone app. iPhone and iPad can't scan their own screen, so they open the
/// drive's own sign-in page, with the code for another phone as the alternative. Plugins read the
/// saved sign-in on their next request.
struct CloudDriveView: View {
    @Environment(Store.self) private var store
    @State private var accounts = CloudDriveAccounts()
    @State private var login: CloudProvider?
    @State private var error: String?
    var body: some View {
        SettingsPage(title: L10n.text("Cloud Drive Accounts"), symbol: "externaldrive") {
            SettingsGroup(footer: footer) {
                ForEach(CloudProvider.shown(store)) { provider in
                    let signedIn = provider.isSignedIn(accounts)
                    SettingsRow(symbol: provider.symbol, tint: provider.tint, title: provider.name,
                                subtitle: L10n.text(signedIn ? "Signed In" : "Not Signed In")) {
                        if signedIn {
                            Button(L10n.text("Sign Out")) { signOut(provider) }.settingsButton()
                        } else {
                            Button(L10n.text("Sign In")) { login = provider }.settingsButton(prominent: true)
                        }
                    }
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.rose) }
        }
        .task { reload() }
        #if os(iOS)
        .sheet(item: $login) { provider in
            if provider == .xunlei { XunleiSignInView(signedIn: reload) }
            else {
                WebSignInView(service: provider.webSignIn, signedIn: reload) {
                    CloudQRLoginView(drive: provider.qrDrive) { reload() }
                }
            }
        }
        #else
        .fullScreenCover(item: $login) { provider in
            if provider == .xunlei { XunleiSignInView(signedIn: reload) }
            else { CloudQRLoginView(drive: provider.qrDrive) { reload() } }
        }
        #endif
    }
    private var footer: String {
        #if os(iOS)
        store.extrasUnlocked ? L10n.text("Sign in on the drive's own page, or scan a code with the drive's app on another phone. Yingxia keeps the sign-in on this device and supplies it to the plugins you run.")
            : L10n.text("Sign in on the drive's own page, or scan a code with the drive's app on another phone. Yingxia keeps the sign-in on this device.")
        #else
        store.extrasUnlocked ? L10n.text("Sign in by scanning a code with the drive's phone app. Yingxia keeps the sign-in on this device and supplies it to the plugins you run.")
            : L10n.text("Sign in by scanning a code with the drive's phone app. Yingxia keeps the sign-in on this device.")
        #endif
    }
    private func reload() {
        do { accounts = try CloudDriveAccounts.load(); error = nil } catch { self.error = error.localizedDescription }
    }
    private func signOut(_ provider: CloudProvider) {
        var updated = accounts
        provider.clear(&updated)
        // The plugin keeps its own copy of a Baidu or Aliyun sign-in; it goes too.
        EmbeddedJarHost.forgetPluginSignIns(provider.pluginFiles)
        do { try updated.save(); accounts = updated; error = nil } catch { self.error = error.localizedDescription }
    }
}
#endif

enum CloudProvider: String, Identifiable, CaseIterable {
    case quark, uc, baidu, aliyun, xunlei
    var id: String { rawValue }
    var name: String {
        switch self {
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .baidu: L10n.text("Baidu Netdisk")
        case .aliyun: L10n.text("Aliyun Drive")
        case .xunlei: L10n.text("Xunlei")
        }
    }
    var symbol: String {
        switch self {
        case .quark: "icloud.fill"
        case .uc: "externaldrive.fill"
        case .baidu: "cloud.fill"
        case .aliyun: "shippingbox.fill"
        case .xunlei: "bolt.fill"
        }
    }
    var tint: Color {
        switch self {
        case .quark: .blue
        case .uc: .orange
        case .baidu: .indigo
        case .aliyun: .purple
        case .xunlei: .cyan
        }
    }
    /// Baidu, Aliyun and Xunlei only serve plugins, so an App Store build lists them once a subscription is added;
    /// Quark and UC are browsed in Cloud Files too.
    @MainActor static func shown(_ store: Store) -> [CloudProvider] { store.extrasUnlocked ? allCases : [.quark, .uc] }

    /// Quark and UC sign in on their web page on a Mac; Xunlei with a texted code; every other sign-in is a code to scan.
    var signsInOnWeb: Bool { self == .quark || self == .uc }
    var domain: String { self == .quark ? "quark.cn" : "uc.cn" }
    var qrDrive: CloudDriveQRLogin.Drive { CloudDriveQRLogin.Drive(rawValue: rawValue)! }
    var webSignIn: WebSignIn { WebSignIn(rawValue: rawValue)! }
    var url: URL { URL(string: self == .quark ? "https://pan.quark.cn/" : "https://drive.uc.cn/")! }
    /// Where FTY plugins keep their own copy of the sign-in.
    var pluginFiles: [String] {
        switch self {
        case .baidu: ["mybd_cookie"]
        case .aliyun: ["ali_user", "ali_oauth", "ali_info"]
        case .quark, .uc, .xunlei: []
        }
    }
    func isSignedIn(_ accounts: CloudDriveAccounts) -> Bool {
        let value: String
        switch self {
        case .quark: value = accounts.quarkCookie
        case .uc: value = accounts.ucCookie
        case .baidu: value = accounts.baiduCookie ?? ""
        case .aliyun: value = accounts.token
        case .xunlei: value = accounts.xunlei?.refreshToken ?? ""
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func set(_ cookie: String, in accounts: inout CloudDriveAccounts) {
        switch self {
        case .quark:
            if accounts.quarkCookie != cookie { accounts.quarkServiceTicket = nil }
            accounts.quarkCookie = cookie
        case .uc: accounts.ucCookie = cookie
        case .baidu: accounts.baiduCookie = cookie.isEmpty ? nil : cookie
        case .aliyun: accounts.token = cookie
        // Xunlei's sign-in is made only by XunleiSignInView; this only clears it.
        case .xunlei: if cookie.isEmpty { accounts.xunlei = nil }
        }
    }
    func clear(_ accounts: inout CloudDriveAccounts) {
        set("", in: &accounts)
        if self == .uc { accounts.ucToken = "" }
    }
    /// "Signed In · Quark" style summary for the Settings row.
    static func summary() -> String {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let names = allCases.filter { $0.isSignedIn(accounts) }.map(\.name)
        return names.isEmpty ? L10n.text("Not Signed In") : L10n.text("Signed In") + " · " + names.joined(separator: ", ")
    }
}

#if os(macOS)
extension CloudProvider {
    /// Saves a login captured outside the accounts page and restarts plugin sessions.
    /// `ticket` is Quark's approved sign-in ticket. FTY's player needs the mobile ticket exchanged from it.
    func saveLogin(_ cookie: String, ticket: String? = nil) async throws {
        var accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        set(cookie, in: &accounts)
        if self == .quark {
            // The cookie is the login every other plugin uses, so a missing or failed ticket does not stop the save.
            if let ticket, !ticket.isEmpty {
                do { accounts.quarkServiceTicket = try await CloudDriveQRLogin.quarkMobileTicket(ticket, cookie: cookie) } catch {}
            }
            Diagnostics.shared.record(.info, "cloud.signin", "quark login saved mobileTicket=\(accounts.quarkServiceTicket != nil)")
        }
        try accounts.save()
        await LocalJarHost.shared.reloadCloudAccounts()
        await EmbeddedJarHost.shared.reloadCloudAccounts()
    }
}
#endif
