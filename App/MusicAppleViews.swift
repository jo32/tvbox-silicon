import SwiftUI
import TVCore

// What Apple Music's catalog adds to the music pages (AppleMusicCatalog): an artist's picture, genres and notes, an
// album's notes, release date, label and genres. Shown only when Apple Music has the artist or album; the pages look
// as before otherwise.

/// Notes a few lines long, the rest on a tap (or a click, or Select on Apple TV).
struct MusicNotes: View {
    let text: String
    @State private var expanded = false
    var body: some View {
        Button { withAnimation(.smooth) { expanded.toggle() } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    .lineLimit(expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                if text.count > 80 { Text(L10n.text(expanded ? "Show Less" : "More")).font(.callout.weight(.semibold)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Where the facts came from, and the way to Apple Music's own page where a browser can open it.
struct MusicAppleCredit: View {
    let url: URL?
    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.text("Info from Apple Music"))
            #if !os(tvOS)
            if let url { Link(L10n.text("Open in Apple Music"), destination: url) }
            #endif
        }
        .font(.caption).foregroundStyle(.tertiary)
    }
}

/// The artist's picture, genres and notes, under the artist page's title.
struct MusicAppleArtistSummary: View {
    let artist: AppleMusicCatalog.Artist
    #if os(tvOS)
    private let side: CGFloat = 180
    #else
    private let side: CGFloat = 96
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if let url = AppleMusicCatalog.artwork(artist.artwork, side: Int(side * 3)) {
                    MusicArtwork(url: url, size: side, symbol: "music.mic").clipShape(Circle())
                }
                if !artist.genres.isEmpty {
                    Text(artist.genres.prefix(3).joined(separator: " · ")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let notes = artist.notes { MusicNotes(text: notes) }
            MusicAppleCredit(url: artist.url)
        }
    }
}

/// An album's notes and facts, after its songs.
struct MusicAppleAlbumAbout: View {
    let album: AppleMusicCatalog.Album

    static func shows(_ album: AppleMusicCatalog.Album) -> Bool { album.notes != nil || album.label != nil || album.released != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("About")).font(.title3.weight(.bold))
            if let notes = album.notes { MusicNotes(text: notes) }
            ForEach(facts, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            if let copyright = album.copyright { Text(copyright).font(.footnote).foregroundStyle(.tertiary) }
            MusicAppleCredit(url: album.url)
        }
        .padding(.top, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var facts: [String] {
        [album.released.map { L10n.text("Released %@", Self.date($0)) }, album.label, album.genres.isEmpty ? nil : album.genres.joined(separator: " · ")]
            .compactMap { $0 }
    }

    /// Apple's `2003-07-31` as the viewer writes dates; a year alone stays a year.
    static func date(_ text: String) -> String {
        guard let date = try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day()) else { return text }
        return date.formatted(date: .long, time: .omitted)
    }
}
