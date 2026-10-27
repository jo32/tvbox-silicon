import SwiftUI
import TVCore

struct FavoriteHeartButton: View {
    @Environment(Store.self) private var store
    let item: FavoriteItem
    let name: String
    /// Draws a dark badge so the heart stays readable on poster artwork.
    var onArtwork = false
    /// An empty artwork heart stays hidden until this is true. A saved heart ignores it.
    var revealed = true
    var body: some View {
        let on = store.favorites.contains(item)
        let shown = on || !onArtwork || revealed
        Button { store.favorites.toggle(item) } label: {
            Image(systemName: on ? "heart.fill" : "heart")
                .font(onArtwork ? .system(size: 13, weight: .semibold) : .title3)
                .foregroundStyle(on ? Brand.rose : (onArtwork ? Color.white : Color.secondary))
                .contentTransition(.symbolEffect(.replace))
                .artworkBadge(onArtwork)
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .accessibilityLabel(on ? L10n.text("Remove %@ from favorites", name) : L10n.text("Add %@ to favorites", name))
    }
}

extension View {
    /// The round badge of a control drawn on poster artwork (the heart, a card's details and remove buttons): one size
    /// and one dark plate for all of them, so a row of them reads as a set. Off, a 44-point plain hit area.
    @ViewBuilder func artworkBadge(_ on: Bool = true, fill: Color? = nil) -> some View {
        if on {
            frame(width: 28, height: 28)
                .background(Circle().fill(fill ?? .black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                .contentShape(Circle())
        } else {
            frame(width: 44, height: 44)
        }
    }

    /// Apple TV: Unlike in the focused card's menu (press and hold). The remote cannot reach a heart drawn on a card, so
    /// favorites lists show none there. Elsewhere the heart stays and this does nothing.
    @ViewBuilder func favoriteMenu(_ item: FavoriteItem, name: String) -> some View {
        #if os(tvOS)
        contextMenu { FavoriteMenuButton(item: item, name: name) }
        #else
        self
        #endif
    }
}

struct FavoriteMenuButton: View {
    @Environment(Store.self) private var store
    let item: FavoriteItem
    let name: String
    var body: some View {
        let on = store.favorites.contains(item)
        // A menu row is short: the title is already on the card it was opened from.
        Button(L10n.text(on ? "Unlike" : "Like"), systemImage: on ? "heart.slash" : "heart") {
            store.favorites.toggle(item)
        }
        .accessibilityLabel(on ? L10n.text("Remove %@ from favorites", name) : L10n.text("Add %@ to favorites", name))
    }
}

/// A control on poster artwork beside the heart: a white glyph on the same badge. A destructive one turns rose under
/// the pointer, so the warning color shows only when it is about to be pressed.
struct ArtworkBadgeButton: View {
    let symbol: String
    let label: String
    var destructive = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .artworkBadge(fill: destructive && hovering ? Brand.rose : nil)
        }
        .buttonStyle(.plain)
        #if !os(tvOS)
        .onHover { hovering = $0 }
        #endif
        .animation(.smooth(duration: 0.12), value: hovering)
        .accessibilityLabel(label).help(label)
    }
}
