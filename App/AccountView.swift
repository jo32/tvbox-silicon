import AuthenticationServices
import SwiftUI
import TVCore

/// Settings › Account: sign in with Apple or Telegram. Signed in, a member card leads (black and gold for Pro), then the
/// redeem code field in supported builds, how points are earned as tiles, the person's feedback and merged pull
/// requests, their account ID for pull requests, the ways they sign in, Sign Out and Delete Account. On Apple TV the
/// card takes the left column.
struct AccountView: View {
    @State private var accounts = AccountStore.shared
    @State private var error: String?
    @State private var notice: String?
    @State private var code = ""
    @State private var confirmsDeletion = false
    @State private var appleRequest = AppleSignInRequest()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        page {
            if let account = accounts.account {
                cardSection(account)
                messages
                if accounts.proAvailable, !accounts.isLifetime { redeemSection(account) }
                earnSection(account)
                // Without the tiles (a server from before points; Apple TV lists rules as rows), a row of its own.
                #if os(tvOS)
                guideSection
                #else
                if account.points == nil { guideSection }
                #endif
                feedbackSection(account)
                contributeSection(account)
                if accounts.telegramLogin != nil { telegramSection } else { methodsSection(account) }
                endSection
            } else {
                if accounts.telegramLogin != nil { telegramSection } else { signedOutSection }
                guideSection
                messages
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await accounts.refresh(force: true)
            await accounts.markActiveDay()
        }
        .task { await accounts.checkAppTransaction() }
        .task {
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

    /// Settings' page; on Apple TV, once signed in, with the member card on the left.
    @ViewBuilder private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if os(tvOS)
        if let account = accounts.account {
            TVSettingsSubpage(title: L10n.text("Account"), hero: { memberCard(account) }, content: content)
        } else {
            SettingsPage(title: L10n.text("Account"), symbol: "person.crop.circle", subtitle: L10n.text("Sign in to count your feedback"), content: content)
        }
        #else
        SettingsPage(title: L10n.text("Account"), symbol: "person.crop.circle",
                     subtitle: accounts.account?.displayName ?? L10n.text("Sign in to count your feedback"), content: content)
        #endif
    }

    private func show(_ failure: Error) {
        notice = nil
        error = failure.localizedDescription
    }

    // MARK: Signed out

    @ViewBuilder private var signedOutSection: some View {
        SettingsGroup(footer: accounts.proAvailable
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

    private func memberCard(_ account: Account) -> MemberCard {
        let tier: MemberCard.Tier = accounts.isPro ? .pro(until: accounts.isLifetime ? nil : accounts.proUntil) : .member
        return MemberCard(name: account.displayName, providers: account.identities.map(\.provider),
                          points: account.points?.total ?? account.feedback.points, tier: tier,
                          memberSince: account.identities.map(\.created).min().map { Date(timeIntervalSince1970: $0) })
    }

    @ViewBuilder private func cardSection(_ account: Account) -> some View {
        #if !os(tvOS)
        Section {
            memberCard(account)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
        }
        #endif
    }

    private func identityText(_ identity: Account.Identity) -> String {
        identity.provider == "apple" ? L10n.text("Apple") : L10n.text("Telegram")
    }

    private func identityDetail(_ identity: Account.Identity) -> String? {
        identity.label.isEmpty || identity.label == "Apple" ? nil : identity.label
    }

    /// A code adds Pro time; in gold, the page's one way to Pro.
    @ViewBuilder private func redeemSection(_ account: Account) -> some View {
        SettingsGroup(title: L10n.text("Redeem Code"),
                      footer: account.feedback.rewardDays > 0
                        ? L10n.text("Each message the developer adopts also gives %lld days of Pro.", account.feedback.rewardDays) : nil) {
            #if os(tvOS)
            TVSettingsField(title: L10n.text("Redeem Code"), text: $code, emptyValue: L10n.text("Enter a code"))
            if !code.isEmpty {
                TVSettingsAction(title: L10n.text("Redeem"), busy: accounts.busy) { redeem() }
            }
            #else
            HStack(spacing: 12) {
                Image(systemName: "ticket.fill").foregroundStyle(MemberCard.gold).font(.system(size: 17))
                TextField(L10n.text("Redeem Code"), text: $code, prompt: Text(verbatim: "XXXX-XXXX-XXXX-XXXX"))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .font(.body.monospaced())
                    .onSubmit(redeem)
                Button(L10n.text("Redeem"), action: redeem)
                    .buttonStyle(GoldButtonStyle())
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || accounts.busy)
            }
            .padding(.vertical, 2)
            #endif
        }
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

    // MARK: Points

    /// The way to the whole explanation, signed in or not, and whatever the server sent.
    private var guideSection: some View {
        SettingsGroup {
            #if os(tvOS)
            SettingsLinkRow(symbol: "star.circle.fill", tint: Brand.amber, title: L10n.text("How Points Work")) { PointsGuideView(offersSignIn: false) }
            #else
            SettingsLinkRow(symbol: "star.circle.fill", tint: Brand.amber, title: L10n.text("How Points Work"),
                            subtitle: pointsSummary()) { PointsGuideView(offersSignIn: false) }
            #endif
        }
    }

    /// The total, then each way to earn with its rule and what it brought, so people see what's worth doing: adopted
    /// feedback and merged code count far more than volume.
    @ViewBuilder private func earnSection(_ account: Account) -> some View {
        #if os(tvOS)
        pointsSection(account)
        #else
        if let points = account.points {
            let rules = points.rules
            let tiles = [
                EarnTile(symbol: "calendar", tint: .orange, title: L10n.text("Daily Use"),
                         detail: L10n.text("+%lld a day you open Yingxia · %lld days", rules.daily, points.days), earned: points.days * rules.daily),
                EarnTile(symbol: "paperplane.fill", tint: Color(red: 0.45, green: 0.55, blue: 1), title: L10n.text("Feedback Sent"),
                         detail: L10n.text("+%lld each, up to %lld a day · %lld counted", rules.sent, rules.sentPerDay, points.sent),
                         earned: points.sent * rules.sent),
                EarnTile(symbol: "checkmark.seal.fill", tint: .green, title: L10n.text("Feedback Adopted"),
                         detail: L10n.text("Bug fixed +%lld · idea +%lld · %lld counted", rules.fixed, rules.adopted, points.fixed + points.adopted),
                         earned: points.feedbackEarned),
                EarnTile(symbol: "arrow.triangle.merge", tint: Color(red: 0.75, green: 0.5, blue: 1), title: L10n.text("Merged Pull Requests"),
                         detail: L10n.text("+%lld each · %lld merged", rules.pullRequest, points.pullRequests),
                         earned: points.pullRequests * rules.pullRequest),
            ]
            Section {
                // Four across where they fit (iPad, Mac), otherwise two by two.
                ViewThatFits(in: .horizontal) {
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow { ForEach(0..<4, id: \.self) { tiles[$0] } }
                    }
                    .frame(minWidth: 620)
                    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow { tiles[0]; tiles[1] }
                        GridRow { tiles[2]; tiles[3] }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                // The whole explanation, one tap from the tiles.
                HStack {
                    Text(L10n.text("How You Earn Points"))
                    Spacer()
                    RouteLink { PointsGuideView(offersSignIn: false) } label: {
                        HStack(spacing: 3) {
                            Text(L10n.text("How Points Work"))
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(MemberCard.goldGlow)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if points.adjusted != 0 {
                SettingsGroup {
                    pointsRow(symbol: "slider.horizontal.3", tint: .gray, title: L10n.text("Set by the Developer"), rule: nil, earned: points.adjusted)
                }
            }
        }
        #endif
    }

    #if os(tvOS)
    @ViewBuilder private func pointsSection(_ account: Account) -> some View {
        if let points = account.points {
            let rules = points.rules
            SettingsGroup(title: L10n.text("Points"),
                          footer: L10n.text("Duplicate or invalid feedback earns nothing. Feedback with your device, build, the source and clear steps is the most likely to be adopted. Feedback sent with /feedback in the Telegram group counts too, for the Telegram account you sign in with.")) {
                pointsRow(symbol: "calendar.circle.fill", tint: .orange, title: L10n.text("Daily Use"),
                          rule: L10n.text("+%lld a day you open Yingxia · %lld days", rules.daily, points.days), earned: points.days * rules.daily)
                pointsRow(symbol: "paperplane.circle.fill", tint: Brand.indigo, title: L10n.text("Feedback Sent"),
                          rule: L10n.text("+%lld each, up to %lld a day · %lld counted", rules.sent, rules.sentPerDay, points.sent),
                          earned: points.sent * rules.sent)
                pointsRow(symbol: "checkmark.seal.fill", tint: .green, title: L10n.text("Feedback Adopted"),
                          rule: L10n.text("Bug fixed +%lld · idea +%lld · %lld counted", rules.fixed, rules.adopted, points.fixed + points.adopted),
                          earned: points.feedbackEarned)
                pointsRow(symbol: "arrow.triangle.merge", tint: .purple, title: L10n.text("Merged Pull Requests"),
                          rule: L10n.text("+%lld each · %lld merged", rules.pullRequest, points.pullRequests),
                          earned: points.pullRequests * rules.pullRequest)
                if points.adjusted != 0 {
                    pointsRow(symbol: "slider.horizontal.3", tint: .gray, title: L10n.text("Set by the Developer"), rule: nil, earned: points.adjusted)
                }
            }
        }
    }
    #endif

    private func pointsRow(symbol: String, tint: Color, title: String, rule: String?, earned: Int) -> some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: rule) {
            Text(verbatim: earned > 0 ? "+\(earned.formatted())" : earned.formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func feedbackSection(_ account: Account) -> some View {
        if !account.feedback.issues.isEmpty {
            SettingsGroup(title: L10n.text("Your Feedback")) {
                ForEach(account.feedback.issues) { issue in
                    issueRow(issue)
                }
            }
        }
    }

    /// Merged pull requests that count, and the account ID to put in a pull request's description.
    @ViewBuilder private func contributeSection(_ account: Account) -> some View {
        SettingsGroup(title: L10n.text("Contribute Code"),
                      footer: L10n.text("Put “Yingxia account: %@” in the description of your pull request on GitHub, or your Telegram @username. Each one merged earns %lld points.",
                                        account.id, account.points?.rules.pullRequest ?? 500)) {
            ForEach(account.pullRequests ?? []) { pull in
                pullRequestRow(pull, points: account.points?.rules.pullRequest ?? 500)
            }
            SettingsRow(symbol: "number.circle.fill", tint: .gray, title: L10n.text("Account ID")) {
                HStack(spacing: 10) {
                    Text(verbatim: account.id).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    #if !os(tvOS)
                    Button { copyAccountID(account.id) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.text("Copy Account ID"))
                    #endif
                }
            }
        }
    }

    #if !os(tvOS)
    private func copyAccountID(_ id: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        #else
        UIPasteboard.general.string = id
        #endif
        error = nil
        notice = L10n.text("Account ID copied.")
    }
    #endif

    @ViewBuilder private func pullRequestRow(_ pull: Account.PullRequest, points: Int) -> some View {
        let label = SettingsRow(symbol: "arrow.triangle.merge", tint: .purple, title: pull.title.isEmpty ? "#\(pull.number)" : pull.title,
                                subtitle: "#\(pull.number) · \(L10n.text("Pull request: merged"))") {
            StatusPill(text: "+\(points.formatted())", tint: Color(red: 0.75, green: 0.5, blue: 1))
        }
        #if os(tvOS)
        label
        #else
        if let url = URL(string: "https://github.com/jo32/tvbox-silicon/pull/\(pull.number)") {
            Link(destination: url) { label.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            label
        }
        #endif
    }

    @ViewBuilder private func issueRow(_ issue: Account.Feedback.Issue) -> some View {
        let day = Date(timeIntervalSince1970: issue.sent).formatted(date: .abbreviated, time: .omitted)
        // No title yet (GitHub not asked): the number leads, so it isn't said twice.
        let label = SettingsRow(symbol: statusSymbol(issue.status), tint: statusTint(issue.status),
                                title: issue.title.isEmpty ? L10n.text("Feedback #%lld", issue.number) : issue.title,
                                subtitle: issue.title.isEmpty ? day : "#\(issue.number) · \(day)") {
            StatusPill(text: statusText(issue.status), tint: statusTint(issue.status))
        }
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
        case "fixed": L10n.text("Fixed")
        case "adopted": L10n.text("Adopted")
        case "declined": L10n.text("Not planned")
        case "duplicate": L10n.text("Duplicate")
        case "closed": L10n.text("Feedback status: closed")
        default: L10n.text("Feedback status: open")
        }
    }
    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "fixed", "adopted": "checkmark.circle.fill"
        case "declined", "duplicate": "minus.circle.fill"
        case "closed": "checkmark.circle"
        default: "circle.dotted"
        }
    }
    private func statusTint(_ status: String) -> Color {
        switch status {
        case "fixed", "adopted": .green
        case "declined", "duplicate", "closed": .gray
        default: .blue
        }
    }

    @ViewBuilder private func methodsSection(_ account: Account) -> some View {
        let addsApple = !account.has("apple") && AppleSignInSupport.available
        let addsTelegram = !account.has("telegram")
        SettingsGroup(title: L10n.text("Sign-in Methods"),
                      footer: addsApple || addsTelegram ? L10n.text("Add another way to sign in, so the same account works on every device.") : nil) {
            ForEach(account.identities) { identity in
                SettingsRow(symbol: identity.provider == "apple" ? "apple.logo" : "paperplane.fill",
                            tint: identity.provider == "apple" ? .gray : AccountColors.telegram,
                            title: identityText(identity), subtitle: identityDetail(identity)) {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if addsApple || addsTelegram {
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
        case .telegram: AccountColors.telegram
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
        .task { await accounts.checkAppTransaction() }
    }

    private var subtitle: String {
        guard let account = accounts.account else {
            return accounts.proAvailable ? L10n.text("Feedback points and Pro codes") : L10n.text("Feedback points")
        }
        let points = L10n.text("%lld points", account.feedback.points)
        return accounts.isPro ? "\(L10n.text("Pro")) · \(points)" : points
    }
}
