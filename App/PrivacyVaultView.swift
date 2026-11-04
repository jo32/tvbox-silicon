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
                        .keyboardType(.numberPad)
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
            #if !os(tvOS)
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
struct PrivacyVaultView: View {
    @Environment(Store.self) private var store
    @State private var gated: Gate?
    /// Whether the page is currently allowed to show hidden rows. Re-read on every appearance so a
    /// timeout while the page is open closes it.
    @State private var unlocked = false
    @State private var pendingSource: String?

    private enum Gate: Identifiable {
        case setPasscode
        case confirmCurrent
        case unlock
        var id: Int { hashValue }
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
                } footer: {
                    Text(L10n.text("Without a passcode nothing can be hidden, because hiding without a lock would only confuse."))
                }
            } else {
                passcodeSection
                sourcesSection
                subscriptionsSection
                dangerSection
            }
        }
        .navigationTitle(L10n.text("Privacy"))
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { reload() }
        .onAppear { reload() }
        .sheet(item: $gated) { gate in
            switch gate {
            case .setPasscode:
                PasscodeGate(purpose: .setNew) { code in
                    do {
                        try store.vault.setPasscode(code)
                        store.saveVault()
                        unlocked = true
                        return true
                    } catch { return false }
                }
            case .confirmCurrent:
                PasscodeGate(purpose: .confirmCurrent) { code in
                    store.vault.unlock(code)
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

    // MARK: 源与订阅

    /// Sources the viewer may hide, grouped by the subscription they came from so a whole feed can
    /// be hidden in one switch.
    private var groupedSites: [(entry: SubscriptionEntry, sites: [Site])] {
        store.subscriptions.compactMap { entry in
            guard let document = store.documents[entry.address] else { return nil }
            let sites = document.sites
            return sites.isEmpty ? nil : (entry, sites)
        }
    }

    @ViewBuilder private var sourcesSection: some View {
        if unlocked, !groupedSites.isEmpty {
            ForEach(groupedSites, id: \.entry.address) { group in
                Section {
                    ForEach(group.sites) { site in
                        Toggle(isOn: binding(for: site.key)) {
                            FormLabel(symbol: "square.stack.3d.up.fill", tint: .purple, title: site.name,
                                      subtitle: site.key)
                        }
                        .settingsSwitch()
                    }
                } header: {
                    Text(group.entry.name.isEmpty ? group.entry.address : group.entry.name)
                } footer: {
                    Text(L10n.text("Hidden sources disappear from history, search, favourites and the source picker."))
                }
            }
        } else if !unlocked {
            Section {
                Text(L10n.text("Unlock to choose what to hide."))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var subscriptionsSection: some View {
        if unlocked, !store.subscriptions.isEmpty {
            Section {
                ForEach(store.subscriptions) { entry in
                    Toggle(isOn: binding(for: entry)) {
                        FormLabel(symbol: "tray.full.fill", tint: .indigo,
                                  title: entry.name.isEmpty ? entry.address : entry.name,
                                  subtitle: entry.address)
                    }
                    .settingsSwitch()
                }
            } header: {
                Text(L10n.text("Subscriptions"))
            } footer: {
                Text(L10n.text("Hiding a subscription hides every source it provides."))
            }
        }
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

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { !store.vault.hiddenSources.contains(key) },
            set: { visible in
                do {
                    if visible { try store.vault.show(sources: [key]) }
                    else { try store.vault.hide(sources: [key]) }
                    store.saveVault()
                } catch {
                    // Refused (not unlocked, or no passcode): leave the switch where it was.
                }
            }
        )
    }

    private func binding(for entry: SubscriptionEntry) -> Binding<Bool> {
        Binding(
            get: {
                guard let origin = store.documents[entry.address]?.origin else { return true }
                return !store.vault.hiddenSubscriptions.contains(origin.absoluteString)
            },
            set: { visible in
                guard let document = store.documents[entry.address] else { return }
                let keys = PrivacyVault.sourceKeys(of: document)
                do {
                    if visible { try store.vault.show(subscription: document.origin, sources: keys) }
                    else { try store.vault.hide(subscription: document.origin, sources: keys) }
                    store.saveVault()
                } catch {}
            }
        )
    }

    private func reload() { unlocked = store.vault.unlocked() }
}
