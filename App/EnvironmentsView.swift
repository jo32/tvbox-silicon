import SwiftUI
import TVCore

/// Separate viewing lives: each with its own libraries, history, watchlist and reporting.
///
/// The footer and the delete confirmation both say the same thing Rex's `Environment.strings` says,
/// because it is the one thing a person must understand before tapping delete: only this
/// environment's data goes, and anything another environment still uses stays.
struct EnvironmentsView: View {
    @Environment(Store.self) private var store
    @State private var newName = ""
    @State private var adding = false
    @State private var removing: Environments.Environment?

    var body: some View {
        Form {
            Section {
                ForEach(store.environments.all) { environment in
                    row(environment)
                }
            } footer: {
                Text(L10n.text("Each environment has its own libraries, watch history, watchlist and reporting. Deleting one removes only its data."))
            }

            Section {
                Button {
                    adding = true
                } label: {
                    FormLabel(symbol: "plus.circle.fill", tint: .green, title: L10n.text("New Environment"))
                }
            }
        }
        .settingsForm(L10n.text("Environments"))
        .alert(L10n.text("New Environment"), isPresented: $adding) {
            TextField(L10n.text("Name"), text: $newName)
            Button(L10n.text("Cancel"), role: .cancel) { newName = "" }
            Button(L10n.text("Create")) {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.environments.add(name: name)
                store.saveVault()
                newName = ""
            }
        }
        .alert(L10n.text("Delete Environment?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L10n.text("Cancel"), role: .cancel) { removing = nil }
            Button(L10n.text("Delete"), role: .destructive) {
                if let target = removing {
                    store.environments.remove(target.id)
                    store.saveVault()
                }
                removing = nil
            }
        } message: {
            Text(L10n.text("Only this environment's history, watchlist and favourites are removed. Libraries and modules another environment still uses are kept."))
        }
    }

    @ViewBuilder
    private func row(_ environment: Environments.Environment) -> some View {
        let isActive = environment.id == store.environments.activeID
        let isDefault = environment.id == store.environments.all.first?.id

        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.environments.activate(environment.id)
                store.saveVault()
            } label: {
                HStack {
                    Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    Text(environment.name)
                    Spacer()
                    if isDefault { Text(L10n.text("Default")).font(.caption).foregroundStyle(.tertiary) }
                }
            }
            .buttonStyle(.plain)

            // Reporting is per environment: the usual reason to have a second one is that its
            // activity should not appear anywhere.
            Toggle(isOn: Binding(
                get: { environment.reportsActivity },
                set: { store.environments.setReportsActivity($0, for: environment.id); store.saveVault() }
            )) {
                Text(L10n.text("Report Activity")).font(.footnote).foregroundStyle(.secondary)
            }
            .disabled(!isActive)
            .opacity(isActive ? 1 : 0.5)

            if !isDefault {
                Button(role: .destructive) {
                    removing = environment
                } label: {
                    Text(L10n.text("Delete")).font(.footnote)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
