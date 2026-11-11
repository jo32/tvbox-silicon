import SwiftUI
import TVCore

/// The account of a recommended source that takes a sign-in: sign in, or sign out. The source's entry names the
/// service and says what to tell the viewer; its script gives the code to scan and reads the answers
/// (`SourceSignIn`). An iPhone can save the code to Photos for the service's own app.
struct SourceAccountView: View {
    let signIn: SourceSignIn
    @State private var account: SourceAccount
    @State private var attempt = 0

    init(signIn: SourceSignIn) { self.signIn = signIn; _account = State(initialValue: SourceAccount.load(signIn.id)) }

    var body: some View {
        SettingsPage(title: signIn.name, symbol: "person.crop.circle") {
            if account.signedIn {
                SettingsGroup(footer: signIn.signedInNote ?? L10n.text("Sign-in details stay on this device.")) {
                    SettingsRow(symbol: "person.crop.circle.fill", tint: .red, title: account.name.isEmpty ? L10n.text("Signed In") : account.name,
                                subtitle: L10n.text("Signed In")) {
                        Button(L10n.text("Sign Out")) { SourceAccount.signOut(signIn.id); account = SourceAccount(); attempt += 1 }.settingsButton()
                            .accessibilityIdentifier("sourceAccount.signOut")
                    }
                }
            } else {
                SourceCodeSignIn(signIn: signIn) { account = $0 }
            }
        }
        .task(id: attempt) { await refresh() }
    }

    /// Shows the current name, and notices a sign-in the service no longer accepts.
    private func refresh() async {
        guard account.signedIn else { return }
        if let current = await signIn.refreshed(account) { if current != account { try? current.save(signIn.id); account = current } }
        else { SourceAccount.signOut(signIn.id); account = SourceAccount(); attempt += 1 }
    }
}

/// Signing in by scanning a code with the service's phone app.
struct SourceCodeSignIn: View {
    let signIn: SourceSignIn
    let signedIn: (SourceAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var login: SourceSignIn.Code?
    @State private var scanned = false
    @State private var expired = false
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: spacing) { code; details }
            VStack(alignment: .leading, spacing: spacing) { code; details }
        }
        #if os(tvOS)
        .frame(maxWidth: .infinity)
        #else
        .padding(.vertical, 10)
        #endif
        .task(id: attempt) { await run() }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("Sign In to %@", signIn.name)).font(.title2.weight(.bold))
                Text(signIn.note ?? L10n.text("Open the %@ app on your phone, scan this code, and confirm the sign-in.", signIn.name))
                    .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            status
            if expired || error != nil {
                Button(L10n.text("Get New Code")) { attempt += 1 }.settingsButton(prominent: true)
                    .accessibilityIdentifier("sourceAccount.newCode")
            }
            #if os(iOS)
            if let login, !expired { SaveCodeButton(text: login.code, app: signIn.name).id(login.code) }
            #endif
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private var code: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white)
            if let login, let image = QRCode.image(login.code) {
                Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                    .padding(codeSize / 12).opacity(expired ? 0.15 : 1)
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
        } else if expired {
            Label(L10n.text("This code has expired."), systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary)
        } else if login != nil {
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text(scanned ? "Scanned. Confirm the sign-in on your phone…" : "Waiting for you to scan…")).foregroundStyle(.secondary)
            }
        }
    }

    private func run() async {
        login = nil; scanned = false; expired = false; error = nil
        do {
            let login = try await signIn.start()
            self.login = login
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(2))
                switch try await signIn.poll(login) {
                case .waiting: continue
                case .scanned: scanned = true
                case .expired: expired = true; return
                case .signedIn(let account): signedIn(account); return
                }
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
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

extension SourceAccount {
    /// The Settings row's subtitle.
    var summary: String { signedIn ? (name.isEmpty ? L10n.text("Signed In") : name) : L10n.text("Not Signed In") }
}
