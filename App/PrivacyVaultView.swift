import SwiftUI
import TVCore

/// The passcode sheet that guards a locked vault, and the page behind it that edits what is hidden.
///
/// Two screens, and the difference is deliberate:
///
/// * `PasscodeGate` is asked for a passcode and nothing else. It has no list of what is hidden, no
///   hint about how much is hidden, and no way to cancel into the hidden content. A person holding
///   the phone sees one field.
/// * `PrivacyVaultView` is only reachable once the vault is unlocked, and shows the sources and
///   subscriptions with a switch each.
///
/// The gate is presented as a sheet rather than a page so an unlock is a single deliberate act:
/// there is no back gesture into content that was not unlocked.
struct PasscodeGate: View {
    /// What the passcode is for. Shown so a person knows which lock they are opening.
    let purpose: PasscodePurpose
    /// Called with the typed passcode; returns whether it matched.
    let attempt: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var wrong = false
    @State private var cooldown: Date?
    @FocusState private var focused: Bool

    enum PasscodePurpose {
        case unlock
        case setNew
        case confirmCurrent
        var title: String {
            switch self {
            case .unlock: L10n.text("Enter Passcode")
            case .setNew: L10n.text("Set a Passcode")
            case .confirmCurrent: L10n.text("Enter Current Passcode")
            }
        }
        var note: String {
            switch self {
            case .unlock: L10n.text("Hidden subscriptions and sources are locked.")
            case .setNew: L10n.text("At least %@ characters. Used to show hidden subscriptions and sources.", String(PrivacyVault.minimumLength))
            case .confirmCurrent: L10n.text("Confirm before changing what is hidden.")
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L10n.text("Passcode"), text: $entry)
                        .textContentType(.password)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .accessibilityIdentifier("privacy.passcode")
                } header: {
                    Text(purpose.title)
                } footer: {
                    Text(purpose.note)
                }

                if wrong {
                    Section {
                        Label(L10n.text("Wrong passcode."), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } footer: {
                        if let cooldown, cooldown > Date() {
                            Text(L10n.text("Too many tries. Wait %@ seconds.", String(Int(cooldown.timeIntervalSinceNow.rounded(.up)))))
                        }
                    }
                }

                Section {
                    Button(action: submit) {
                        Text(purpose == .setNew ? L10n.text("Set Passcode") : L10n.text("Unlock"))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(entry.count < PrivacyVault.minimumLength)
                    .accessibilityIdentifier("privacy.submit")
                }
            }
            .navigationTitle(purpose.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }

    private func submit() {
        guard entry.count >= PrivacyVault.minimumLength else { return }
        if attempt(entry) {
            dismiss()
        } else {
            wrong = true
            entry = ""
            // A wrong attempt clears the field: retyping is the deliberate act, not editing.
        }
    }
}

extension PasscodeGate.PasscodePurpose: Equatable {}

/// What is hidden, and the switches that hide it.
///
/// The page only lists *visible* rows plus a separate "hidden" section, so it never leaks the name
/// of something the vault is protecting — a hidden source's real name appears here only after an
/// unlock, which is the point.
///
/// One subscription is one foldable section: the switch on the section hides the whole feed, the
/// switches inside hide one source each, and the field at the top narrows the list to the sources
/// whose name or key matches. Sixty sources as one flat wall of switches is unusable.
///
/// A switch is bound to its own source identity — its subscription's address plus the key the feed
/// gave it — never to the key alone. Unrelated feeds share keys all the time (`csp_AppYsV2` appears
/// in dozens of public subscriptions), so a key-only binding turned one switch into two.
struct PrivacyVaultView: View {
    @Environment(Store.self) private var store
    @State private var gated: Gate?
    /// The current passcode after it has been verified, held while the owner types its replacement.
    /// `setPasscode(_:replacing:)` re-verifies it, so it must be kept from the confirm step.
    @State private var verifiedPasscode: String?
    /// Whether the page is currently allowed to show hidden rows. Re-read on every appearance so a
    /// timeout while the page is open closes it.
    @State private var unlocked = false
    /// The timer that closes the page when the unlock lapses.
    @State private var relock: Task<Void, Never>?
    @State private var query = ""
    /// The subscriptions whose sources are showing. All folded on arrival: a long list of feeds
    /// reads better folded, and the field above finds a source anyway.
    @State private var expanded: Set<String> = []

    private enum Gate: Identifiable {
        case setPasscode
        case confirmCurrent
        case unlock
        var id: Int { hashValue }
    }

    /// One subscription and the sources it contributes, as the Privacy page sees them.
    private struct Feed: Identifiable {
        let entry: SubscriptionEntry
        let document: Subscription
        var id: String { entry.address }
        var title: String { entry.name.isEmpty ? entry.address : entry.name }
        var origin: URL { document.origin }
        var keys: [String] { document.sites.map(\.sourceKey) }

        /// The sources matching what was typed, by name or by key. An empty query keeps them all.
        func matching(_ query: String) -> [Site] {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return document.sites }
            return document.sites.filter {
                $0.name.lowercased().contains(needle) || $0.sourceKey.lowercased().contains(needle)
            }
        }
    }

    var body: some View {
        Form {
            if !store.vault.hasPasscode {
                Section {
                    Button {
                        gated = .setPasscode
                    } label: {
                        FormLabel(symbol: "lock.fill", tint: .blue, title: L10n.text("Set a Passcode"),
                                  subtitle: L10n.text("Needed before anything can be hidden."))
                    }
                    // A fresh install shows this row instead of a passcode field, so acceptance can assert
                    // "the vault drew" without guessing a passcode: one of setup/passcode/unlock is present.
                    .accessibilityIdentifier("privacy.setup")
                } footer: {
                    Text(L10n.text("Without a passcode nothing can be hidden, because hiding without a lock would only confuse."))
                }
            } else {
                passcodeSection
                if unlocked {
                    searchSection
                    feedsSection
                } else {
                    Section {
                        Text(L10n.text("Unlock to choose what to hide."))
                            .foregroundStyle(.secondary)
                    }
                }
                dangerSection
            }
        }
        // Named for the lock, not for "Privacy": it is a page inside the privacy settings, and a
        // page that repeats its parent's title reads as if the tap did nothing.
        .navigationTitle(L10n.text("Privacy Vault"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: store.vault.revision) {
            // A timeout can fire while this page is open and nothing else mutates the vault, so the
            // "Unlocked" label would stay stale. Watch the mutating check — it flips a stale unlock
            // into a lock and bumps `revision`, which restarts this task and triggers `.onChange`.
            while !Task.isCancelled {
                guard store.vault.isUnlocked() else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onAppear { reload() }
        .onChange(of: store.vault.revision) { _, _ in reload() }
        .onDisappear { relock?.cancel() }
        .sheet(item: $gated) { gate in
            switch gate {
            case .setPasscode:
                PasscodeGate(purpose: .setNew) { code in
                    do {
                        if let current = verifiedPasscode {
                            try store.vault.setPasscode(code, replacing: current)
                        } else {
                            try store.vault.setPasscode(code)
                        }
                        verifiedPasscode = nil
                        store.saveVault()
                        unlocked = true
                        return true
                    } catch { return false }
                }
            case .confirmCurrent:
                PasscodeGate(purpose: .confirmCurrent) { code in
                    guard store.vault.unlock(code) else { return false }
                    verifiedPasscode = code
                    // Present the set-new sheet after this one dismisses, so the two gates do not
                    // fight over the same `.sheet(item:)` binding.
                    DispatchQueue.main.async { gated = .setPasscode }
                    return true
                }
            case .unlock:
                PasscodeGate(purpose: .unlock) { code in
                    let ok = store.vault.unlock(code)
                    if ok { unlocked = true }
                    return ok
                }
            }
        }
    }

    // MARK: 密码

    @ViewBuilder private var passcodeSection: some View {
        Section {
            LabeledContent {
                Text(unlocked ? L10n.text("Unlocked") : L10n.text("Locked"))
                    .foregroundStyle(unlocked ? .green : .secondary)
            } label: {
                FormLabel(symbol: unlocked ? "lock.open.fill" : "lock.fill",
                          tint: unlocked ? .green : .gray,
                          title: L10n.text("Passcode"))
            }
            if !unlocked {
                Button(L10n.text("Unlock")) { gated = .unlock }
                    .accessibilityIdentifier("privacy.unlock")
            } else {
                Button(L10n.text("Lock Now")) {
                    store.vault.lock()
                    store.saveVault()
                    unlocked = false
                }
                Button(L10n.text("Change Passcode")) { gated = .confirmCurrent }
            }
        } footer: {
            Text(L10n.text("Unlocking lasts %@ minutes, and ends when the app goes to the background.",
                           String(Int(store.vault.unlockDuration / 60))))
        }
    }

    // MARK: 搜索

    @ViewBuilder private var searchSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text("Find a source"), text: $query)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("privacy.search")
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        } footer: {
            Text(L10n.text("Narrows the list below; it does not change what is hidden."))
        }
    }

    // MARK: 源与订阅

    /// Every subscription with a copy, in the order they were added.
    private var feeds: [Feed] {
        store.subscriptions.compactMap { entry in
            guard let document = store.documents[entry.address], !document.sites.isEmpty else { return nil }
            return Feed(entry: entry, document: document)
        }
    }

    @ViewBuilder private var feedsSection: some View {
        if feeds.isEmpty {
            Section {
                Text(L10n.text("No subscriptions to hide yet."))
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(feeds) { feed in
                feedSection(feed)
            }
        }
    }

    @ViewBuilder private func feedSection(_ feed: Feed) -> some View {
        let sites = feed.matching(query)
        let hidden = feed.document.sites.filter { store.vault.isHidden(sourceKey: $0.sourceKey, origin: feed.origin) }.count
        Section {
            Toggle(isOn: subscriptionBinding(feed)) {
                FormLabel(symbol: "tray.full.fill", tint: .indigo,
                          title: feed.title,
                          subtitle: hidden == 0
                            ? L10n.text("%lld sources", feed.document.sites.count)
                            : L10n.text("%lld hidden of %lld", hidden, feed.document.sites.count))
            }
            .settingsSwitch()
            .accessibilityIdentifier("privacy.feed." + feed.entry.address)

            #if os(tvOS)
            // `DisclosureGroup` is not on the TV, so the fold is a row of its own: pressing it opens
            // the feed, the same way the chevron does on a phone.
            Button { toggle(feed) } label: {
                HStack {
                    foldLabel(feed, sites)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded(feed) ? 90 : 0))
                }
            }
            if isExpanded(feed) { sourceToggles(feed, sites) }
            #else
            DisclosureGroup(isExpanded: expansion(feed)) {
                sourceToggles(feed, sites)
            } label: {
                foldLabel(feed, sites)
            }
            #endif
        } footer: {
            Text(L10n.text("Hidden sources disappear from history, search, favourites and the source picker."))
        }
    }

    /// One switch per source, for the feed whose fold is open.
    @ViewBuilder private func sourceToggles(_ feed: Feed, _ sites: [Site]) -> some View {
        ForEach(sites) { site in
            Toggle(isOn: sourceBinding(site, origin: feed.origin)) {
                FormLabel(symbol: "square.stack.3d.up.fill", tint: .purple, title: site.name,
                          subtitle: site.sourceKey)
            }
            .settingsSwitch()
            // A hidden feed hides all of its sources at once; the rows inside would only disagree
            // with it, so they wait until the feed itself is visible again.
            .disabled(store.vault.isHidden(subscription: feed.origin))
            .accessibilityIdentifier("privacy.source." + site.sourceKey)
        }
        if sites.isEmpty {
            Text(L10n.text("No source matches %@.", query))
                .foregroundStyle(.secondary)
        }
    }

    /// The fold's own line: how many sources it holds, or how many matched what was typed.
    private func foldLabel(_ feed: Feed, _ sites: [Site]) -> some View {
        Text(query.isEmpty ? L10n.text("Sources") : L10n.text("Matching sources (%lld)", sites.count))
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// Whether a feed's sources are showing. A search opens them all, so a match is never hidden
    /// behind a fold the viewer has to find.
    private func isExpanded(_ feed: Feed) -> Bool {
        !query.isEmpty || expanded.contains(feed.id)
    }

    private func toggle(_ feed: Feed) {
        if expanded.contains(feed.id) { expanded.remove(feed.id) } else { expanded.insert(feed.id) }
    }

    @ViewBuilder private var dangerSection: some View {
        if unlocked {
            Section {
                Button(role: .destructive) {
                    try? store.vault.removePasscode()
                    store.saveVault()
                    unlocked = false
                } label: {
                    Text(L10n.text("Remove Passcode and Unhide Everything"))
                }
            } footer: {
                Text(L10n.text("Everything hidden becomes visible again. Nothing is deleted either way."))
            }
        }
    }

    // MARK: 绑定

    private func expansion(_ feed: Feed) -> Binding<Bool> {
        Binding(
            get: { !query.isEmpty || expanded.contains(feed.id) },
            set: { open in
                if open { expanded.insert(feed.id) } else { expanded.remove(feed.id) }
            }
        )
    }

    private func sourceBinding(_ site: Site, origin: URL) -> Binding<Bool> {
        Binding(
            get: { !store.vault.isHidden(sourceKey: site.sourceKey, origin: origin) },
            set: { visible in
                do {
                    if visible { try store.vault.show(sourceKeys: [site.sourceKey], origin: origin) }
                    else { try store.vault.hide(sourceKeys: [site.sourceKey], origin: origin) }
                    store.saveVault()
                } catch {
                    // Refused (not unlocked, or no passcode): leave the switch where it was.
                }
            }
        )
    }

    private func subscriptionBinding(_ feed: Feed) -> Binding<Bool> {
        Binding(
            get: { !store.vault.isHidden(subscription: feed.origin) },
            set: { visible in
                do {
                    if visible { try store.vault.show(subscription: feed.origin, sourceKeys: feed.keys) }
                    else { try store.vault.hide(subscription: feed.origin, sourceKeys: feed.keys) }
                    store.saveVault()
                } catch {}
            }
        )
    }

    private func reload() {
        unlocked = store.vault.unlocked()
        scheduleRelock()
    }

    /// Closes the page when the unlock window lapses.
    ///
    /// The vault has always expired the unlock, but nothing acted on it: the page kept showing the
    /// hidden subscriptions and the switches to unhide them until the viewer happened to leave and
    /// come back. A timeout that only takes effect on navigation is not a timeout.
    private func scheduleRelock() {
        relock?.cancel()
        guard unlocked, let expires = store.vault.unlockExpiresAt else { return }
        relock = Task { @MainActor in
            let wait = expires.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            reload()
        }
    }
}
