import SwiftUI
import TVCore
#if !os(tvOS)
import WebKit
#endif

/// The Douyin account, which Douyin requires for live search. Douyin signs in only on its own web
/// page: iPhone, iPad and Mac open it in a web view, and Apple TV, which has no web view, shows a
/// code that the iPhone app scans to send its sign-in over the local network.
struct DouyinAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = DouyinAccount.load()
    @State private var attempt = 0
    @State private var error: String?
    #if os(tvOS)
    @State private var link: DouyinHandoff.Link?
    #else
    @State private var signingIn = false
    #endif

    var body: some View {
        SettingsPage(title: L10n.text("Douyin Account"), symbol: "music.note") {
            if account.signedIn {
                SettingsGroup(footer: L10n.text("Douyin Live search uses this sign-in. It stays on this device.")) {
                    SettingsRow(symbol: "person.crop.circle.fill", tint: .black, title: account.name.isEmpty ? L10n.text("Signed In") : account.name,
                                subtitle: L10n.text("Signed In")) {
                        Button(L10n.text("Sign Out")) { DouyinAccount.signOut(); account = DouyinAccount(); attempt += 1 }.settingsButton()
                    }
                }
            } else {
                #if os(tvOS)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 72) { code; handoffDetails }
                    VStack(alignment: .leading, spacing: 72) { code; handoffDetails }
                }
                .frame(maxWidth: .infinity)
                #else
                SettingsGroup(footer: L10n.text("Douyin answers live searches only for signed-in accounts. Sign in on Douyin's own page with a text-message code, or by scanning its code with the Douyin app on another phone.")) {
                    SettingsRow(symbol: "person.crop.circle.badge.questionmark", tint: .gray, title: L10n.text("Not Signed In"),
                                subtitle: L10n.text("Sign in to search Douyin Live.")) {
                        Button(L10n.text("Sign In")) { signingIn = true }.settingsButton(prominent: true)
                    }
                }
                #endif
            }
            #if os(iOS)
            SettingsGroup {
                SettingsRow(symbol: "appletv.fill", tint: .gray, title: L10n.text("Signing In on Apple TV"),
                            subtitle: L10n.text("Apple TV can't show Douyin's sign-in page. Sign in here first, then open Settings > Douyin on the Apple TV and scan its code with this iPhone's Camera.")) {
                    EmptyView()
                }
            }
            #endif
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.amber) }
        }
        .task(id: attempt) { await run() }
        #if !os(tvOS)
        .sheet(isPresented: $signingIn) { DouyinLoginView { account = $0 } }
        #endif
    }

    private func run() async {
        error = nil
        if account.signedIn {
            // Shows the nickname, and notices a sign-in Douyin no longer accepts.
            var current = account
            if await current.refresh() { if current != account { try? current.save(); account = current } }
            else { DouyinAccount.signOut(); account = DouyinAccount(); attempt += 1 }
            return
        }
        #if os(tvOS)
        link = nil
        let receiver = DouyinHandoff.Receiver()
        defer { receiver.stop() }
        let (arrivals, continuation) = AsyncStream.makeStream(of: DouyinAccount.self)
        do {
            link = try await receiver.start { continuation.yield($0) }
        } catch {
            self.error = error.localizedDescription
            return
        }
        // Ends when the page closes (the task is cancelled).
        for await received in arrivals {
            var current = received
            _ = await current.refresh()
            do { try current.save(); account = current } catch { self.error = error.localizedDescription }
            return
        }
        #endif
    }

    #if os(tvOS)
    private var handoffDetails: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Sign In to Douyin")).font(.title2.weight(.bold))
                Text(L10n.text("Douyin signs in only on its own web page, which Apple TV can't show. Sign in with Yingxia on your iPhone instead:"))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    step(1, L10n.text("On your iPhone, open Yingxia, go to Settings > Douyin, and sign in."))
                    step(2, L10n.text("Scan this code with the iPhone's Camera and open it in Yingxia."))
                    step(3, L10n.text("Tap Send to Apple TV."))
                }
            }
            if error == nil && link != nil {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.text("Waiting for your iPhone…")).foregroundStyle(.secondary)
                }
            }
            if error != nil {
                Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.body.weight(.bold).monospacedDigit()).foregroundStyle(.secondary)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white)
            if let link, let image = QRCode.image(link.url.absoluteString) {
                Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit().padding(320 / 12)
            } else if error == nil {
                ProgressView().tint(.black)
            }
        }
        .frame(width: 320, height: 320)
        // While waiting there is no button, and Back with nothing focused would leave the app.
        .loadingFocus(takeFocus: true) { dismiss() }
    }
    #endif
}

extension DouyinAccount {
    /// The Settings row's subtitle.
    var summary: String { signedIn ? (name.isEmpty ? L10n.text("Signed In") : name) : L10n.text("Not Signed In") }
}

/// Atop Douyin Live while signed out: signing in adds search.
struct DouyinSignInBanner: View {
    var body: some View {
        HStack(spacing: 16) {
            if let douyin = LivePlatform(rawValue: "douyin") { LivePlatformMark(platform: douyin, size: 44) }
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Sign In to Douyin")).font(.headline)
                Text(L10n.text("Douyin answers live searches only for signed-in accounts."))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            RouteLink { DouyinAccountView() } label: { Text(L10n.text("Sign In")) }.controlButton(prominent: true)
        }
        .padding(16)
        .contentPanel()
    }
}

#if !os(tvOS)
/// Douyin's own sign-in, in a private web view. Signing in is detected from the session cookie,
/// so the sheet closes by itself once Douyin has signed the account in.
struct DouyinLoginView: View {
    let signedIn: (DouyinAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        // The desktop page offers text-message and code sign-in; the phone page sends people to the app.
        view.customUserAgent = DouyinAccount.userAgent
        return view
    }()
    @State private var error: String?
    @State private var loading = true
    static let page = URL(string: "https://www.douyin.com/")!

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let douyin = LivePlatform(rawValue: "douyin") { LivePlatformMark(platform: douyin, size: 28) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.text("Sign In to Douyin")).font(.headline)
                    Text(L10n.text("Use Douyin's Log In button on the page.")).font(.caption).foregroundStyle(.secondary)
                }
                if loading { ProgressView().controlSize(.small).padding(.leading, 4) }
                Spacer()
                Button { error = nil; loading = true; webView.load(URLRequest(url: Self.page)) } label: { Image(systemName: "arrow.clockwise") }
                    .settingsButton().accessibilityLabel(L10n.text("Retry"))
                Button(L10n.text("Cancel")) { dismiss() }.settingsButton().keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            Divider()
            DouyinLoginBrowser(webView: webView, url: Self.page, error: $error, loading: $loading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(width: 1000, height: 720)
        #endif
        .task {
            // Douyin sets `sessionid` once the sign-in completes, whichever way it was done.
            while !Task.isCancelled {
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                if var account = DouyinAccount.from(cookies: cookies) {
                    _ = await account.refresh()
                    do {
                        try account.save()
                        signedIn(account)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private final class DouyinLoginCoordinator: NSObject, WKNavigationDelegate {
    @Binding var error: String?
    @Binding var loading: Bool
    init(error: Binding<String?>, loading: Binding<Bool>) { _error = error; _loading = loading }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { loading = false; error = failure.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { loading = false; error = failure.localizedDescription }
}

#if os(macOS)
private struct DouyinLoginBrowser: NSViewRepresentable {
    let webView: WKWebView
    let url: URL
    @Binding var error: String?
    @Binding var loading: Bool
    func makeCoordinator() -> DouyinLoginCoordinator { DouyinLoginCoordinator(error: $error, loading: $loading) }
    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
private struct DouyinLoginBrowser: UIViewRepresentable {
    let webView: WKWebView
    let url: URL
    @Binding var error: String?
    @Binding var loading: Bool
    func makeCoordinator() -> DouyinLoginCoordinator { DouyinLoginCoordinator(error: $error, loading: $loading) }
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
#endif

#if os(iOS)
/// Opened by scanning an Apple TV's Douyin code: sends this iPhone's Douyin sign-in to that TV.
struct DouyinHandoffView: View {
    let link: DouyinHandoff.Link
    @Environment(\.dismiss) private var dismiss
    @State private var account = DouyinAccount.load()
    @State private var signingIn = false
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: sent ? "checkmark.circle.fill" : "appletv.fill")
                    .font(.system(size: 56)).foregroundStyle(sent ? Color.green : Color.secondary)
                Text(L10n.text("Sign In on Apple TV")).font(.title2.weight(.bold))
                Text(message).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Brand.amber).multilineTextAlignment(.center)
                }
                if sent {
                    Button(L10n.text("Done")) { dismiss() }.controlButton(prominent: true)
                } else if account.signedIn {
                    Button { send() } label: {
                        HStack(spacing: 8) { if sending { ProgressView() }; Text(L10n.text("Send to Apple TV")) }
                    }
                    .controlButton(prominent: true).disabled(sending)
                } else {
                    Button(L10n.text("Sign In to Douyin")) { signingIn = true }.controlButton(prominent: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 480)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
        }
        .sheet(isPresented: $signingIn) { DouyinLoginView { account = $0 } }
    }

    private var message: String {
        if sent { return L10n.text("Your Apple TV is now signed in to Douyin.") }
        if account.signedIn {
            let name = account.name.isEmpty ? L10n.text("Douyin") : account.name
            return L10n.text("Send %@'s sign-in to the Apple TV at %@? It goes only to that TV, encrypted.", name, link.host)
        }
        return L10n.text("Sign in to Douyin on this iPhone first, then send the sign-in to the Apple TV.")
    }

    private func send() {
        sending = true; error = nil
        Task {
            defer { sending = false }
            do { try await DouyinHandoff.send(account, to: link); sent = true }
            catch { self.error = error.localizedDescription }
        }
    }
}
#endif
