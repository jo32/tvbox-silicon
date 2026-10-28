import SwiftUI
import TVCore

/// The episode's artwork for the waiting screen.
struct PlaybackArtwork: Equatable {
    var poster: URL?
    var headers: [String: String] = [:]
}

/// What the waiting screen says: one calm line, and a second one only when there is something to try.
struct PlaybackWait: Equatable {
    var message: String
    var caption: String?
    /// Points to the other lines, under the ⋯ button, drawn with that button's own symbol.
    var suggestsLines = false
    /// The small print, once the wait has run `detailsAfter`: the download's speed and size, and the player's last steps.
    var detail: String?
    var steps: [String] = []
    /// Short waits show only the spinner and the line; longer ones say how they are going.
    static let detailsAfter: TimeInterval = 3
}

/// The player's wait, ready to drop into a player's content overlay.
@MainActor struct PlaybackWaitContent {
    let artwork: PlaybackArtwork
    /// The first load shows the artwork; a stall during playback keeps the frame and shows only the words.
    let starting: Bool
    var showsWords = true
    var appearAfter: TimeInterval = 0
    let state: @MainActor (TimeInterval) -> PlaybackWait
    var view: some View {
        PlaybackWaitView(artwork: artwork, starting: starting, showsWords: showsWords, appearAfter: appearAfter, state: state).id(starting)
    }
}

/// While a video gets ready: its artwork where the picture will be, a slow band of morning light passing
/// over it, and one line of words below. It sits in the player's content overlay, under AVKit's own
/// controls, so a tap still reaches them, and nothing of it covers their rows.
struct PlaybackWaitView: View {
    let artwork: PlaybackArtwork
    let starting: Bool
    var showsWords = true
    var appearAfter: TimeInterval = 0
    let state: @MainActor (TimeInterval) -> PlaybackWait
    @State private var started = Date()
    @State private var poster: CGImage?
    @State private var drifting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let picture = Self.picture(in: proxy.size)
            let layout = Self.layout(size: proxy.size, picture: picture)
            ZStack {
                if starting {
                    ambient
                    // Behind an error only the colours stay, so the message has the stage to itself.
                    if showsWords { artwork(picture: picture, card: layout.card) }
                }
                if showsWords { words(in: proxy.size, layout: layout) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
        .task(id: artwork.poster) {
            guard starting, let url = artwork.poster else { return }
            let image = await PosterPalette.image(url, headers: artwork.headers)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { poster = image }
            drifting = true
        }
    }

    /// Where the video will appear: 16:9, fitted and centred, as the players lay it out.
    static func picture(in size: CGSize) -> CGRect {
        let width = min(size.width, size.height * 16 / 9), height = width * 9 / 16
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// The artwork's colours, blurred, so the room around the picture is never black.
    private var ambient: some View {
        Color.black.overlay {
            if let poster {
                Image(decorative: poster, scale: 1).resizable().scaledToFill()
                    .blur(radius: 70).opacity(0.55)
                    .overlay(Color.black.opacity(0.32))
                    .transition(.opacity)
            }
        }
        .clipped()
    }

    @ViewBuilder private func artwork(picture: CGRect, card area: CGRect) -> some View {
        if let poster, CGFloat(poster.width) >= CGFloat(poster.height) * 1.3 {
            // A wide still fills the picture and drifts, slowly, like an opening title.
            ZStack {
                Color.clear.overlay {
                    Image(decorative: poster, scale: 1).resizable().scaledToFill()
                        .scaleEffect(drifting && !reduceMotion ? 1.05 : 1)
                        .animation(.linear(duration: 30), value: drifting)
                }
                .overlay(Color.black.opacity(0.16))
                if !reduceMotion { LightSweep() }
            }
            .frame(width: picture.width, height: picture.height).clipped()
            .position(x: picture.midX, y: picture.midY)
            .transition(.opacity)
        } else if let poster {
            // A tall poster floats as a card on its own colours, with the light passing over the card.
            let ratio = CGFloat(poster.width) / CGFloat(max(1, poster.height))
            let height = max(1, min(area.height, area.width / ratio)), width = height * ratio
            let shape = RoundedRectangle(cornerRadius: height * 0.035, style: .continuous)
            Image(decorative: poster, scale: 1).resizable()
                .frame(width: width, height: height)
                .overlay { if !reduceMotion { LightSweep() } }
                .clipShape(shape)
                .overlay { shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.5), radius: height * 0.09, y: height * 0.035)
                .position(x: area.midX, y: area.midY)
                .transition(.opacity)
        } else {
            ZStack {
                LinearGradient(colors: [Color(white: 0.15), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                if !reduceMotion { LightSweep() }
            }
            .frame(width: picture.width, height: picture.height).clipped()
            .position(x: picture.midX, y: picture.midY)
        }
    }

    /// Where the card and the words go.
    private struct WaitLayout {
        /// Room for a tall poster; the card is fitted inside it, centred.
        var card: CGRect
        /// The horizontal centre shared by the card and the words.
        var axis: CGFloat
        /// The words hang from this line when it is set; otherwise they stand `wordsBottom` above the bottom edge.
        var wordsTop: CGFloat?
        var wordsBottom: CGFloat = 0
        /// One line: the hint joins the message, so nothing changes height when it appears.
        var inlineCaption = false
    }

    @MainActor private static func layout(size: CGSize, picture: CGRect) -> WaitLayout {
        #if os(iOS)
        // AVKit puts its play button over the middle of the picture: the card is centred on it, in both orientations.
        let axis = controlsAxis(width: size.width), centre = picture.midY
        if size.height > size.width * 1.2 {
            // Upright: clear of the title bar above, with the words hanging under the card, clear of the scrubber.
            let half = max(40, min(size.height * 0.19, centre - 176, size.height - 230 - centre))
            let card = CGRect(x: axis - (picture.width - 48) / 2, y: centre - half, width: picture.width - 48, height: half * 2)
            return WaitLayout(card: card, axis: axis, wordsTop: card.maxY + 24)
        }
        // Sideways: between the title bar and one line of words, with its small print, just above the scrubber (its top
        // is about 62 pt up).
        let wordsBottom: CGFloat = 68, wordsTop = size.height - wordsBottom - 74
        let half = max(40, min(size.height * 0.3, centre - 111, wordsTop - 10 - centre))
        let card = CGRect(x: axis - picture.width * 0.3, y: centre - half, width: picture.width * 0.6, height: half * 2)
        return WaitLayout(card: card, axis: axis, wordsBottom: wordsBottom, inlineCaption: true)
        #elseif os(macOS)
        // AVPlayerView's floating controls take the lower part of the window (about 120–205 pt up in a 700 pt one):
        // the card and the words stay above them, the words hanging just under the card.
        let wordsLimit = min(size.height * 0.68, size.height - 215)
        var card = picture.insetBy(dx: 0, dy: picture.height * 0.08)
        card.size.height = max(1, min(card.height, wordsLimit - wordsHeight - 18 - card.minY))
        return WaitLayout(card: card, axis: size.width / 2, wordsTop: card.maxY + 18)
        #else
        // No button sits over the card here: it takes the picture's height above the words.
        var card = picture.insetBy(dx: 0, dy: picture.height * 0.08)
        card.size.height = max(1, min(card.height, size.height - bottomGap - wordsHeight - 20 - card.minY))
        return WaitLayout(card: card, axis: size.width / 2, wordsBottom: bottomGap)
        #endif
    }

    #if os(iOS)
    /// Where AVKit centres its play button. On an iPhone held sideways it lays its controls out from the camera side's
    /// safe inset to 8 pt from the other edge (measured on iOS 26.5), so the button sits off the screen's middle.
    /// The player's overlay gets no safe area of its own, so this reads the window's.
    @MainActor private static func controlsAxis(width: CGFloat) -> CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.keyWindow ?? scene.windows.first,
              // A phone held sideways. iPhone Duo's inner display is regular both ways and keeps the camera elsewhere.
              window.traitCollection.verticalSizeClass == .compact else { return width / 2 }
        let insets = window.safeAreaInsets
        switch scene.interfaceOrientation {
        case .landscapeRight: return (insets.left + width - 8) / 2 // camera on the left
        case .landscapeLeft: return (8 + width - insets.right) / 2 // camera on the right
        default: return width / 2
        }
    }
    #endif

    private func words(in size: CGSize, layout: WaitLayout) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(started))
            let wait = elapsed >= appearAfter ? state(elapsed) : nil
            let stack = VStack(spacing: 10) {
                if let wait {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(.white)
                        // A new message replaces the old with a soft blur rather than two lines crossing.
                        line(wait, inline: layout.inlineCaption).lineLimit(1)
                            .id("\(wait.message)|\(wait.caption ?? "")|\(wait.suggestsLines)").transition(.blurReplace)
                    }
                    .font(Self.pillFont)
                    .foregroundStyle(.white)
                    .padding(.horizontal, Self.pillPadding * 1.6).padding(.vertical, Self.pillPadding)
                    .glassSurface(.regular, in: Capsule())
                    if !layout.inlineCaption, let caption = caption(wait) {
                        caption.font(Self.captionFont).foregroundStyle(.white.opacity(0.66))
                            .multilineTextAlignment(.center).lineLimit(2)
                            .frame(maxWidth: Self.captionWidth)
                            .transition(.opacity)
                    }
                    if wait.detail != nil || !wait.steps.isEmpty {
                        WaitDetails(detail: wait.detail, steps: Array(wait.steps.suffix(layout.inlineCaption ? 1 : 2)))
                            .frame(maxWidth: Self.captionWidth)
                            .transition(.opacity)
                    }
                }
            }
            .animation(.smooth(duration: 0.45), value: wait)
            .padding(.horizontal, 24)
            .accessibilityElement(children: .combine)
            VStack(spacing: 0) {
                if let top = layout.wordsTop { Color.clear.frame(height: top) } else { Spacer(minLength: 0) }
                stack
                if layout.wordsTop == nil { Color.clear.frame(height: layout.wordsBottom) } else { Spacer(minLength: 0) }
            }
            .frame(width: size.width, height: size.height)
            .offset(x: layout.axis - size.width / 2)
        }
    }

    private func line(_ wait: PlaybackWait, inline: Bool) -> Text {
        guard inline, let caption = caption(wait) else { return Text(wait.message) }
        return Text(wait.message) + Text("   ") + caption.font(Self.captionFont).foregroundStyle(.white.opacity(0.62))
    }

    /// The second line: a note on a switch the player made, or the way to another line, shown with the button's symbol.
    private func caption(_ wait: PlaybackWait) -> Text? {
        if let caption = wait.caption { return Text(caption) }
        guard wait.suggestsLines else { return nil }
        return Text(L10n.text("Another line may be faster:")) + Text(" ") + Text(Image(systemName: "ellipsis.circle")) + Text(" › " + L10n.text("Episodes"))
    }

    #if os(tvOS)
    private static let pillFont = Font.callout.weight(.medium)
    private static let captionFont = Font.caption
    private static let pillPadding: CGFloat = 16
    private static let captionWidth: CGFloat = 900
    /// Clears the transport bar, which tvOS shows by itself while a video loads (its scrubber sits about 175 pt up).
    private static let bottomGap: CGFloat = 250
    private static let wordsHeight: CGFloat = 175
    #elseif os(macOS)
    private static let pillFont = Font.callout.weight(.medium)
    private static let captionFont = Font.footnote
    private static let pillPadding: CGFloat = 10
    private static let captionWidth: CGFloat = 520
    private static let bottomGap: CGFloat = 96
    private static let wordsHeight: CGFloat = 115
    #else
    private static let pillFont = Font.subheadline.weight(.medium)
    private static let captionFont = Font.footnote
    private static let pillPadding: CGFloat = 11
    private static let captionWidth: CGFloat = 520
    #endif
}

/// A wait's small print, under its words or spinner: how the download goes, then the last steps, the newest brightest.
struct WaitDetails: View {
    var detail: String?
    var steps: [String] = []
    var body: some View {
        VStack(spacing: 3) {
            if let detail { Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75)) }
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text(step).font(.caption2).foregroundStyle(.white.opacity(index == steps.count - 1 ? 0.55 : 0.35))
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.45), radius: 6)
    }
}

/// A soft band of warm light that crosses the artwork every few seconds, as if the picture were developing.
private struct LightSweep: View {
    private static let light = Color(red: 1, green: 0.93, blue: 0.83)
    var body: some View {
        GeometryReader { proxy in
            // 30 frames a second is plenty for a slow band of light, and half the work of the display rate.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let period = 2.9, travel = 2.2
                let phase = min(1, timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / travel)
                let eased = phase * phase * (3 - 2 * phase)
                let band = max(120, proxy.size.width * 0.4)
                LinearGradient(stops: [.init(color: Self.light.opacity(0), location: 0), .init(color: Self.light.opacity(0.17), location: 0.5),
                                       .init(color: Self.light.opacity(0), location: 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: band, height: proxy.size.height * 1.9)
                    .rotationEffect(.degrees(16))
                    .position(x: -band + (proxy.size.width + band * 2) * eased, y: proxy.size.height / 2)
                    .blendMode(.screen)
            }
        }
        .allowsHitTesting(false)
    }
}
