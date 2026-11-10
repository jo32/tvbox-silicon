import SwiftUI
import TVCore

/// Signing in to a live plugin's platform by scanning a code with the platform's own phone app
/// (`LivePluginQRSession`). A code that runs out is replaced by itself a few times; the platform's cookies
/// are kept once it confirms. On Apple TV this is the sign-in that needs no typing.
struct LivePluginQRSignIn: View {
    let plugin: LivePlugins.Installed
    let plan: LivePluginQRPlan
    var done: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var session: LivePluginQRSession?
    @State private var challenge: LivePluginQRChallenge?
    @State private var scanned = false
    @State private var expired = false
    @State private var error: String?
    @State private var attempt = 0
    /// The platform's request for a code it sent, in its words.
    @State private var verification: String?
    @State private var code = ""
    @State private var submitting = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: spacing) { picture; details }
            VStack(alignment: .leading, spacing: spacing) { picture; details }
        }
        #if os(tvOS)
        .frame(maxWidth: .infinity)
        #else
        .padding(.vertical, 10)
        #endif
        .task(id: attempt) { await run() }
        .onDisappear { if let session { Task { await session.cancel() } } }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Open the %@ app on another phone, scan this code, and confirm the sign-in.", plugin.name))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                // The plugin's own words: where the scanner is in that app.
                if let hint = challenge?.hint ?? Optional(plan.hint), !hint.isEmpty {
                    Text(hint).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            status
            if let verification { verify(verification) }
            if expired || error != nil {
                Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
            }
            #if os(iOS)
            if let challenge, !expired, error == nil { SaveCodeButton(text: challenge.content, app: plugin.name).id(challenge.content) }
            #endif
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private func verify(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.isEmpty { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            TextField(L10n.text("Verification Code"), text: $code)
                #if os(iOS)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                #endif
                #if !os(tvOS)
                .textFieldStyle(.roundedBorder)
                #endif
                .frame(maxWidth: 280)
            HStack(spacing: 12) {
                Button(L10n.text("Sign In")) { submit() }.settingsButton(prominent: true)
                    .disabled(submitting || code.trimmingCharacters(in: .whitespaces).isEmpty)
                if plan.resends {
                    Button(L10n.text("Send Again")) { Task { try? await session?.resend() } }.settingsButton()
                }
            }
        }
    }

    @ViewBuilder private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white)
            if let challenge, let image = QRCode.image(challenge.content) {
                Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                    .padding(codeSize / 12).opacity(expired || error != nil ? 0.15 : 1)
            } else if error == nil {
                ProgressView().tint(.black)
            }
            if expired {
                Image(systemName: "arrow.clockwise").font(.system(size: codeSize / 6, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
            }
        }
        .frame(width: codeSize, height: codeSize)
        // While waiting there is no button, and Back with nothing focused would leave the app.
        .loadingFocus(takeFocus: true) { dismiss() }
    }

    @ViewBuilder private var status: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
                .fixedSize(horizontal: false, vertical: true)
        } else if expired {
            Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
        } else if challenge != nil, verification == nil {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text(scanned ? "Scanned. Confirm the sign-in on your phone…" : "Waiting for you to scan…")).foregroundStyle(.secondary)
            }
        }
    }

    private func submit() {
        guard let session, !submitting else { return }
        submitting = true
        Task {
            defer { submitting = false }
            do { apply(try await session.submit(code: code.trimmingCharacters(in: .whitespaces))) }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Whether the sign-in is over (signed in, or stopped).
    @discardableResult private func apply(_ state: LivePluginQRState) -> Bool {
        switch state {
        case .waiting: return false
        case .scanned: scanned = true; return false
        case .verification(let message): verification = message; return false
        case .confirmed: done(); dismiss(); return true
        case .expired: expired = true; return true
        case .failed(let message): error = message.isEmpty ? L10n.text("The platform didn't accept this sign-in. Try again.") : message; return true
        }
    }

    private func run() async {
        challenge = nil; scanned = false; expired = false; error = nil; verification = nil; code = ""
        let session = LivePluginQRSession(plugin: plugin.pluginId, plan: plan)
        self.session = session
        let deadline = Date().addingTimeInterval(plan.timeout * Double(plan.maxRefreshes + 1))
        var refreshes = 0
        do {
            while !Task.isCancelled {
                let challenge = try await session.start()
                self.challenge = challenge; scanned = false; expired = false
                try await Task.sleep(for: .seconds(challenge.firstPollDelay))
                var ran = false
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(challenge.pollInterval))
                    // The code field is up: the platform is waiting for that, not for a scan.
                    if verification != nil { continue }
                    let state = try await session.poll()
                    if state == .expired { ran = true; break }
                    if apply(state) { return }
                    if let expires = challenge.expires, Date() > expires.addingTimeInterval(5), !scanned { ran = true; break }
                    if Date() > deadline { ran = true; refreshes = plan.maxRefreshes; break }
                }
                guard ran, refreshes < plan.maxRefreshes, Date() < deadline else { break }
                refreshes += 1
            }
            if !Task.isCancelled { expired = true }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        await session.cancel()
    }

    private var codeSize: CGFloat {
        #if os(tvOS)
        320
        #else
        220
        #endif
    }
    private var spacing: CGFloat {
        #if os(tvOS)
        72
        #else
        28
        #endif
    }
}

/// The QR sign-in as a page (Apple TV) or a sheet's content (iPhone, iPad, Mac).
struct LivePluginQRPage: View {
    let plugin: LivePlugins.Installed
    let plan: LivePluginQRPlan
    /// Offered on iPhone, iPad and Mac when the plugin also signs in on a web page.
    var useWebPage: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        TVSettingsSubpage(symbol: "qrcode", title: L10n.text("Sign In to %@", plugin.name)) {
            LivePluginQRSignIn(plugin: plugin, plan: plan)
        }
        #else
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LivePluginQRSignIn(plugin: plugin, plan: plan)
                    if let useWebPage {
                        Button(L10n.text("Use the Web Page Instead")) { dismiss(); useWebPage() }.settingsButton()
                    }
                }
                .padding(24)
            }
            .screenBackdrop()
            .navigationTitle(L10n.text("Sign In to %@", plugin.name))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 380, idealHeight: 420)
        #endif
        #endif
    }
}
