import SwiftUI
import TVCore

/// Edits one source's display name and API address, applied through `SourceOverrides` so the
/// subscription file itself is never rewritten and the edits survive a refresh.
struct SourceEditorSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let site: Site
    let origin: URL

    @State private var name: String
    @State private var api: String

    init(site: Site, origin: URL) {
        self.site = site
        self.origin = origin
        let override = SourceOverrides.shared.override(for: site, origin: origin)
        _name = State(initialValue: override?.name ?? site.name)
        _api = State(initialValue: override?.api ?? site.api)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Name")) {
                    TextField(L10n.text("Name"), text: $name)
                }
                Section {
                    TextField(L10n.text("Address"), text: $api)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text(L10n.text("The source's API address. Leave empty to use the subscription's."))
                }
                if let current = store.sourceOverrides.override(for: site, origin: origin), current.name != nil || current.api != nil {
                    Section {
                        Button(L10n.text("Reset"), role: .destructive) {
                            store.sourceOverrides.rename(site, origin: origin, to: "")
                            store.sourceOverrides.setAPI(site, origin: origin, to: "")
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("Edit Source"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Save")) {
                        store.sourceOverrides.rename(site, origin: origin, to: name)
                        store.sourceOverrides.setAPI(site, origin: origin, to: api)
                        dismiss()
                    }
                }
            }
        }
    }
}
