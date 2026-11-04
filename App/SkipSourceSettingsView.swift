import SwiftUI
import TVCore

/// Which parties may claim where the intro ends, and in what order they are believed.
///
/// Drag to reorder — the order is the whole mechanism — and switch a source off without losing its
/// position, so turning it back on does not demote it to last.
struct SkipSourceSettingsView: View {
    @Environment(Store.self) private var store
    @State private var order: [SkipSegmentSources.Source] = []
    @State private var disabled: Set<SkipSegmentSources.Source> = []

    var body: some View {
        Form {
            Section {
                ForEach(order, id: \.self) { source in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { !disabled.contains(source) },
                            set: { on in
                                if on { disabled.remove(source) } else { disabled.insert(source) }
                                commit()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title(source))
                                Text(subtitle(source))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    commit()
                }
            } header: {
                Text(L10n.text("Segment Sources"))
            } footer: {
                Text(L10n.text("Drag to reorder. The first source with a usable segment wins."))
            }
        }
        .settingsForm(L10n.text("Segment Sources"))
        .environment(\.editMode, .constant(.active))
        .task {
            order = store.skipSources.order
            disabled = store.skipSources.disabled
        }
    }

    private func commit() {
        store.skipSources = SkipSegmentSources(order: order, disabled: disabled)
        store.saveVault()
    }

    private func title(_ source: SkipSegmentSources.Source) -> String {
        switch source {
        case .manual: return L10n.text("Your Markers")
        case .mediaServer: return L10n.text("Server Chapters")
        case .theIntroDB, .introDB, .publicMetaDB: return L10n.text("Public Timestamps")
        }
    }

    /// Says whether this source knows *this file* or only the title — the difference decides
    /// whether its answer is applied directly or sanity-checked first.
    private func subtitle(_ source: SkipSegmentSources.Source) -> String {
        source.isFileLevel
            ? L10n.text("Describes this exact file")
            : L10n.text("Describes the title; used only if the timing fits")
    }
}
