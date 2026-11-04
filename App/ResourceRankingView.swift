import SwiftUI
import TVCore

/// How to choose between several files of the same title.
///
/// Reordering is by drag, because the order *is* the preference — a list of checkboxes would let a
/// person express "I care about resolution and bitrate" but not "resolution first". The presets are
/// the three answers people actually give.
struct ResourceRankingView: View {
    @Environment(Store.self) private var store
    @State private var keys: [ResourceRanking.Key] = []

    var body: some View {
        Form {
            Section {
                ForEach(keys) { key in
                    HStack {
                        Text(title(key.attribute))
                        Spacer()
                        #if os(macOS)
                        // A Mac has no edit mode and no swipe, so the arrows are the reorder here.
                        HStack(spacing: 2) {
                            Button { move(key, by: -1) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.borderless)
                                .disabled(keys.first == key)
                                .accessibilityLabel(L10n.text("Move %@ up", key))
                            Button { move(key, by: 1) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.borderless)
                                .disabled(keys.last == key)
                                .accessibilityLabel(L10n.text("Move %@ down", key))
                        }
                        #endif
                        // Direction is per key: smaller is better for bitrate and size when the
                        // viewer is on a weak connection.
                        if key.attribute.speedTestProvides {
                            Picker("", selection: directionBinding(key)) {
                                Text(L10n.text("Largest First")).tag(true)
                                Text(L10n.text("Smallest First")).tag(false)
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        } else {
                            // A direction for something nothing measures is a switch that does
                            // nothing; the row stays so the order can be set up, but says so.
                            Text(L10n.text("No Data")).font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onMove { from, to in
                    keys.move(fromOffsets: from, toOffset: to)
                    commit()
                }
                .onDelete { offsets in
                    keys.remove(atOffsets: offsets)
                    commit()
                }
            } footer: {
                // No header: the page's own title already says what this is, and a second copy an
                // inch below it is noise.
                Text(L10n.text("Attributes are applied top to bottom. Drag to reorder; swipe to stop using one. The speed test measures resolution only, so ordering by bitrate, file size or colour range does not change which source comes first yet."))
            }

            Section {
                ForEach(ResourceRanking.presets, id: \.name) { preset in
                    Button {
                        keys = preset.ranking.keys
                        commit()
                    } label: {
                        HStack {
                            Text(title(for: preset.name))
                            Spacer()
                            if keys == preset.ranking.keys {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(L10n.text("Presets"))
            }

            if keys.count < ResourceRanking.Key.Attribute.allCases.count {
                Section {
                    ForEach(unusedAttributes, id: \.self) { attribute in
                        Button {
                            keys.append(ResourceRanking.Key(attribute))
                            commit()
                        } label: {
                            FormLabel(symbol: "plus.circle", tint: .green, title: title(attribute))
                        }
                    }
                } header: {
                    Text(L10n.text("Add"))
                }
            }
        }
            .settingsPage()
        .settingsForm(L10n.text("Resource Order"))
        #if !os(macOS)
        // Edit mode is what turns the rows into draggable ones on iOS; a Mac has no such mode and
        // uses the arrows in each row instead.
        .environment(\.editMode, .constant(.active))
        #endif
        .task { keys = store.resourceRanking.keys }
    }

    #if os(macOS)
    private func move(_ key: ResourceRanking.Key, by offset: Int) {
        guard let index = keys.firstIndex(of: key) else { return }
        let target = index + offset
        guard keys.indices.contains(target) else { return }
        keys.swapAt(index, target)
        commit()
    }
    #endif

    private var unusedAttributes: [ResourceRanking.Key.Attribute] {
        ResourceRanking.Key.Attribute.allCases.filter { attribute in
            !keys.contains { $0.attribute == attribute }
        }
    }

    private func directionBinding(_ key: ResourceRanking.Key) -> Binding<Bool> {
        Binding(
            get: { keys.first { $0.attribute == key.attribute }?.descending ?? true },
            set: { newValue in
                guard let index = keys.firstIndex(where: { $0.attribute == key.attribute }) else { return }
                keys[index].descending = newValue
                commit()
            }
        )
    }

    private func commit() {
        store.resourceRanking = ResourceRanking(keys: keys)
        store.saveVault()
    }

    private func title(_ attribute: ResourceRanking.Key.Attribute) -> String {
        switch attribute {
        case .resolution: return L10n.text("Resolution")
        case .bitrate: return L10n.text("Bitrate")
        case .fileSize: return L10n.text("File Size")
        case .colourRange: return L10n.text("Colour Range")
        }
    }

    private func title(for preset: String) -> String {
        switch preset {
        case "Quality": return L10n.text("Quality First")
        case "Speed": return L10n.text("Speed First")
        default: return L10n.text("Default")
        }
    }
}
