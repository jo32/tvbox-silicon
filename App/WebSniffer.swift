#if os(macOS) || os(iOS)

import TVCore
import WebKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Hidden-page sniff. `SniffRules.decision` decides which address wins.
///
/// WKWebView has no `shouldInterceptRequest`. The same five steps run on addresses
/// posted by the document-start script (`fetch`, `XMLHttpRequest`, and the media
/// `src` setter) and on navigations. A script-reported address has no browser
/// request headers, so success uses the headers that opened the page. A navigation
/// uses that navigation's headers. Either way, Cookie and User-Agent overlay those
/// headers, compared without case. Referer is not invented.
///
/// The 15 second clock starts in `sniff`. A child page does not add time. The
/// Cloudflare sheet does not pause or restart it. Closing that sheet fails the sniff.
/// Certificate errors are not ignored: WebKit fails the load, and the sniff fails
/// when no page is still loading. Spider `isVideoFormat` is not called.
///
/// Each page view is attached to a clear, click-through window. WebKit does not
/// load or run JavaScript in a view that is not in a window, so a free-floating
/// web view waits out the clock without ever seeing a media address.
public final class WKWebSniffer: WebSniffing, @unchecked Sendable {
    public init() {}
    public func sniff(url: String, headers: [String: String], click: String, detect: Bool, ads: [String], rules: [SniffRule]) async -> (url: URL, headers: [String: String])? {
        let host = URL(string: url)?.host() ?? "-"
        Diagnostics.shared.record(.info, "sniff", "start host=\(host)")
        let box = SniffBox()
        let session = await MainActor.run {
            SniffSession(box: box, url: url, headers: headers, click: click, detect: detect, ads: ads, rules: rules)
        }
        await session.start()
        let found = await withTaskCancellationHandler {
            await box.result
        } onCancel: {
            Task { @MainActor in session.stop() }
        }
        if let found {
            Diagnostics.shared.record(.info, "sniff", "hit host=\(found.url.host() ?? host)")
        } else {
            Diagnostics.shared.record(.warning, "sniff", "miss host=\(host)")
        }
        return found
    }
}

private final class SniffBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(url: URL, headers: [String: String])?, Never>?
    private var value: (url: URL, headers: [String: String])?
    private var done = false
    var result: (url: URL, headers: [String: String])? {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if done {
                    let value = self.value
                    lock.unlock()
                    continuation.resume(returning: value)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
    func resume(_ value: (url: URL, headers: [String: String])?) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let continuation = self.continuation
        self.value = value
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

@MainActor
private final class SniffSession: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private let box: SniffBox
    private let click: String
    private let ads: [String]
    private let rules: [SniffRule]
    private let store = WKWebsiteDataStore.nonPersistent()
    fileprivate let stage = SniffStage()
    private var pages: [SniffPage] = []
    /// Every address a page of this session followed. A hook and a navigation can report the same
    /// address, and each child page sniffs too, so the cap is for the whole session.
    private var followed = Set<String>()
    private static let followLimit = 5
    private var timeout: Task<Void, Never>?
    private var challenge: SniffChallenge?
    private var stopped = false

    init(box: SniffBox, url: String, headers: [String: String], click: String, detect: Bool, ads: [String], rules: [SniffRule]) {
        self.box = box
        self.click = click
        self.ads = ads
        self.rules = rules
        super.init()
        pages = [SniffPage(session: self, url: url, detect: detect, headers: headers)]
    }

    func start() {
        guard timeout == nil else { return }
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self?.stop()
        }
        pages.first?.load()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        challenge?.dismiss()
        challenge = nil
        for page in pages { page.close() }
        pages = []
        stage.close()
        box.resume(nil)
    }

    func succeed(url: String, headers reported: [String: String], page: SniffPage) {
        guard !stopped, let media = URL(string: url) else { return }
        stopped = true
        timeout?.cancel()
        challenge?.dismiss()
        challenge = nil
        let store = self.store
        let agent = page.webView.customUserAgent ?? ""
        // A script report has no browser request headers. Use the headers that opened this page.
        let opened = reported.isEmpty ? page.headers : reported
        Task {
            let cookies = await store.httpCookieStore.allCookies()
            let host = media.host ?? ""
            let cookie = cookies.filter { item in
                let domain = item.domain.hasPrefix(".") ? String(item.domain.dropFirst()) : item.domain
                return host == domain || host.hasSuffix("." + domain)
            }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            var result = opened
            Self.overlay(&result, name: "Cookie", value: cookie)
            Self.overlay(&result, name: "User-Agent", value: agent)
            for page in self.pages { page.close() }
            self.pages = []
            self.stage.close()
            self.box.resume((url: media, headers: result))
        }
    }

    func decide(url: String, page: SniffPage, reported: [String: String]) -> String {
        if stopped { return "block" }
        switch SniffRules.decision(url: url, pageURL: page.url, detect: page.detect, followedCount: page.followed.count, ads: ads, rules: rules) {
        case .allow: return "allow"
        case .block: return "block"
        case .video:
            succeed(url: url, headers: reported, page: page)
            return "block"
        case .follow:
            guard !followed.contains(url), followed.count < Self.followLimit else { return "allow" }
            followed.insert(url)
            page.followed.insert(url)
            let child = SniffPage(session: self, url: url, detect: !url.contains("player/?url="), headers: reported.isEmpty ? page.headers : reported)
            pages.append(child)
            child.load()
            return "allow"
        }
    }

    func pageFinished(_ page: SniffPage) {
        guard !stopped else { return }
        Task { await runPageActions(page) }
    }

    func pageFailed(_ page: SniffPage) {
        pages.removeAll { $0 === page }
        if pages.isEmpty { stop() }
    }

    func showChallenge(_ webView: WKWebView) {
        guard challenge == nil, !stopped else { return }
        challenge = SniffChallenge(webView: webView) { [weak self] in self?.stop() }
    }

    private func runPageActions(_ page: SniffPage) async {
        guard !stopped else { return }
        let flag = (try? await page.webView.evaluateJavaScript(SniffRules.cloudflareCheck))
        if (flag as? Bool) == true || (flag as? Int) == 1 || (flag as? String) == "true" {
            showChallenge(page.webView)
            return
        }
        for script in SniffRules.pageScripts(pageURL: page.url, click: click, rules: rules) where !script.isEmpty && !stopped {
            _ = try? await page.webView.evaluateJavaScript(script)
        }
        for selector in SniffRules.pageClicks(pageURL: page.url, rules: rules) {
            var attempt = 0
            while attempt < 20 && !stopped {
                let encoded = (try? JSONSerialization.data(withJSONObject: [selector]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                let literal = String(encoded.dropFirst().dropLast())
                let js = "(function(){var e=document.querySelector(\(literal));if(!e)return false;e.click();return true;})()"
                if (try? await page.webView.evaluateJavaScript(js)) as? Bool == true { break }
                attempt += 1
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private static func overlay(_ headers: inout [String: String], name: String, value: String) {
        guard !value.isEmpty else { return }
        headers = headers.filter { $0.key.caseInsensitiveCompare(name) != .orderedSame }
        headers[name] = value
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard !stopped, let page = pages.first(where: { $0.webView == message.webView }) ?? pages.first else {
            return (["action": "allow"], nil)
        }
        return (["action": decide(url: message.body as? String ?? "", page: page, reported: [:])], nil)
    }

    fileprivate func makeWebView(page: SniffPage) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.hook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.addScriptMessageHandler(self, contentWorld: .page, name: "sniff")
        configuration.userContentController = content
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        if let agent = page.headers.first(where: { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame })?.value {
            webView.customUserAgent = agent
        }
        return webView
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let page = pages.first(where: { $0.webView == webView }), let url = navigationAction.request.url?.absoluteString else {
            decisionHandler(.allow)
            return
        }
        let action = decide(url: url, page: page, reported: navigationAction.request.allHTTPHeaderFields ?? [:])
        decisionHandler(action == "block" ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse,
           http.value(forHTTPHeaderField: "cf-mitigated")?.caseInsensitiveCompare("challenge") == .orderedSame {
            showChallenge(webView)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let page = pages.first(where: { $0.webView == webView }) else { return }
        pageFinished(page)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        noteLoadFailure(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        noteLoadFailure(webView, error: error)
    }

    /// A cancelled navigation is one this sniffer rejected. The page that is already open keeps sniffing.
    private func noteLoadFailure(_ webView: WKWebView, error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        guard let page = pages.first(where: { $0.webView == webView }) else { return }
        pageFailed(page)
    }

    private static let hook = #"""
    (function () {
      function absolute(url) {
        try { return new URL(String(url), location.href).href; } catch (e) { return String(url || ""); }
      }
      function decide(url) {
        var target = absolute(url);
        if (!target) return Promise.resolve({ action: "allow" });
        try { return window.webkit.messageHandlers.sniff.postMessage(target); }
        catch (e) { return Promise.resolve({ action: "allow" }); }
      }
      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input, init) {
          var raw = typeof input === "string" ? input : (input && input.url);
          return decide(raw).then(function (answer) {
            if (answer && answer.action === "block") return new Response(new Uint8Array(), { status: 200 });
            return originalFetch.call(window, input, init);
          });
        };
      }
      var originalOpen = XMLHttpRequest.prototype.open;
      var originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__sniffURL = url;
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        var xhr = this;
        decide(xhr.__sniffURL).then(function (answer) {
          if (answer && answer.action === "block") xhr.abort();
          else originalSend.call(xhr, body);
        });
      };
      var media = window.HTMLMediaElement && Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
      if (media && media.set && media.get) {
        Object.defineProperty(HTMLMediaElement.prototype, "src", {
          configurable: true,
          get: function () { return media.get.call(this); },
          set: function (value) {
            var target = this;
            if (target.__sniffBypass) { media.set.call(target, value); return; }
            decide(value).then(function (answer) {
              if (answer && answer.action === "block") return;
              target.__sniffBypass = true;
              try { media.set.call(target, value); } finally { target.__sniffBypass = false; }
            });
          }
        });
      }
    })();
    """#
}

@MainActor
private final class SniffPage {
    let url: String
    let detect: Bool
    let headers: [String: String]
    var followed = Set<String>()
    private let session: SniffSession
    private var webViewStorage: WKWebView?
    var webView: WKWebView {
        if let webViewStorage { return webViewStorage }
        let created = session.makeWebView(page: self)
        session.stage.attach(created)
        webViewStorage = created
        return created
    }
    init(session: SniffSession, url: String, detect: Bool, headers: [String: String]) {
        self.session = session
        self.url = url
        self.detect = detect
        self.headers = headers
    }
    func load() {
        guard let address = URL(string: url) else { session.pageFailed(self); return }
        let view = webView
        Task {
            if let raw = headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame })?.value {
                for part in raw.split(separator: ";") {
                    let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard pieces.count == 2, let host = address.host,
                          let cookie = HTTPCookie(properties: [.name: pieces[0], .value: pieces[1], .domain: host, .path: "/"]) else { continue }
                    await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
            }
            var request = URLRequest(url: address)
            for (key, value) in headers where key.caseInsensitiveCompare("Cookie") != .orderedSame && key.caseInsensitiveCompare("User-Agent") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: key)
            }
            view.load(request)
        }
    }
    func close() {
        // The content controller keeps its message handler, the session, alive.
        webViewStorage?.configuration.userContentController.removeAllScriptMessageHandlers()
        webViewStorage?.stopLoading()
        webViewStorage?.removeFromSuperview()
        webViewStorage = nil
    }
}

/// A clear window that keeps sniff pages in a real view hierarchy. Clicks pass through,
/// and the window is not key, so playback stays in front. WebKit still loads it: a view
/// with no window never starts its navigation.
@MainActor
private final class SniffStage {
    #if os(macOS)
    private let window: NSWindow
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    #else
    private let window: UIWindow?
    private let container = UIView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
    #endif
    private var closed = false

    init() {
        #if os(macOS)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.alphaValue = 0
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.frame.minX, y: screen.frame.minY))
        }
        window.orderFrontRegardless()
        #else
        if let scene = UIApplication.shared.appWindowScene {
            let window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            controller.view = container
            window.rootViewController = controller
            window.windowLevel = .normal
            window.isUserInteractionEnabled = false
            window.alpha = 0
            window.isHidden = false
            self.window = window
        } else {
            window = nil
        }
        #endif
    }

    func attach(_ webView: WKWebView) {
        guard !closed else { return }
        #if os(macOS)
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        #else
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        container.addSubview(webView)
    }

    func close() {
        guard !closed else { return }
        closed = true
        #if os(macOS)
        window.orderOut(nil)
        #else
        window?.isHidden = true
        #endif
    }
}

#if os(macOS)
@MainActor
private final class SniffChallenge: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void
    private var closed = false
    init(webView: WKWebView, onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Cloudflare"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        onClose()
    }
    func dismiss() {
        closed = true
        window.orderOut(nil)
    }
}
#else
@MainActor
private final class SniffChallenge {
    private var window: UIWindow?
    init(webView: WKWebView, onClose: @escaping () -> Void) {
        guard let scene = UIApplication.shared.appWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        window.windowLevel = .alert
        webView.frame = controller.view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(webView)
        let close = UIButton(type: .close)
        close.frame = CGRect(x: 16, y: 16, width: 32, height: 32)
        close.addAction(UIAction { _ in onClose() }, for: .touchUpInside)
        controller.view.addSubview(close)
        window.makeKeyAndVisible()
        self.window = window
    }
    func dismiss() { window?.isHidden = true; window = nil }
}
#endif

#endif
