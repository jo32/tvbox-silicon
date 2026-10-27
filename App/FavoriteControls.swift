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
                .frame(width: onArtwork ? 28 : 44, height: onArtwork ? 28 : 44)
                .background { if onArtwork { Circle().fill(.black.opacity(0.55)) } }
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .accessibilityHidden(!shown)
        .accessibilityLabel(on ? L10n.text("Remove %@ from favorites", name) : L10n.text("Add %@ to favorites", name))
    }
}

extension View {
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
