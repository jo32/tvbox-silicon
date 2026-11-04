import SwiftUI
import TVCore

/// The maintenance list for sources moved between subscriptions.
///
/// Dragging a source onto another subscription's header is quick and easy to forget. This page is
/// the record: every move, where it came from, where it went, when, and whether it still applies —
/// plus the way to put one back, send it somewhere else, or undo the lot.
///
/// The list is deliberately read-only about the feeds themselves: a move never edits a subscription,
/// so a refresh cannot break it and undoing it loses nothing.
struct SourceMovesView: View {
    @Environment(Store.self) private var store
    @State private var confirmingReset = false

    var body: some View {
        let entries = store.sourceMoveEntries()
        Form {
            if entries.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.text("No source has been moved"), systemImage: "arrow.triangle.branch")
                            .font(.body)
                        Text(L10n.text("Drag a source onto another subscription's header in Sources to file it there."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text(L10n.text("Moved Sources"))
                } footer: {
                    Text(L10n.text("A move only changes which group lists the source; it still plays through its own subscription. It is kept when subscriptions refresh, and stays here — waiting — if a target is switched off or removed."))
                }

                Section {
                    Button(role: .destructive) {
                        confirmingReset = true
                    } label: {
                        Text(L10n.text("Put Every Source Back"))
                    }
                } footer: {
                    Text(L10n.text("Every moved source returns to its own subscription. Nothing is deleted either way."))
                }
            }
        }
        .navigationTitle(L10n.text("Moved Sources"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(L10n.text("Put every moved source back?"), isPresented: $confirmingReset, titleVisibility: .visible) {
            Button(L10n.text("Put Every Source Back"), role: .destructive) { store.undoAllSourceMoves() }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Every source returns to its own subscription. Nothing is deleted either way."))
        }
    }

    private func row(_ entry: Store.SourceMoveEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                stateBadge(entry.state)
            }
            Text(entry.move.sourceKey)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(entry.ownTitle).lineLimit(1)
                Image(systemName: "arrow.right").font(.caption2)
                Text(entry.targetTitle).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(entry.move.movedAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contextMenu { actions(entry) }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { store.undoSourceMove(entry) } label: {
                Label(L10n.text("Move Back"), systemImage: "arrow.uturn.backward")
            }
        }
        #endif
        .accessibilityIdentifier("source.move." + entry.id)
    }

    @ViewBuilder private func actions(_ entry: Store.SourceMoveEntry) -> some View {
        Button {
            store.undoSourceMove(entry)
        } label: {
            Label(L10n.text("Move Back"), systemImage: "arrow.uturn.backward")
        }
        Menu {
            ForEach(store.subscriptions.filter { $0.address != entry.move.address && $0.address != entry.move.target }) { target in
                Button(target.title) { store.moveMovedSource(entry, to: target) }
            }
        } label: {
            Label(L10n.text("Move to Another Subscription"), systemImage: "arrow.triangle.branch")
        }
        .disabled(store.subscriptions.filter { $0.address != entry.move.address && $0.address != entry.move.target }.isEmpty)
    }

    @ViewBuilder private func stateBadge(_ state: Store.SourceMoveEntry.State) -> some View {
        switch state {
        case .applied:
            badge(L10n.text("Active"), symbol: "checkmark.circle.fill", tint: .green)
        case .targetOff:
            badge(L10n.text("Target Off"), symbol: "pause.circle.fill", tint: .orange)
        case .missingTarget:
            badge(L10n.text("Target Removed"), symbol: "exclamationmark.circle.fill", tint: .red)
        case .missingSource:
            badge(L10n.text("Source Gone"), symbol: "questionmark.circle.fill", tint: .secondary)
        }
    }

    private func badge(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
    }
}
