import SwiftUI

/// The built-in Bilibili source's icon: Bilibili's TV logo, white on Bilibili blue like its app icon.
/// The logo is the official glyph as vector data (Assets.xcassets/BilibiliLogo, from Simple Icons),
/// so it stays sharp from a chip to a TV card.
struct BilibiliMark: View {
    static let blue = Color(red: 0, green: 0.682, blue: 0.925)
    /// Bilibili's pink (#FB7299), for what the account has done: liked, coined, followed.
    static let pink = Color(red: 0.984, green: 0.447, blue: 0.6)
    var size: CGFloat = 44

    var body: some View {
        #if os(tvOS)
        let size = size >= 44 ? max(size, 56) : size
        #endif
        Image("BilibiliLogo")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.white)
            .padding(size * 0.17)
            .frame(width: size, height: size)
            .background(Self.blue, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The Bilibili logo on its own, in the current foreground style, for use inline with text (chips),
/// where it reads like an SF Symbol rather than an app-icon tile.
struct BilibiliGlyph: View {
    var size: CGFloat = 15

    var body: some View {
        #if os(tvOS)
        let size = max(size, 28)
        #endif
        Image("BilibiliLogo")
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
