#if !os(tvOS)
import SwiftUI
import TVCore

/// The player's channel list (#1010): the list the live channel was picked from, to switch channels without leaving the
/// player, and the channel's lines (#679) when it has several. `label` is the button's face in its row's style.
struct PlayerChannelsButton<Label: View>: View {
    let channel: Channel
    let session: PlaybackSession
    @Binding var isPresented: Bool
    @ViewBuilder let label: () -> Label
    @Environment(Store.self) private var store

    var body: some View {
        if PlayerChannelsSheet.offered(for: channel, session: session, in: store) {
            Button(action: { isPresented = true }, label: label)
                .help(L10n.text("Channel List"))
                .accessibilityLabel(L10n.text("Channel List"))
                .accessibilityIdentifier("player.channels")
        }
    }
}

extension View {
    /// The channel list, on a view that stays while the player's controls come and go, as the episodes sheet is.
    func playerChannelsSheet(isPresented: Binding<Bool>, channel: Channel, session: PlaybackSession) -> some View {
        sheet(isPresented: isPresented) { PlayerChannelsSheet(channel: channel, session: session).playerSheet() }
    }
}

/// The channels a group at a time, the playing one marked and scrolled to, with the lines above them. Half the screen
/// on a phone, so the picture stays in view.
struct PlayerChannelsSheet: View {
    let channel: Channel
    let session: PlaybackSession
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var group: String?
    /// The viewer chose a channel here: the sheet closes once it plays.
    @State private var picked = false

    static let symbol = "list.bullet.rectangle"

    /// A channel picked from a list of several, or one of several lines.
    @MainActor static func offered(for channel: Channel, session: PlaybackSession, in store: Store) -> Bool {
        store.lineup(for: channel) != nil || session.lines.count > 1
    }

    /// The channel playing now.
    private var playing: Channel { store.playing ?? channel }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(store.lineup(for: playing)?.title ?? playing.name)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } }
                }
        }
        .environment(\.glassControls, true)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(minWidth: 520, idealWidth: 620, minHeight: 460, idealHeight: 560)
        #endif
        .onChange(of: store.playing) { _, _ in if picked { dismiss() } }
    }

    private var content: some View {
        let playing = playing
        let channels = store.lineup(for: playing)?.channels ?? []
        var seen = Set<String>()
        let groups = channels.map(\.group).filter { seen.insert($0).inserted }
        let shown = group.flatMap { groups.contains($0) ? $0 : nil } ?? playing.group
        let items = groups.count > 1 ? channels.filter { $0.group == shown } : channels
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if session.lines.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.text("Lines")).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            SourceStrip(items: session.lines.indices.map { .init(id: "\($0)", name: L10n.text("Line %@", "\($0 + 1)")) },
                                        selection: "\(session.line)") { id in
                                if let index = Int(id) { session.choose(line: index) }
                            }
                            .contentMargins(.horizontal, 16, for: .scrollContent).scrollClipDisabled()
                            .padding(.horizontal, -16)
                        }
                    }
                    if groups.count > 1 {
                        SourceStrip(items: groups.map { .init(id: $0, name: $0.isEmpty ? L10n.text("Ungrouped") : $0) }, selection: shown) {
                            group = $0
                        }
                        .contentMargins(.horizontal, 16, for: .scrollContent).scrollClipDisabled()
                        .padding(.horizontal, -16)
                    }
                    LazyVStack(spacing: 4) {
                        ForEach(items) { item in row(item, current: item.id == playing.id).id(item.id) }
                    }
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo(playing.id, anchor: .center) }
            .onChange(of: shown) { _, _ in if let first = items.first { proxy.scrollTo(first.id, anchor: .top) } }
        }
    }

    private func row(_ item: Channel, current: Bool) -> some View {
        Button {
            guard !current else { return }
            picked = true
            store.playing = item
        } label: {
            HStack(spacing: 12) {
                ChannelLogo(channel: item, size: 36)
                Text(item.name).font(current ? .body.weight(.semibold) : .body).lineLimit(1)
                Spacer(minLength: 8)
                if current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Brand.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(current ? Brand.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
#endif
