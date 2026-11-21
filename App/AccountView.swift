import AuthenticationServices
import SwiftUI
import TVCore

/// Settings › Account: sign in with Apple or Telegram; then the feedback that counts for the person (sent, adopted,
/// points), Pro and its redeem code field (not in App Store builds), other ways to sign in, Sign Out and Delete Account.
struct AccountView: View {
    @State private var accounts = AccountStore.shared
    @State private var error: String?
    @State private var notice: String?
    @State private var code = ""
    @State private var confirmsDeletion = false
    @State private var appleRequest = AppleSignInRequest()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsPage(title: L10n.text("Account"), symbol: "person.crop.circle",
                     subtitle: accounts.account?.displayName ?? L10n.text("Sign in to count your feedback")) {
            if let account = accounts.account {
                profile(account)
                if AccountStore.proAvailable { proSection(account) }
                feedbackSection(account)
                if accounts.telegramLogin != nil { telegramSection } else { methodsSection(account) }
                messages
                endSection
            } else {
                if accounts.telegramLogin != nil { telegramSection } else { signedOutSection }
                messages
            }
        }
        .task {
            await accounts.refresh()
            #if DEBUG
            // `-qaAccountTelegram 1`: starts a Telegram sign-in without a tap (and without leaving for Telegram).
            if UserDefaults.standard.bool(forKey: "qaAccountTelegram"), !accounts.signedIn, accounts.telegramLogin == nil {
                do { try await accounts.startTelegram() } catch { show(error) }
            }
            #endif
        }
        // Again when the app comes back (from Telegram, after tapping Start): check at once.
        .task(id: "\(accounts.telegramLogin?.code ?? "")|\(scenePhase == .active)") {
            guard accounts.telegramLogin != nil else { return }
            do { try await accounts.waitForTelegram() } catch is CancellationError {} catch { show(error) }
        }
        #if !os(tvOS)
        .confirmationDialog(L10n.text("Delete your Yingxia account?"), isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button(L10n.text("Delete Account"), role: .destructive) { deleteAccount() }
        } message: {
            Text(L10n.text("Your feedback points and Pro time are deleted with it, and can't be brought back."))
        }
        #endif
    }

    private func show(_ failure: Error) {
        notice = nil
        error = failure.localizedDescription
    }

    // MARK: Signed out

    @ViewBuilder private var signedOutSection: some View {
        SettingsGroup(footer: AccountStore.proAvailable
                      ? L10n.text("Feedback you send counts toward points, more for each message the developer adopts, and you can redeem Pro codes. Feedback this device sent in the last 30 days counts too.")
                      : L10n.text("Feedback you send counts toward points, more for each message the developer adopts. Feedback this device sent in the last 30 days counts too.")) {
            #if os(tvOS)
            if AppleSignInSupport.available {
                TVSettingsAction(title: L10n.text("Sign in with Apple"), busy: accounts.busy) { signInWithApple() }
            }
            TVSettingsAction(title: L10n.text("Sign in with Telegram"), busy: accounts.busy) { startTelegram() }
            #else
            signInButtons(apple: AppleSignInSupport.available, telegram: true)
            #endif
        }
    }

    #if !os(tvOS)
    /// Apple and Telegram in one look, in one row (no line between them).
    private func signInButtons(apple: Bool, telegram: Bool) -> some View {
        VStack(spacing: 12) {
            if apple { SignInButton(kind: .apple, title: L10n.text("Sign in with Apple")) { signInWithApple() } }
            if telegram { SignInButton(kind: .telegram, title: L10n.text("Sign in with Telegram")) { startTelegram() } }
        }
        .padding(.vertical, 4)
        .disabled(accounts.busy)
    }
    #endif

    private func signInWithApple() {
        Task {
            do { await signIn(try await appleRequest.run()) } catch { if !AppleCredential.cancelled(error) { show(error) } }
        }
    }

    private func signIn(_ credential: AppleCredential) async {
        error = nil
        do {
            try await accounts.signInWithApple(credential)
        } catch {
            show(error)
        }
    }

    private func startTelegram() {
        error = nil
        Task {
            do {
                try await accounts.startTelegram()
                #if !os(tvOS)
                if let url = accounts.telegramLogin?.url { openURL(url) }
                #endif
            } catch {
                show(error)
            }
        }
    }

    #if !os(tvOS)
    @Environment(\.openURL) private var openURL
    #endif

    // MARK: Telegram, waiting

    @ViewBuilder private var telegramSection: some View {
        if let login = accounts.telegramLogin {
            SettingsGroup(title: L10n.text("Sign in with Telegram")) {
                HStack(alignment: .center, spacing: 24) {
                    if let image = QRCode.image(login.url.absoluteString) {
                        Image(image, scale: 1, label: Text(L10n.text("Sign-in code"))).interpolation(.none).resizable().scaledToFit()
                            .padding(codeSize / 12)
                            .frame(width: codeSize, height: codeSize)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        #if os(tvOS)
                        Text(L10n.text("Scan with your iPhone, then tap Start in Telegram.")).font(.system(size: 26))
                        #else
                        Text(L10n.text("Tap Start in Telegram to finish. On another device, scan the code instead.")).font(.callout)
                        #endif
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(L10n.text("Waiting for Telegram…")).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                #if os(tvOS)
                .padding(.horizontal, 28).padding(.vertical, 12)
                #else
                .padding(.vertical, 8)
                #endif
                #if !os(tvOS)
                Button(L10n.text("Open Telegram")) { openURL(login.url) }.formRowButton()
                #endif
                SettingsActionRow(title: L10n.text("Cancel")) { accounts.cancelTelegram() }
            }
        }
    }

    private var codeSize: CGFloat {
        #if os(tvOS)
        260
        #else
        132
        #endif
    }

    // MARK: Signed in

    private func profile(_ account: Account) -> some View {
        SettingsGroup {
            SettingsRow(symbol: "person.crop.circle.fill", tint: Brand.indigo, title: account.displayName,
                        subtitle: account.identities.map(identityText).joined(separator: "\n"))
        }
    }

    private func identityText(_ identity: Account.Identity) -> String {
        let method = identity.provider == "apple" ? L10n.text("Apple") : L10n.text("Telegram")
        return identity.label.isEmpty || identity.label == "Apple" ? method : "\(method) · \(identity.label)"
    }

    @ViewBuilder private func proSection(_ account: Account) -> some View {
        SettingsGroup(title: L10n.text("Yingxia Pro"),
                      footer: account.feedback.rewardDays > 0
                        ? L10n.text("Each message the developer adopts also gives %lld days of Pro.", account.feedback.rewardDays) : nil) {
            SettingsRow(symbol: "crown.fill", tint: Brand.amber, title: L10n.text("Pro")) {
                Text(proValue).foregroundStyle(accounts.isPro ? .primary : .secondary)
            }
            #if os(tvOS)
            TVSettingsField(title: L10n.text("Redeem Code"), text: $code, emptyValue: L10n.text("Enter a code"))
            if !code.isEmpty {
                TVSettingsAction(title: L10n.text("Redeem"), busy: accounts.busy) { redeem() }
            }
            #else
            HStack(spacing: 12) {
                TextField(L10n.text("Redeem Code"), text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX-XXXX"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .font(.body.monospaced())
                    .onSubmit(redeem)
                Button(L10n.text("Redeem"), action: redeem)
                    .settingsButton(prominent: true)
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || accounts.busy)
            }
            #endif
        }
    }

    private var proValue: String {
        guard let until = accounts.proUntil else { return L10n.text("Not active") }
        return accounts.isLifetime ? L10n.text("Lifetime") : L10n.text("Until %@", until.formatted(date: .abbreviated, time: .omitted))
    }

    private func redeem() {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        error = nil
        notice = nil
        Task {
            do {
                let days = try await accounts.redeem(entered)
                code = ""
                notice = days.map { L10n.text("Code redeemed: %lld days of Pro added.", $0) } ?? L10n.text("Code redeemed: Pro for life.")
            } catch {
                show(error)
            }
        }
    }

    @ViewBuilder private func feedbackSection(_ account: Account) -> some View {
        let feedback = account.feedback
        SettingsGroup(title: L10n.text("Your Feedback"),
                      footer: L10n.text("Messages sent from Settings › Send Feedback while signed in count here. Each one earns points, and many more when the developer adopts it.")) {
            SettingsRow(symbol: "star.circle.fill", tint: Brand.amber, title: L10n.text("Points")) {
                Text(feedback.points.formatted()).font(.body.weight(.semibold)).monospacedDigit()
            }
            SettingsRow(symbol: "paperplane.circle.fill", tint: Brand.indigo, title: L10n.text("Sent")) {
                Text(feedback.sent.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            SettingsRow(symbol: "checkmark.seal.fill", tint: .green, title: L10n.text("Adopted")) {
                Text(feedback.adopted.formatted()).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(feedback.issues) { issue in
                issueRow(issue)
            }
        }
    }

    @ViewBuilder private func issueRow(_ issue: Account.Feedback.Issue) -> some View {
        let label = SettingsRow(symbol: statusSymbol(issue.status), tint: statusTint(issue.status),
                                title: issue.title.isEmpty ? "#\(issue.number)" : issue.title,
                                subtitle: "#\(issue.number) · \(statusText(issue.status))")
        #if os(tvOS)
        label
        #else
        if let url = URL(string: "https://github.com/jo32/tvbox-silicon/issues/\(issue.number)") {
            Link(destination: url) { label.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            label
        }
        #endif
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "adopted": L10n.text("Adopted")
        case "declined": L10n.text("Not planned")
        case "duplicate": L10n.text("Duplicate")
        default: L10n.text("Open")
        }
    }
    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "adopted": "checkmark.circle.fill"
        case "declined", "duplicate": "minus.circle.fill"
        default: "circle.dotted"
        }
    }
    private func statusTint(_ status: String) -> Color {
        switch status {
        case "adopted": .green
        case "declined", "duplicate": .gray
        default: .blue
        }
    }

    @ViewBuilder private func methodsSection(_ account: Account) -> some View {
        let addsApple = !account.has("apple") && AppleSignInSupport.available
        let addsTelegram = !account.has("telegram")
        if addsApple || addsTelegram {
            SettingsGroup(footer: L10n.text("Add another way to sign in, so the same account works on every device.")) {
                #if os(tvOS)
                if addsApple { TVSettingsAction(title: L10n.text("Add Sign in with Apple"), busy: accounts.busy) { signInWithApple() } }
                if addsTelegram { TVSettingsAction(title: L10n.text("Add Telegram"), busy: accounts.busy) { startTelegram() } }
                #else
                signInButtons(apple: addsApple, telegram: addsTelegram)
                #endif
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if error != nil || notice != nil {
            SettingsGroup {
                if let error {
                    SettingsRow(symbol: "exclamationmark.triangle.fill", tint: .orange, title: error)
                }
                if let notice {
                    SettingsRow(symbol: "checkmark.circle.fill", tint: .green, title: notice)
                }
            }
        }
    }

    @ViewBuilder private var endSection: some View {
        SettingsGroup {
            SettingsActionRow(title: L10n.text("Sign Out")) {
                Task { await accounts.signOut() }
            }
            #if os(tvOS)
            // A second press confirms: dialogs on pushed tvOS pages can hang (#272).
            TVSettingsAction(title: L10n.text(confirmsDeletion ? "Press Again to Delete Account" : "Delete Account"),
                             busy: accounts.busy, destructive: true) {
                if confirmsDeletion { deleteAccount() } else { confirmsDeletion = true }
            }
            #else
            SettingsActionRow(title: L10n.text("Delete Account"), destructive: true) { confirmsDeletion = true }
            #endif
        }
    }

    private func deleteAccount() {
        confirmsDeletion = false
        Task {
            do { try await accounts.delete() } catch { show(error) }
        }
    }
}

#if !os(tvOS)
/// A sign-in button: Apple and Telegram share the shape, height, type and icon layout. Apple's keeps what its
/// guidelines ask of a custom button (the Apple logo, "Sign in with Apple", black on a light page and white on a dark
/// one); Telegram's is Telegram blue.
private struct SignInButton: View {
    enum Kind { case apple, telegram }
    let kind: Kind
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: kind == .apple ? "apple.logo" : "paperplane.fill")
                    .font(.system(size: kind == .apple ? 19 : 16, weight: .semibold))
                    .frame(width: 22)
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: Self.fontSize, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: Self.height)
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(Pressed())
        .opacity(isEnabled ? 1 : 0.5)
    }

    #if os(macOS)
    private static let height: CGFloat = 40, fontSize: CGFloat = 15
    #else
    private static let height: CGFloat = 50, fontSize: CGFloat = 17
    #endif

    private var background: Color {
        switch kind {
        case .apple: colorScheme == .dark ? .white : .black
        case .telegram: Color(red: 0x22 / 255, green: 0x9E / 255, blue: 0xD9 / 255)
        }
    }

    private var foreground: Color {
        kind == .apple && colorScheme == .dark ? .black : .white
    }

    private struct Pressed: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}
#endif

/// The row on Settings that opens the Account page: the name when signed in, otherwise what signing in is for.
struct AccountSettingsRow: View {
    @State private var accounts = AccountStore.shared
    var body: some View {
        Group {
            #if os(tvOS)
            TVSettingsLink(title: L10n.text("Account"), value: accounts.account?.displayName ?? L10n.text("Not signed in")) { AccountView() }
            #else
            SettingsLinkRow(symbol: "person.crop.circle.fill", tint: Brand.indigo, title: accounts.account?.displayName ?? L10n.text("Sign In"),
                            subtitle: subtitle) { AccountView() }
            #endif
        }
        .task { await accounts.refresh() }
    }

    private var subtitle: String {
        guard let account = accounts.account else {
            return AccountStore.proAvailable ? L10n.text("Feedback points and Pro codes") : L10n.text("Feedback points")
        }
        let points = L10n.text("%lld points", account.feedback.points)
        return accounts.isPro ? "\(L10n.text("Pro")) · \(points)" : points
    }
}
