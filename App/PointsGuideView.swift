import SwiftUI
import TVCore

/// How points work, for everyone, signed in or not: the ways to earn and what each is worth, what gets feedback
/// adopted, the line that makes a pull request count, and fair play. The numbers are the server's when it has sent
/// them, the standard ones otherwise. Opened from Settings › Account and from Send Feedback.
struct PointsGuideView: View {
    /// Offer Send Feedback (not when opened from it) and, signed out, Sign In (not when opened from the Account page).
    var offersFeedback = true
    var offersSignIn = true
    @State private var accounts = AccountStore.shared
    @State private var copied = false

    private var rules: Account.Points.Rules { accounts.account?.points?.rules ?? .standard }
    private var claim: String { "Yingxia account: \(accounts.account?.id ?? "u_…")" }

    private struct Rule: Identifiable {
        enum Kind { case daily, feedback, fixed, adopted, pullRequest }
        let kind: Kind
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let points: Int
        var id: Kind { kind }
    }

    private var items: [Rule] {
        [
            Rule(kind: .daily, symbol: "calendar", tint: .orange, title: L10n.text("Daily Use"),
                 detail: L10n.text("Open Yingxia while signed in, once a day. Each device counts for one account a day."), points: rules.daily),
            Rule(kind: .feedback, symbol: "paperplane.fill", tint: Color(red: 0.45, green: 0.55, blue: 1), title: L10n.text("Feedback Sent"),
                 detail: L10n.text("Each message sent from Settings › Send Feedback, or with /feedback in the Telegram group (sign in with that Telegram account). Up to %lld a day; duplicates and invalid ones don't count.", rules.sentPerDay),
                 points: rules.sent),
            Rule(kind: .fixed, symbol: "ladybug.fill", tint: .green, title: L10n.text("Bug Fixed"),
                 detail: L10n.text("When the developer fixes a problem you reported. The clearer the report, the likelier: your device, the build, the source, the steps, and a screenshot or video."),
                 points: rules.fixed),
            Rule(kind: .adopted, symbol: "checkmark.seal.fill", tint: .teal, title: L10n.text("Idea Adopted"),
                 detail: L10n.text("When the developer builds a feature you suggested."),
                 points: rules.adopted),
            Rule(kind: .pullRequest, symbol: "arrow.triangle.merge", tint: Color(red: 0.75, green: 0.5, blue: 1), title: L10n.text("Merged Pull Requests"),
                 detail: L10n.text("Yingxia's code is on GitHub. Put this line in your pull request's description; each merged pull request counts once."),
                 points: rules.pullRequest),
        ]
    }

    var body: some View {
        #if os(tvOS)
        // Every rule is a focusable row (TVReadingRowStyle): the remote can move through them, the scroll view
        // follows focus, and Back stays with the NavigationStack.
        SettingsPage(title: L10n.text("How Points Work"), symbol: "star.circle", subtitle: L10n.text("Points reward feedback and code that really help Yingxia.")) {
            SettingsGroup {
                ForEach(items) { item in
                    Button {} label: {
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.system(size: 29, weight: .medium)).lineLimit(2)
                                Text(item.kind == .pullRequest ? "\(item.detail)\n\(claim)" : item.detail)
                                    .font(.system(size: 23)).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer(minLength: 32)
                            Text(verbatim: "+\(item.points.formatted())")
                                .font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(item.tint)
                        }
                        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                    }
                    .buttonStyle(TVReadingRowStyle())
                }
                Button {} label: {
                    Text(L10n.text("Points are counted again from the records every time. Duplicates, spam or several accounts on one device earn nothing more, and points gained unfairly are taken away."))
                        .font(.system(size: 22)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(TVReadingRowStyle())
            }
        }
        #else
        ScrollView {
            VStack(spacing: 16) {
                header.padding(.bottom, 8)
                ForEach(items) { item in card(item) }
                fairPlay
            }
            .padding(.horizontal, Layout.gutter).padding(.top, 20).padding(.bottom, 40)
            .frame(maxWidth: Layout.settingsWidth)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .background { Backdrop() }
        #endif
        .screenTitle(L10n.text("How Points Work"), width: Layout.settingsWidth)
        #endif
    }

    #if !os(tvOS)
    private static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
    private static var fill: Color {
        #if os(iOS)
        SettingsStyle.rowFill
        #else
        Color.primary.opacity(0.05)
        #endif
    }

    private var header: some View {
        let tile = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(MemberCard.ink)
                .frame(width: 64, height: 64)
                .background(MemberCard.gold, in: tile)
                .overlay { tile.strokeBorder(.white.opacity(0.35), lineWidth: 0.5) }
                .padding(.bottom, 8)
            Text(L10n.text("How Points Work")).font(.title2.weight(.bold))
            Text(L10n.text("Points reward feedback and code that really help Yingxia.")).foregroundStyle(.secondary)
            if let account = accounts.account {
                Text(L10n.text("%lld points", account.points?.total ?? account.feedback.points))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(MemberCard.gold)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Self.fill, in: Capsule())
                    .padding(.top, 6)
            } else if offersSignIn {
                RouteLink { AccountView() } label: {
                    Text(L10n.text("Sign in to count your feedback")).padding(.horizontal, 4)
                }
                .buttonStyle(GoldButtonStyle())
                .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private func card(_ item: Rule) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(item.tint)
                .frame(width: 40, height: 40)
                .background(item.tint.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.headline)
                    Spacer(minLength: 8)
                    Text(verbatim: "+\(item.points.formatted())")
                        .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(item.tint)
                }
                Text(item.detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch item.kind {
                case .feedback where offersFeedback:
                    RouteLink { FeedbackView() } label: { linkLabel(L10n.text("Send Feedback"), tint: item.tint) }
                        .buttonStyle(.plain).padding(.top, 2)
                case .pullRequest:
                    claimBox(tint: item.tint)
                default:
                    EmptyView()
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.fill, in: Self.shape)
    }

    private func linkLabel(_ title: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.right").font(.caption.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(tint)
        .contentShape(Rectangle())
    }

    /// The line to put in a pull request, with the person's account ID, to copy; signed out, where to get the ID.
    @ViewBuilder private func claimBox(tint: Color) -> some View {
        if let id = accounts.account?.id {
            HStack(spacing: 10) {
                Text(verbatim: claim).font(.footnote.monospaced()).textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Button { copy("Yingxia account: \(id)") } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Copy Account ID"))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 2)
            if copied { Text(L10n.text("Account ID copied.")).font(.caption).foregroundStyle(.secondary) }
        } else {
            Text(L10n.text("Sign in to get the account ID for your pull requests.")).font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        withAnimation { copied = true }
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { copied = false } }
    }

    private var fairPlay: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(Color.primary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Fair Play")).font(.headline)
                Text(L10n.text("Points are counted again from the records every time. Duplicates, spam or several accounts on one device earn nothing more, and points gained unfairly are taken away."))
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { Self.shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1) }
    }
    #endif
}

/// "Daily +1 · feedback +1 · fixed +50 · adopted +100 · PR +500", for rows that open the guide.
@MainActor func pointsSummary() -> String {
    let rules = AccountStore.shared.account?.points?.rules ?? .standard
    return L10n.text("Daily +%lld · feedback +%lld · fixed +%lld · adopted +%lld · PR +%lld", rules.daily, rules.sent, rules.fixed, rules.adopted, rules.pullRequest)
}
