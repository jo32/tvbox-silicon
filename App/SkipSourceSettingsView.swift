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
                        // A switch that changes nothing is worse than one that says it cannot:
                        // these three need a network call to a timestamp database, and no such
                        // call is made yet, so they are listed and locked rather than left on.
                        .disabled(!source.isConnected)
                        #if os(macOS)
                        // A Mac has no edit mode and no swipe, so the arrows are the reorder here.
                        HStack(spacing: 2) {
                            Button { move(source, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless)
                                .disabled(order.first == source)
                            Button { move(source, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless)
                                .disabled(order.last == source)
                        }
                        #endif
                    }
                    .opacity(source.isConnected ? 1 : 0.55)
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    commit()
                }
            } footer: {
                Text(L10n.text("Drag to reorder. The first source with a usable segment wins. Your own markers and the file's chapters are read on this device; the public timestamp databases are not connected yet, and their switches stay off until they are."))
            }
        }
            .settingsPage()
        .settingsForm(L10n.text("Segment Sources"))
        #if !os(macOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .task {
            order = store.skipSources.order
            disabled = store.skipSources.disabled
        }
    }

    #if os(macOS)
    private func move(_ source: SkipSegmentSources.Source, by offset: Int) {
        guard let index = order.firstIndex(of: source) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        commit()
    }
    #endif

    private func commit() {
        store.skipSources = SkipSegmentSources(order: order, disabled: disabled)
        store.saveVault()
    }

    /// The databases keep their own names: "Public Timestamps" three times over reads as three
    /// identical rows rather than as three parties that might disagree.
    private func title(_ source: SkipSegmentSources.Source) -> String {
        switch source {
        case .manual: return L10n.text("Your Markers")
        case .mediaServer: return L10n.text("Server Chapters")
        case .theIntroDB: return "TheIntroDB"
        case .introDB: return "IntroDB"
        case .publicMetaDB: return "PublicMetaDB"
        }
    }

    /// Says whether this source knows *this file* or only the title — the difference decides
    /// whether its answer is applied directly or sanity-checked first — and, for the three that are
    /// not wired yet, says that instead of describing a behaviour it does not have.
    private func subtitle(_ source: SkipSegmentSources.Source) -> String {
        guard source.isConnected else { return L10n.text("Not connected yet: no request is made to these databases.") }
        switch source {
        case .manual: return L10n.text("The intro end and outro you set on a video's page")
        case .mediaServer: return L10n.text("Chapters carried inside the file")
        default: return source.isFileLevel
            ? L10n.text("Describes this exact file")
            : L10n.text("Describes the title; used only if the timing fits")
        }
    }
}
