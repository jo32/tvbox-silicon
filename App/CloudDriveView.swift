#if os(macOS)
import SwiftUI
import WebKit
import TVCore

struct CloudDriveView: View {
    @State private var accounts = CloudDriveAccounts()
    @State private var login: CloudProvider?
    @State private var notice: String?
    @State private var error: String?
    @State private var saving = false
    @State private var showsManual = false
    var body: some View {
        SettingsPage(title: L10n.text("Cloud Drive Accounts")) {
            SettingsGroup(footer: L10n.text("Sign in on the provider's official page. Yingxia stores the login on this Mac and supplies it to the plugins you run.")) {
                ForEach(CloudProvider.allCases) { provider in
                    let signedIn = provider.isSignedIn(accounts)
                    SettingsRow(symbol: provider.symbol, tint: provider.tint, title: provider.name,
                                subtitle: L10n.text(signedIn ? "Signed In" : "Not Signed In")) {
                        if signedIn {
                            Button(L10n.text("Sign Out")) { provider.clear(&accounts); save() }.settingsButton()
                        } else {
                            Button(L10n.text("Sign In")) { login = provider }.settingsButton(prominent: true)
                        }
                    }
                }
            }
            SettingsGroup(title: L10n.text("Advanced"),
                          footer: L10n.text("You can also paste existing credentials. They are stored locally and supplied to the subscription plugins you run. Saving restarts plugin sessions.")) {
                DisclosureGroup(isExpanded: $showsManual) {
                    VStack(alignment: .leading, spacing: 10) {
                        credential(L10n.text("Quark Cookie"), $accounts.quarkCookie)
                        credential(L10n.text("UC Cookie"), $accounts.ucCookie)
                        credential(L10n.text("UC Token (optional)"), $accounts.ucToken)
                        credential(L10n.text("Aliyun Refresh Token"), $accounts.token)
                        Button(L10n.text("Save Accounts")) { save() }.settingsButton(prominent: true).disabled(saving)
                    }
                    .padding(.top, 10)
                } label: {
                    Text(L10n.text("Paste Credentials Manually")).font(.body)
                }
                .padding(14)
            }
            if let notice { Label(notice, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green) }
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.rose) }
        }
        .task { do { accounts = try CloudDriveAccounts.load() } catch { self.error = error.localizedDescription } }
        .sheet(item: $login) { provider in
            CloudLoginView(provider: provider) { cookie in
                provider.set(cookie, in: &accounts)
                save()
            }
        }
    }
    private func credential(_ title: String, _ value: Binding<String>) -> some View {
        SecureField(title, text: value)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)) }
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

enum CloudProvider: String, Identifiable, CaseIterable {
    case quark, uc
    var id: String { rawValue }
    var name: String { self == .quark ? L10n.text("Quark") : "UC" }
    var symbol: String { self == .quark ? "icloud.fill" : "externaldrive.fill" }
    var tint: Color { self == .quark ? .blue : .orange }
    var domain: String { self == .quark ? "quark.cn" : "uc.cn" }
    var url: URL { URL(string: self == .quark ? "https://pan.quark.cn/" : "https://drive.uc.cn/")! }
    func isSignedIn(_ accounts: CloudDriveAccounts) -> Bool {
        !(self == .quark ? accounts.quarkCookie : accounts.ucCookie).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func set(_ cookie: String, in accounts: inout CloudDriveAccounts) {
        if self == .quark { accounts.quarkCookie = cookie } else { accounts.ucCookie = cookie }
    }
    func clear(_ accounts: inout CloudDriveAccounts) {
        set("", in: &accounts)
        if self == .uc { accounts.ucToken = "" }
    }
    /// Saves a login captured outside the accounts page and restarts plugin sessions.
    func saveLogin(_ cookie: String) async throws {
        var accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        set(cookie, in: &accounts)
        try accounts.save()
        await LocalJarHost.shared.reloadCloudAccounts()
        await EmbeddedJarHost.shared.reloadCloudAccounts()
    }
    /// "Signed In · Quark" style summary for the Settings row.
    static func summary() -> String {
        let accounts = (try? CloudDriveAccounts.load()) ?? CloudDriveAccounts()
        let names = allCases.filter { $0.isSignedIn(accounts) }.map(\.name)
        return names.isEmpty ? L10n.text("Not Signed In") : L10n.text("Signed In") + " · " + names.joined(separator: ", ")
    }
}

struct CloudLoginView: View {
    let provider: CloudProvider
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    @State private var error: String?
    @State private var loading = true
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
                Button { error = nil; loading = true; webView.load(URLRequest(url: provider.url)) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .settingsButton().help(L10n.text("Retry")).accessibilityLabel(L10n.text("Retry"))
                Button(L10n.text("Cancel")) { dismiss() }.settingsButton().keyboardShortcut(.cancelAction)
                Button(L10n.text("Save Login")) {
                    webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        let selected = cookies.filter { cookie in
                            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                            return (domain == provider.domain || domain.hasSuffix("." + provider.domain)) && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
                        }
                        guard selected.contains(where: { $0.name == "__pus" && !$0.value.isEmpty }) else {
                            error = L10n.text("Finish signing in before saving the login."); return
                        }
                        var fields: [String: String] = [:]
                        for cookie in selected { fields[cookie.name] = cookie.value }
                        save(fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
                        dismiss()
                    }
                }
                .settingsButton(prominent: true).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            CloudLoginBrowser(webView: webView, url: provider.url, error: $error, loading: $loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 680)
    }
}
private struct CloudLoginBrowser: NSViewRepresentable {
    let webView: WKWebView
    let url: URL
    @Binding var error: String?
    @Binding var loading: Bool
    func makeCoordinator() -> Coordinator { Coordinator(error: $error, loading: $loading) }
    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var error: String?
        @Binding var loading: Bool
        init(error: Binding<String?>, loading: Binding<Bool>) { _error = error; _loading = loading }
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
#endif
