import SwiftUI
import TVCore

/// Messages the website publishes for the people using the app (`website/public/messages.json`), each
/// shown once in an alert. Unlike release notes they also reach App Store and TestFlight builds.
@MainActor @Observable final class Announcements {
    /// The first message this device hasn't shown; it waits while something else is on screen.
    var current: MessageFeed.Message? { pending.first }
    /// Messages not shown yet; they put a New badge on Messages.
    var unread: [MessageFeed.Message] { pending }
    /// Every message for this build that is live now, read or not, in the feed's order: the Messages page.
    var all: [MessageFeed.Message] { feed.messages.filter { $0.applies(to: build) } }
    private var pending: [MessageFeed.Message] = []
    private var feed: MessageFeed
    private var checking = false
    private var lastChecked: Date?
    private let build: MessageFeed.Build
    private let defaults: UserDefaults
    private let address: URL
    private static let interval: TimeInterval = 15 * 60

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        var version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        var number = Int(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
        var address = MessageFeed.address
        #if DEBUG
        // QA: `-qaMessageFeed <url>` reads another feed (a file:// path works on simulators); `-qaVersion 1.7.7`
        // and `-qaBuild 27` pretend to be another build.
        if let value = defaults.string(forKey: "qaMessageFeed"), let url = URL(string: value) { address = url }
        if let value = defaults.string(forKey: "qaVersion") { version = value }
        if defaults.object(forKey: "qaBuild") != nil { number = defaults.integer(forKey: "qaBuild") }
        #endif
        build = MessageFeed.Build(appStore: Distribution.isAppStore, version: version, number: number)
        self.address = address
        feed = defaults.data(forKey: Keys.feed).flatMap { try? JSONDecoder().decode(MessageFeed.self, from: $0) } ?? MessageFeed(messages: [])
        lastChecked = defaults.object(forKey: Keys.checked) as? Date
        refresh()
    }

    /// Asks whether the feed changed at most every quarter hour (`force`, as pulling to refresh, asks anyway); an
    /// unchanged feed costs a 304 without a body. Between checks the saved copy decides (a message may have started).
    func check(force: Bool = false) async {
        guard !checking else { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { refresh(); return }
        checking = true
        defer { checking = false }
        do {
            // The validator only counts with the saved copy it names.
            let known = defaults.data(forKey: Keys.feed) == nil ? nil
                : defaults.data(forKey: Keys.validator).flatMap { try? JSONDecoder().decode(MessageFeed.Validator.self, from: $0) }
            if case .changed(let fetched, let validator) = try await MessageFeed.fetch(address, ifChangedFrom: known) {
                feed = fetched
                defaults.set(try? JSONEncoder().encode(fetched), forKey: Keys.feed)
                defaults.set(try? JSONEncoder().encode(validator), forKey: Keys.validator)
            }
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Keys.checked)
        } catch {
            Diagnostics.shared.record(.warning, "messages", "Message feed check failed: \(error.localizedDescription)")
        }
        refresh()
    }

    /// Records the message on screen as shown. The next one follows after a moment: an alert presented
    /// while the last one is still closing doesn't appear.
    func dismiss() {
        guard let message = current else { return }
        defaults.set(Array((seen + [message.id]).suffix(200)), forKey: Keys.seen)
        pending = []
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            refresh()
        }
    }

    /// Records every live message as shown, as when someone reads them on the Messages page.
    func markAllRead() {
        let new = all.map(\.id).filter { !seen.contains($0) }
        guard !new.isEmpty else { return }
        defaults.set(Array((seen + new).suffix(200)), forKey: Keys.seen)
        refresh()
    }

    private var seen: [String] { defaults.stringArray(forKey: Keys.seen) ?? [] }

    private func refresh() {
        let next = feed.pending(for: build, seen: Set(seen))
        if next != pending { pending = next }
    }

    private enum Keys {
        static let feed = "messages.feed"
        static let validator = "messages.validator"
        static let checked = "messages.lastChecked"
        static let seen = "messages.seen"
    }
}

extension View {
    /// Shows the next message in an alert, once nothing else is on screen.
    func announcementPresentation(_ announcements: Announcements, blocked: Bool) -> some View {
        modifier(AnnouncementAlert(announcements: announcements, blocked: blocked))
    }
}

private struct AnnouncementAlert: ViewModifier {
    let announcements: Announcements
    let blocked: Bool
    /// True a moment after nothing else is on screen: an alert presented while a sheet (What's New after an
    /// update) is still closing never appears.
    @State private var settled = false
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let message = announcements.current
        content.alert(message?.title.text() ?? "", isPresented: Binding(get: { settled && !blocked && message != nil }, set: { if !$0 { announcements.dismiss() } }),
                      presenting: message) { message in
            #if !os(tvOS)
            // Apple TV can't open web pages.
            if let link = message.link {
                Button(message.linkTitle?.text() ?? L10n.text("Learn More")) { openURL(link) }
            }
            #endif
            Button(L10n.text("OK"), role: .cancel) {}
        } message: { message in
            Text(message.body.text())
        }
        .task(id: blocked) {
            settled = false
            guard !blocked else { return }
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { settled = true }
        }
    }
}

// MARK: Messages page

/// Every message the website has for this device. Opening it counts as reading them, so none pops up later.
struct MessagesView: View {
    @Environment(Announcements.self) private var announcements
    @Environment(\.openURL) private var openURL
    /// The messages that were unread when the page opened; they keep a dot while it is on screen.
    @State private var fresh: Set<String> = []

    var body: some View {
        let messages = announcements.all
        Group {
            if messages.isEmpty {
                EmptyResults(symbol: "megaphone", title: L10n.text("No Messages"),
                             message: L10n.text("News and notices from Yingxia appear here."), fills: true)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(messages) { card($0) }
                    }
                    .pageContainer()
                }
                .scrollIndicators(.hidden)
            }
        }
        #if os(iOS)
        .refreshable { await announcements.check(force: true); read() }
        #endif
        .screenBackdrop()
        .screenTitle(L10n.text("Messages"))
        // Read at once, so a waiting message doesn't pop up over the page, and again after the check.
        .task { read(); await announcements.check(); read() }
    }

    private func read() {
        fresh.formUnion(announcements.unread.map(\.id))
        announcements.markAllRead()
    }

    private func card(_ message: MessageFeed.Message) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if fresh.contains(message.id) {
                    Circle().fill(Brand.accent).frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityLabel(L10n.text("New"))
                }
                Text(message.title.text()).font(.headline)
                Spacer(minLength: 8)
                if let date = message.start.flatMap(MessageFeed.Message.date) {
                    Text(date, format: .dateTime.month().day()).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text(message.body.text())
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #if !os(tvOS)
            if let link = message.link {
                Button { openURL(link) } label: {
                    Label(message.linkTitle?.text() ?? L10n.text("Learn More"), systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentPanel(cornerRadius: 22)
        .accessibilityElement(children: .contain)
    }
}
