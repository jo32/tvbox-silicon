#if os(iOS)
import Photos
import SwiftUI
import TVCore
import WebKit

/// Sign in on the service's own page, in a private web view: a phone can't scan a code on its own
/// screen. The sheet closes by itself once the page has signed in and the sign-in is saved. `code`
/// is the scan-a-code sign-in, for signing in with the app on another phone.
struct WebSignInView<Code: View>: View {
    let service: WebSignIn
    let signedIn: () -> Void
    @ViewBuilder let code: () -> Code
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Desktop pages forbid zooming; the sheet zooms to their sign-in box, and people can too.
        configuration.ignoresViewportScaleLimits = true
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    @State private var error: String?
    @State private var loading = true
    @State private var saving = false
    @State private var showsCode = false
    /// Quark's approved sign-in ticket, when the page opens one.
    @State private var ticket: String?

    init(service: WebSignIn, showingCode: Bool = false, signedIn: @escaping () -> Void, @ViewBuilder code: @escaping () -> Code) {
        self.service = service; self.signedIn = signedIn; self.code = code
        _showsCode = State(initialValue: showingCode)
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsCode { code() } else { page }
            }
            .navigationTitle(service.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                if showsCode {
                    ToolbarItem(placement: .primaryAction) {
                        Button(L10n.text("Sign In Here")) { showsCode = false }.accessibilityIdentifier("webSignIn.page")
                    }
                }
            }
        }
        .task { await watch() }
    }

    private var page: some View {
        VStack(spacing: 0) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
            WebSignInBrowser(webView: webView, service: service, error: $error, loading: $loading, ticket: $ticket)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if saving {
                        HStack(spacing: 10) { ProgressView(); Text(L10n.text("Signing In…")) }
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .glassSurface(.regular, in: Capsule())
                    }
                }
                .overlay(alignment: .top) {
                    if loading && !saving { ProgressView().padding(12) }
                }
            if Code.self != EmptyView.self {
                Button { showsCode = true } label: {
                    Label(L10n.text("Scan a Code with Another Phone"), systemImage: "qrcode")
                }
                .settingsButton()
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .accessibilityIdentifier("webSignIn.code")
            }
        }
    }

    /// Checks the page's cookies (and Aliyun's storage) every second until it has signed in.
    private func watch() async {
        var followedUp = false
        var waitedForTicket = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            var stored: String?
            if let storage = service.storage, let host = webView.url?.host, storage.hosts.contains(host) {
                stored = try? await webView.evaluateJavaScript("localStorage.getItem('\(storage.key)')") as? String
            }
            if let result = service.result(cookies: cookies, stored: stored) {
                // Quark sets its cookie as the ticket reaches the page; give the ticket a moment.
                if service.catchesTicket, ticket == nil, waitedForTicket < 4 { waitedForTicket += 1; continue }
                saving = true
                do {
                    try await service.save(result, ticket: ticket)
                    signedIn()
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                    saving = false
                }
                return
            }
            if !followedUp, !loading, service.needsFollowUp(cookies: cookies), let url = service.followUp {
                followedUp = true
                webView.load(URLRequest(url: url))
            }
        }
    }
}

extension WebSignInView where Code == EmptyView {
    init(service: WebSignIn, signedIn: @escaping () -> Void) {
        self.init(service: service, signedIn: signedIn) { EmptyView() }
    }
}

extension WebSignIn {
    var name: String {
        switch self {
        case .bilibili: L10n.text("Bilibili")
        case .quark: L10n.text("Quark")
        case .uc: "UC"
        case .baidu: L10n.text("Baidu Netdisk")
        case .aliyun: L10n.text("Aliyun Drive")
        }
    }
    var title: String {
        switch self {
        case .bilibili: L10n.text("Sign In to Bilibili")
        case .quark: L10n.text("Sign In to Quark")
        case .uc: L10n.text("Sign In to UC")
        case .baidu, .aliyun: L10n.text("Sign In to %@", name)
        }
    }
}

private struct WebSignInBrowser: UIViewRepresentable {
    let webView: WKWebView
    let service: WebSignIn
    @Binding var error: String?
    @Binding var loading: Bool
    @Binding var ticket: String?

    func makeCoordinator() -> Coordinator { Coordinator(service: service, error: $error, loading: $loading, ticket: $ticket) }
    func makeUIView(context: Context) -> WKWebView {
        webView.customUserAgent = service.userAgent
        let content = webView.configuration.userContentController
        if let box = service.signInBox {
            content.add(context.coordinator, name: Self.boxMessage)
            content.addUserScript(WKUserScript(source: Self.findBox(box), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if service.catchesTicket {
            content.add(context.coordinator, name: Self.ticketMessage)
            content.addUserScript(WKUserScript(source: Self.catchTicket, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: service.page))
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    /// Switching to the code and back makes the page again.
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: boxMessage)
        view.configuration.userContentController.removeScriptMessageHandler(forName: ticketMessage)
        view.configuration.userContentController.removeAllUserScripts()
    }

    static let boxMessage = "signInBox"
    static let ticketMessage = "signInTicket"

    /// Reports Quark's sign-in ticket: from the sign-in frame's message to the page, or from the page's
    /// background request to /account/info?st=, which never shows as a navigation.
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

    /// Reports where the sign-in box is once the page has drawn it. The desktop pages lay out at
    /// 1,260 points and scale themselves to the window, so on a phone the box is too small to use.
    static func findBox(_ box: String) -> String {
        let selector = String(decoding: (try? JSONEncoder().encode(box)) ?? Data(), as: UTF8.self)
        return """
        (function () {
          var tries = 0;
          var timer = setInterval(function () {
            var box = document.querySelector(\(selector));
            // After the page has loaded, when WebKit has fitted it to the window.
            if ((!box || document.readyState !== 'complete') && ++tries < 80) return;
            clearInterval(timer);
            if (!box) return;
            setTimeout(function () {
              var frame = box.getBoundingClientRect();
              window.webkit.messageHandlers.\(boxMessage).postMessage({ x: frame.left + window.scrollX, y: frame.top + window.scrollY,
                width: frame.width, height: frame.height, page: document.documentElement.scrollWidth });
            }, 600);
          }, 250);
        })();
        """
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let service: WebSignIn
        @Binding var error: String?
        @Binding var loading: Bool
        @Binding var ticket: String?
        init(service: WebSignIn, error: Binding<String?>, loading: Binding<Bool>, ticket: Binding<String?>) {
            self.service = service; _error = error; _loading = loading; _ticket = ticket
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
            if let found = service.serviceTicket(in: url) { ticket = found }
            // The pages offer to open their own apps (bilibili://, baiduboxapp://); signing in stays here.
            if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "blob", "data", "javascript"].contains(scheme) {
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
        /// Keeps the ticket `catchTicket` reported, or zooms to the sign-in box `findBox` reported (in page points).
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == WebSignInBrowser.ticketMessage {
                if let found = message.body as? String, !found.isEmpty, found != ticket {
                    ticket = found
                    Diagnostics.shared.record(.info, "cloud.signin", "\(service.rawValue) page passed its sign-in ticket")
                }
                return
            }
            guard let body = message.body as? [String: Any], let scrollView = message.webView?.scrollView,
                  let x = (body["x"] as? NSNumber)?.doubleValue, let y = (body["y"] as? NSNumber)?.doubleValue,
                  let width = (body["width"] as? NSNumber)?.doubleValue, let height = (body["height"] as? NSNumber)?.doubleValue,
                  let page = (body["page"] as? NSNumber)?.doubleValue, page > 0, width > 0, scrollView.zoomScale > 0 else { return }
            // zoom(to:) takes the unzoomed content's coordinates.
            let scale = scrollView.contentSize.width / scrollView.zoomScale / page
            scrollView.zoom(to: CGRect(x: (x - 12) * scale, y: (y - 12) * scale, width: (width + 24) * scale, height: (height + 24) * scale), animated: true)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { failed(failure) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { failed(failure) }
        private func failed(_ failure: Error) {
            loading = false
            // A page that moves on before it finished loading, or a link to an app, isn't a failure.
            let code = (failure as NSError).code, domain = (failure as NSError).domain
            if (domain == NSURLErrorDomain && code == NSURLErrorCancelled) || (domain == "WebKitErrorDomain" && code == 102) { return }
            error = failure.localizedDescription
        }
    }
}

/// Saves a sign-in code to Photos. The drive's app on this phone scans it from there (Scan, then the
/// photo library), and it can be sent to another phone.
struct SaveCodeButton: View {
    /// The text to encode, or the address of a code image (Baidu).
    let text: String?
    var image: URL? = nil
    let app: String
    @State private var saved = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { Task { await save() } } label: {
                Label(L10n.text(saved ? "Saved to Photos" : "Save Code to Photos"), systemImage: saved ? "checkmark" : "square.and.arrow.down")
            }
            .settingsButton()
            .disabled(saved || (text == nil && image == nil))
            .accessibilityIdentifier("signIn.saveCode")
            #if DEBUG
            // `-qaSaveCode 1` saves the code as soon as it shows, for checking without a tap.
            .task { if UserDefaults.standard.bool(forKey: "qaSaveCode") { await save() } }
            #endif
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Brand.amber)
                    .fixedSize(horizontal: false, vertical: true)
            } else if saved {
                Text(L10n.text("In the %@ app, tap Scan, then choose this photo.", app))
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() async {
        error = nil
        var picture: UIImage?
        if let text, let code = QRCode.image(text, scale: 12) {
            picture = UIImage(cgImage: code)
        } else if let image, let data = try? await URLSession.shared.data(from: image).0 {
            picture = UIImage(data: data)
        }
        guard let picture else { error = L10n.text("Couldn't get a sign-in code. Try again."); return }
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            error = L10n.text("Allow Yingxia to add photos in Settings, then try again."); return
        }
        do {
            try await Self.addToPhotos(picture)
            saved = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Photos runs the change on its own queue: the closure must not belong to the main actor.
    nonisolated private static func addToPhotos(_ picture: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: picture) }
    }
}

/// A CatPawOpen bundle's config center, opened in the app. The bundle serves it from inside the app, so in Safari it
/// stopped answering as soon as iOS suspended the app (#311). `address` asks the bundle for it again: iOS takes back a
/// suspended app's listening sockets, and the bundle then answers on a new port.
struct ConfigCenterView: View {
    let address: () async -> URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    @State private var page: URL?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(Brand.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                }
                ConfigCenterBrowser(webView: webView, error: $error, loading: $loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { if loading { ProgressView().padding(12) } }
            }
            .navigationTitle(L10n.text("Config Center"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await open(reload: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(L10n.text("Refresh"))
                }
            }
        }
        .task { await open(reload: true) }
        // Back from another app (copying a password, say): the page moves to the bundle's new port, if it has one.
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await open(reload: false) } } }
    }

    private func open(reload: Bool) async {
        guard let fresh = await address() else {
            loading = false
            error = L10n.text("The plugin returned no content. Try another source.")
            return
        }
        guard let page, var current = webView.url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              current.host == fresh.host() else {
            page = fresh
            webView.load(URLRequest(url: fresh))
            return
        }
        // Where the viewer is in the page, on the port the bundle answers on now.
        let moved = page.port != fresh.port
        current.port = fresh.port
        self.page = fresh
        if moved, let url = current.url { webView.load(URLRequest(url: url)) } else if reload { webView.reload() }
    }
}

private struct ConfigCenterBrowser: UIViewRepresentable {
    let webView: WKWebView
    @Binding var error: String?
    @Binding var loading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(error: $error, loading: $loading) }
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        return webView
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        @Binding var error: String?
        @Binding var loading: Bool
        init(error: Binding<String?>, loading: Binding<Bool>) { _error = error; _loading = loading }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) { failed(failure) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) { failed(failure) }
        private func failed(_ failure: Error) {
            loading = false
            let code = (failure as NSError).code, domain = (failure as NSError).domain
            if (domain == NSURLErrorDomain && code == NSURLErrorCancelled) || (domain == "WebKitErrorDomain" && code == 102) { return }
            error = failure.localizedDescription
        }

        /// Links that open a new window open here.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
        // A web view shows no alert, confirm or prompt of its own; config pages ask with them ("确定删除？").
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            present(message, on: webView, actions: [(L10n.text("OK"), .default, completionHandler)], cancel: completionHandler)
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            present(message, on: webView, actions: [(L10n.text("Cancel"), .cancel, { completionHandler(false) }),
                                                    (L10n.text("OK"), .default, { completionHandler(true) })],
                    cancel: { completionHandler(false) })
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: L10n.text("Cancel"), style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: L10n.text("OK"), style: .default) { _ in completionHandler(alert.textFields?.first?.text ?? "") })
            guard let host = Self.presenter(for: webView) else { return completionHandler(nil) }
            host.present(alert, animated: true)
        }

        private func present(_ message: String, on webView: WKWebView,
                             actions: [(String, UIAlertAction.Style, @MainActor () -> Void)], cancel: @MainActor () -> Void) {
            guard let host = Self.presenter(for: webView) else { return cancel() }
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            for (title, style, action) in actions { alert.addAction(UIAlertAction(title: title, style: style) { _ in action() }) }
            host.present(alert, animated: true)
        }

        /// The sheet's controller: the frontmost one above the web view's window.
        private static func presenter(for webView: WKWebView) -> UIViewController? {
            var controller = webView.window?.rootViewController
            while let next = controller?.presentedViewController, !next.isBeingDismissed { controller = next }
            return controller
        }
    }
}
#endif
