import SwiftUI
import TVCore

/// Where people talk with the developer and each other, besides Send Feedback's public issues.
enum Support {
    static let telegram = URL(string: "https://t.me/+knKAmySfMycyMzg5")!
}

/// Settings › Send Feedback: a problem or an idea in the user's own words, posted as a public GitHub
/// issue (Feedback). Under the message go the subscriptions and what was played lately
/// (Feedback.context), filled in when the page opens, for the viewer to edit or remove. Once the issue
/// is up, the page shows its number and, off Apple TV, a link to it. Under it, Your Feedback lists what
/// was sent from this device with how each issue is doing and the developer's replies, asked from the
/// server each time the page opens or sends.
struct FeedbackView: View {
    @Environment(Store.self) private var store
    @State private var kind = Feedback.Kind.bug
    @State private var message = ""
    @State private var context = ""
    @State private var contextLoaded = false
    @State private var sending = false
    @State private var sent: Feedback.Issue?
    @State private var error: String?
    @State private var history: [Feedback.Sent] = []
    @State private var statuses: [Int: Feedback.Status] = [:]
    @State private var checking = false
    @State private var checkFailed = false
    #if os(tvOS)
    /// The issue whose latest reply the section's footer shows.
    @State private var reading: Int?
    #endif

    static var note: String {
        L10n.text("Your feedback becomes a public issue on Yingxia's GitHub page, with the app and system versions, the device model, the language and the included details. Please don't include accounts or passwords.")
    }
    static var contextNote: String {
        L10n.text("Your subscriptions and what you played lately help find the problem. Edit or remove anything you'd rather keep private.")
    }
    private var freshContext: String {
        Feedback.context(subscriptions: store.subscriptions, errors: store.subscriptionErrors, history: store.playbackHistory.entries)
    }
    private var empty: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var thanks: String? { sent.map { L10n.text("Thanks! Your feedback is issue #%lld.", $0.number) } }

    #if DEBUG
    private static var qaDrafted = false
    #endif

    var body: some View {
        content
            .onAppear {
                guard !contextLoaded else { return }
                contextLoaded = true
                context = freshContext
            }
            .task(id: sent?.number) { await check() }
            #if DEBUG
            // `-qaFeedbackDraft <text>` fills in the message (typing on the TV's keyboard is slow), and
            // `-qaFeedbackSend 1` sends it, to the server named by `-qaFeedback <url>`. Once per launch: the
            // page can appear more than once.
            .onAppear {
                guard !Self.qaDrafted, let draft = UserDefaults.standard.string(forKey: "qaFeedbackDraft") else { return }
                Self.qaDrafted = true
                message = draft
                if UserDefaults.standard.bool(forKey: "qaFeedbackSend") { send() }
            }
            #endif
    }

    @ViewBuilder private var content: some View {
        #if os(tvOS)
        // The note goes under the rows: the hero's subtitle stops at three lines.
        TVSettingsSubpage(symbol: "bubble.left.and.text.bubble.right", title: L10n.text("Send Feedback")) {
            TVSettingsSection(title: L10n.text("Feedback"), footer: [error ?? thanks, Self.note].compactMap { $0 }.joined(separator: "\n\n")) {
                TVSettingsAction(title: L10n.text("Type"), value: kind.title) {
                    let kinds = Feedback.Kind.allCases
                    kind = kinds[((kinds.firstIndex(of: kind) ?? 0) + 1) % kinds.count]
                }
                TVSettingsField(title: L10n.text("Message"), text: $message, prose: true)
                TVSettingsAction(title: sending ? L10n.text("Sending…") : L10n.text("Send"), busy: sending, action: send)
                    .disabled(sending || empty)
            }
            // Typing a dozen lines with the remote is no way to edit them: the TV shows the details
            // and sends them or not.
            TVSettingsSection(title: L10n.text("Included Details"), footer: context.isEmpty ? Self.contextNote : context + "\n\n" + Self.contextNote) {
                TVSettingsToggle(title: L10n.text("Include Details"), isOn: Binding {
                    !context.isEmpty
                } set: { context = $0 ? freshContext : "" })
            }
            if !history.isEmpty {
                TVSettingsSection(title: L10n.text("Your Feedback"), footer: latestReply) {
                    ForEach(history.prefix(Feedback.checked)) { item in
                        let status = statuses[item.number]
                        let unread = (status?.replies.count ?? 0) > item.seen
                        TVSettingsAction(title: "#\(item.number) \(item.title)", value: unread ? L10n.text("New Reply") : status?.progress.title,
                                         busy: checking && status == nil) {
                            reading = item.number
                            read(item)
                        }
                    }
                }
            }
        }
        #else
        FeedbackPage(kind: $kind, message: $message, context: $context, freshContext: freshContext, sending: sending,
                     sent: $sent, error: error, send: send,
                     history: history, statuses: statuses, checking: checking, checkFailed: checkFailed, read: read)
        #endif
    }

    #if os(tvOS)
    /// The chosen issue's latest reply as plain text, cut short: a footer can't scroll.
    private var latestReply: String? {
        if checkFailed { return L10n.text("Couldn't check for replies. Please try again later.") }
        guard let reading, let status = statuses[reading] else { return nil }
        guard let reply = status.replies.last else { return L10n.text("No replies yet. They'll appear here.") }
        let text = String(Feedback.reply(reply.text).characters)
        return "\(L10n.text("Developer")) · \(reply.date.formatted(date: .abbreviated, time: .shortened))\n"
            + (text.count > 600 ? String(text.prefix(599)) + "…" : text)
    }
    #endif

    /// What was sent from here and how each issue is doing. A failure leaves what was shown before.
    private func check() async {
        history = Feedback.sent()
        guard !history.isEmpty else { return }
        checking = true
        defer { checking = false }
        do {
            statuses = try await Feedback.statuses(of: history.map(\.number))
            checkFailed = false
        } catch {
            if !Task.isCancelled { checkFailed = true }
        }
    }

    /// The viewer opened an issue: its replies so far are read.
    private func read(_ item: Feedback.Sent) {
        guard let count = statuses[item.number]?.replies.count, count != item.seen else { return }
        Feedback.markSeen(item.number, replies: count)
        history = Feedback.sent()
    }

    private func send() {
        guard !sending, !empty else { return }
        sending = true; error = nil; sent = nil
        Task {
            defer { sending = false }
            do {
                sent = try await Feedback.send(Feedback.combined(message, context: context), kind: kind)
                message = ""
                context = freshContext
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private extension Feedback.Status {
    /// How the issue is doing, as a word and its color.
    var progress: (title: String, tint: Color) {
        switch state {
        case .closed: (L10n.text("Resolved"), .green)
        case .declined: (L10n.text("Closed"), .secondary)
        case .open: replies.isEmpty ? (L10n.text("Received"), Brand.indigo) : (L10n.text("Replied"), Brand.cyan)
        }
    }
}

#if !os(tvOS)
// MARK: Send Feedback on the Mac, iPhone and iPad
// A page of its own rather than a form: a short invitation, the three kinds as cards, a roomy editor
// with Send in its bottom bar (⌘↩), the included details in an editor of their own, and what goes
// with the message spelled out. Once the issue is
// up, a thank-you card links to it. iPhone keeps the layout with smaller type and cards without
// their blurbs, on the app's navy canvas.

private struct FeedbackPage: View {
    @Binding var kind: Feedback.Kind
    @Binding var message: String
    @Binding var context: String
    let freshContext: String
    let sending: Bool
    @Binding var sent: Feedback.Issue?
    let error: String?
    let send: () -> Void
    let history: [Feedback.Sent]
    let statuses: [Int: Feedback.Status]
    let checking: Bool
    let checkFailed: Bool
    let read: (Feedback.Sent) -> Void
    @FocusState private var editing: Bool
    @Environment(\.openURL) private var openURL
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var empty: Bool { message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static let card = RoundedRectangle(cornerRadius: 14, style: .continuous)
    /// Cards and chips: a faint grey on the Mac, the settings rows' fill on iPhone and iPad.
    static var fill: Color {
        #if os(iOS)
        SettingsStyle.rowFill
        #else
        Color.primary.opacity(0.05)
        #endif
    }
    /// iPhone, or iPad in a narrow window.
    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(spacing: compact ? 22 : 28) {
                header
                if let sent {
                    thanks(sent).transition(.scale(scale: 0.97).combined(with: .opacity))
                } else {
                    form.transition(.opacity)
                }
                if !history.isEmpty {
                    FeedbackHistory(history: history, statuses: statuses, checking: checking, failed: checkFailed, compact: compact, read: read)
                }
            }
            .padding(.horizontal, compact ? Layout.gutter : 32).padding(.top, compact ? 20 : 32).padding(.bottom, 40)
            .frame(maxWidth: Layout.settingsWidth)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.35), value: sent)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        .background { Backdrop() }
        #endif
        .screenTitle(L10n.text("Send Feedback"), width: Layout.settingsWidth)
    }

    private var header: some View {
        let tile = RoundedRectangle(cornerRadius: compact ? 16 : 18, style: .continuous)
        return VStack(spacing: compact ? 6 : 8) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: compact ? 26 : 30, weight: .semibold)).foregroundStyle(.white)
                .frame(width: compact ? 60 : 68, height: compact ? 60 : 68)
                .background(LinearGradient(colors: [Brand.cyan, Brand.indigo], startPoint: .topLeading, endPoint: .bottomTrailing), in: tile)
                .overlay { tile.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                .shadow(color: Brand.indigo.opacity(0.45), radius: 18, y: 8)
                .padding(.bottom, 8)
            Text(L10n.text("Help Make Yingxia Better")).font(compact ? .title2.weight(.bold) : .title.weight(.bold))
            Text(L10n.text("Report a problem or share an idea. It goes straight to the developer."))
                .font(compact ? .body : .title3).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 20) {
            HStack(spacing: compact ? 10 : 12) {
                ForEach(Feedback.Kind.allCases, id: \.self) { option in
                    FeedbackKindCard(kind: option, selected: option == kind, compact: compact) { kind = option; editing = true }
                }
            }
            composer
            included
            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
                    Text(error)
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            details
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // TextEditor has no prompt: this sits where its first line starts.
                if message.isEmpty {
                    Text(kind.prompt).foregroundStyle(.tertiary).padding(.leading, 5)
                        #if os(iOS)
                        .padding(.top, 8)
                        #endif
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .scrollContentBackground(.hidden)
                    .focused($editing)
            }
            #if os(macOS)
            .font(.system(size: 14))
            #endif
            .frame(minHeight: compact ? 150 : 200)
            .padding(compact ? 10 : 14)
            Divider()
            HStack(spacing: 10) {
                // What is sent: the message and the included details.
                let count = Feedback.combined(message, context: context).count
                Text(verbatim: "\(count.formatted()) / \(Feedback.limit.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(count > Feedback.limit ? AnyShapeStyle(Brand.amber) : AnyShapeStyle(.tertiary))
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                #if os(macOS)
                Text(verbatim: "⌘↩").font(.callout).foregroundStyle(.tertiary)
                #endif
                Button(action: send) {
                    Label(sending ? L10n.text("Sending…") : L10n.text("Send"), systemImage: "paperplane.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(systemAccent).feedbackButton(compact ? .regular : .large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || empty)
            }
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, 10)
        }
        .background { Self.card.fill(Self.fill) }
        .overlay { Self.card.strokeBorder(editing ? systemAccent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: editing ? 1.5 : 1) }
        .animation(.easeOut(duration: 0.15), value: editing)
        #if os(macOS)
        // Not on iPhone: the keyboard would cover the page before it has been read.
        .onAppear { editing = true }
        #endif
    }

    /// The subscriptions and recent plays, sent after the message as they read here.
    private var included: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label(L10n.text("Included Details"), systemImage: "list.bullet.rectangle.portrait")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if context != freshContext { Button(L10n.text("Reset")) { context = freshContext } }
                if !context.isEmpty { Button(L10n.text("Remove"), role: .destructive) { context = "" } }
            }
            .buttonStyle(.borderless).font(.subheadline)
            if !context.isEmpty {
                TextEditor(text: $context)
                    .font(.system(compact ? .footnote : .callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: compact ? 160 : 180)
                    .padding(compact ? 8 : 10)
                    .background { Self.card.fill(Self.fill) }
                    .overlay { Self.card.strokeBorder(Color.primary.opacity(0.08)) }
            }
            Text(FeedbackView.contextNote).font(compact ? .footnote : .callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
        .animation(.easeOut(duration: 0.2), value: context.isEmpty)
    }

    private var details: some View {
        let details = Feedback.details
        let language = Locale(identifier: details.language).localizedString(forIdentifier: details.language) ?? details.language
        let app = chip("app.badge.fill", "\(L10n.text("Yingxia")) \(details.app)"), system = chip(deviceSymbol, details.system)
        let model = chip("cpu", details.model), lang = chip("character.bubble", language)
        return VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("Sent with your message")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { app; system; model; lang }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { app; system }
                    HStack(spacing: 8) { model; lang }
                }
                VStack(alignment: .leading, spacing: 8) { app; system; model; lang }
            }
            Label(FeedbackView.note, systemImage: "globe").font(compact ? .footnote : .callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: Support.telegram) {
                Label(L10n.text("Prefer to chat? Join the Telegram group."), systemImage: "paperplane")
            }
            .font(compact ? .footnote : .callout)
        }
        .padding(.horizontal, 4)
    }

    private var deviceSymbol: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        "desktopcomputer"
        #endif
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(compact ? .footnote : .callout).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Self.fill, in: Capsule())
    }

    private func thanks(_ issue: Feedback.Issue) -> some View {
        let another = Button(L10n.text("Send Another")) { sent = nil; editing = true }
            .buttonStyle(.bordered).feedbackButton(.large)
        let open = Button { openURL(issue.url) } label: { Label(L10n.text("View on GitHub"), systemImage: "arrow.up.right") }
            .buttonStyle(.borderedProminent).tint(systemAccent).feedbackButton(.large)
        return VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: compact ? 48 : 56)).symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                .shadow(color: .green.opacity(0.45), radius: 18, y: 6)
                .padding(.bottom, 4)
            Text(L10n.text("Thank You!")).font(.title2.weight(.bold))
            Text(L10n.text("Your feedback is now issue #%lld on GitHub.", issue.number)).font(compact ? .body : .title3).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { another; open }
                VStack(spacing: 10) { open; another }
            }
            .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, compact ? 32 : 40).padding(.horizontal, compact ? 16 : 24)
        .frame(maxWidth: .infinity)
        .background {
            Self.card.fill(Self.fill)
                .overlay { Self.card.fill(RadialGradient(colors: [Color.green.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 260)) }
        }
        .overlay { Self.card.strokeBorder(Color.primary.opacity(0.08)) }
    }
}

/// Your Feedback: the issues sent from here, newest first, each with how it is doing. Opening one shows
/// the developer's replies and marks them read; a dot marks an issue with replies not read yet.
private struct FeedbackHistory: View {
    let history: [Feedback.Sent]
    let statuses: [Int: Feedback.Status]
    let checking: Bool
    let failed: Bool
    let compact: Bool
    let read: (Feedback.Sent) -> Void
    @State private var open: Int?
    @Environment(\.openURL) private var openURL
    private static let card = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L10n.text("Your Feedback"), systemImage: "tray.full")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if checking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(history.prefix(Feedback.checked)) { item in
                    if item.id != history.first?.id { Divider().padding(.leading, compact ? 12 : 14) }
                    row(item)
                }
            }
            .background { Self.card.fill(FeedbackPage.fill) }
            .overlay { Self.card.strokeBorder(Color.primary.opacity(0.08)) }
            if failed {
                Text(L10n.text("Couldn't check for replies. Please try again later."))
                    .font(compact ? .footnote : .callout).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: open)
    }

    private func row(_ item: Feedback.Sent) -> some View {
        let status = statuses[item.number]
        let unread = (status?.replies.count ?? 0) > item.seen
        let expanded = open == item.number
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                open = expanded ? nil : item.number
                if !expanded { read(item) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: item.kind.symbol).foregroundStyle(item.kind.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(compact ? .subheadline.weight(.medium) : .body.weight(.medium))
                            .lineLimit(expanded ? nil : 1)
                        Text(verbatim: "#\(item.number) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if unread {
                        Circle().fill(systemAccent).frame(width: 8, height: 8).accessibilityLabel(L10n.text("New Reply"))
                    }
                    if let progress = status?.progress {
                        Text(progress.title).font(.caption.weight(.semibold)).foregroundStyle(progress.tint).lineLimit(1).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(progress.tint.opacity(0.14), in: Capsule())
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { replies(item, status) }
        }
        .padding(compact ? 12 : 14)
    }

    private func replies(_ item: Feedback.Sent, _ status: Feedback.Status?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let replies = status?.replies, !replies.isEmpty {
                ForEach(replies, id: \.self) { reply in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "\(L10n.text("Developer")) · \(reply.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(Feedback.reply(reply.text)).font(compact ? .callout : .body)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(compact ? 10 : 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            } else {
                Text(L10n.text("No replies yet. They'll appear here.")).font(.callout).foregroundStyle(.secondary)
            }
            Button { openURL(item.url) } label: { Label(L10n.text("View on GitHub"), systemImage: "arrow.up.right") }
                .buttonStyle(.borderless).font(.callout)
        }
        .padding(.leading, compact ? 0 : 26)
    }
}

private extension View {
    /// The page's buttons: capsules on iPhone and iPad, like the app's other buttons there.
    @ViewBuilder func feedbackButton(_ size: ControlSize) -> some View {
        #if os(iOS)
        controlSize(size).buttonBorderShape(.capsule)
        #else
        controlSize(size)
        #endif
    }
}

/// One kind of feedback as a card: its symbol, name and (with room) a line on what it is for.
private struct FeedbackKindCard: View {
    let kind: Feedback.Kind
    let selected: Bool
    var compact = false
    let action: () -> Void
    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(alignment: .top) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: compact ? 14 : 15, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: compact ? 30 : 32, height: compact ? 30 : 32)
                        .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous))
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selected ? AnyShapeStyle(kind.tint) : AnyShapeStyle(.tertiary))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(compact ? .subheadline.weight(.semibold) : .headline).lineLimit(1)
                    if !compact { Text(kind.blurb).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .padding(compact ? 12 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(FeedbackPage.fill)
                    .overlay { shape.fill(selected ? kind.tint.opacity(0.14) : Color.primary.opacity(hovering ? 0.03 : 0)) }
            }
            .overlay { shape.strokeBorder(selected ? kind.tint.opacity(0.85) : Color.primary.opacity(hovering ? 0.14 : 0.08), lineWidth: selected ? 1.5 : 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension Feedback.Kind {
    var symbol: String {
        switch self {
        case .bug: "ladybug.fill"
        case .idea: "lightbulb.fill"
        case .other: "ellipsis.bubble.fill"
        }
    }
    var tint: Color {
        switch self {
        case .bug: Brand.rose
        case .idea: .orange
        case .other: Brand.indigo
        }
    }
    var blurb: String {
        switch self {
        case .bug: L10n.text("Something isn't working")
        case .idea: L10n.text("An idea or a wish")
        case .other: L10n.text("Anything else")
        }
    }
    /// The editor's prompt, asking for what helps most with this kind.
    var prompt: String {
        switch self {
        case .bug: L10n.text("What happened? What did you expect instead?")
        case .idea: L10n.text("What would make Yingxia better for you?")
        case .other: L10n.text("What's on your mind?")
        }
    }
}
#endif

#if os(tvOS)
/// Settings › Telegram Group: Apple TV can't open the invite, so it goes to a phone as a QR code.
struct TelegramGroupView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TVSettingsSubpage(symbol: "paperplane", title: L10n.text("Telegram Group"), subtitle: L10n.text("Chat with the developer and other users")) {
            VStack(spacing: 24) {
                if let image = QRCode.image(Support.telegram.absoluteString) {
                    Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 320, height: 320).padding(24)
                        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        // Nothing else here takes focus, and Back with nothing focused would leave the app.
                        .loadingFocus(takeFocus: true) { dismiss() }
                }
                Text(L10n.text("Scan with your iPhone to join the group.")).font(.system(size: 24)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
#endif
