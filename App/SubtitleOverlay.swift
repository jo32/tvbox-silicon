import SwiftUI
import TVCore
#if canImport(UIKit)
import UIKit
#endif

/// Draws the current subtitle over the picture, where the viewer may drag it and resize it.
///
/// 映匣 lets `AVPlayer` draw subtitles, which pins them to the bottom centre at a size the system
/// chooses. This view replaces that for the tracks the app parses itself: the same text, positioned
/// and sized by `SubtitleStyle`, draggable, and remembered per video by `SubtitlePositionMemory`.
///
/// It is deliberately a plain overlay rather than a player modification: the picture stays an
/// `AVPlayerLayer`, so Picture in Picture and the platform's own video pipeline keep working. When
/// this view has nothing to show, it draws nothing at all — no clear layer over the video, so a film
/// without subtitles is untouched.
///
/// One caveat worth stating: while this overlay shows a parsed track, the player's own rendering of
/// its selected legible track must be turned off, or both appear. That switch lives with the caller
/// (`MobilePlayer`), because only it knows which tracks it handed to the player.
struct SubtitleOverlay: View {
    let track: SubtitleTrack?
    /// The time on screen, in seconds.
    let position: Double
    @Binding var style: SubtitleStyle
    /// Where to remember a dragged position; nil keeps it for this session only.
    var positionKey: String?
    @Binding var memory: SubtitlePositionMemory
    /// Whether the controls are showing, so the bubble can step out of their way.
    var controlsVisible: Bool = false

    @State private var drag: CGSize = .zero

    private var cue: SubtitleTrack.Cue? {
        guard style.enabled else { return nil }
        return track?.cue(atSeconds: position)
    }

    var body: some View {
        GeometryReader { proxy in
            if let cue {
                bubble(cue, in: proxy.size)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: cue.text)
            }
        }
        .allowsHitTesting(cue != nil)
        .accessibilityHidden(cue == nil)
    }

    private func bubble(_ cue: SubtitleTrack.Cue, in size: CGSize) -> some View {
        // While the controls are up the scrubber occupies the lower band, so the bubble lifts out of
        // it rather than sitting under the finger.
        let lift = controlsVisible ? -0.10 : 0
        let x = min(max(style.centerX, 0.08), 0.92) * size.width + drag.width
        let y = min(max(style.centerY + lift, 0.10), 0.94) * size.height + drag.height
        return Text(cue.text)
            .font(.system(size: style.fontSize, weight: .semibold))
            .foregroundStyle(.white.opacity(style.textOpacity))
            .multilineTextAlignment(.center)
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
            .background {
                if style.backgroundOpacity > 0 {
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                        .fill(.black.opacity(style.backgroundOpacity))
                }
            }
            // A shadow under the text, so it reads over a bright frame even with the plate off.
            .shadow(color: .black.opacity(style.textOpacity * 0.55), radius: 3, y: 1)
            .frame(maxWidth: size.width * 0.92)
            .position(x: x, y: y)
            #if !os(tvOS)
            .gesture(
                DragGesture()
                    .onChanged { value in drag = value.translation }
                    .onEnded { value in
                        settle(value, in: size)
                    }
            )
            #endif
            .accessibilityLabel(cue.text)
    }

    /// Turns a finished drag into a stored position, clamped so the bubble cannot be thrown off
    /// screen, then clears the in-flight offset so the next frame reads from the stored value.
    /// tvOS has no drag gesture, so a subtitle there stays where the style puts it.
    #if !os(tvOS)
    private func settle(_ value: DragGesture.Value, in size: CGSize) {
        let settledX = min(max(style.centerX, 0.08), 0.92) + value.translation.width / max(size.width, 1)
        let settledY = min(max(style.centerY, 0.10), 0.94) + value.translation.height / max(size.height, 1)
        let clamped = style.clampedCenter(x: settledX, y: settledY)
        style.centerX = clamped.x
        style.centerY = clamped.y
        memory.store(CGPoint(x: clamped.x, y: clamped.y), for: positionKey)
        drag = .zero
    }
    #endif
}

/// The subtitle controls: size, both opacities, on/off, and a way back to the defaults.
///
/// Sliders rather than a stepper for size, because a person judges caption size by looking, not by
/// counting points. Each slider shows its own value so a change is legible while dragging.
struct SubtitleSettingsView: View {
    @Binding var style: SubtitleStyle
    @Binding var memory: SubtitlePositionMemory
    /// The video whose position this page edits, so "reset position" affects only this title.
    var positionKey: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $style.enabled) {
                    FormLabel(symbol: "captions.bubble.fill", tint: .teal, title: L10n.text("Show Subtitles"))
                }
                .settingsSwitch()
            } footer: {
                Text(L10n.text("Applies to subtitle files the source provides. A track built into the stream keeps the player's own styling."))
            }

            Section {
                slider(L10n.text("Text Size"), value: $style.fontSize,
                       range: SubtitleStyle.fontSizeRange, format: "%.0f",
                       symbol: "textformat.size")
                slider(L10n.text("Text Opacity"), value: $style.textOpacity,
                       range: 0...1, format: "%.0f%%", scaled: true,
                       symbol: "circle.lefthalf.filled")
                slider(L10n.text("Background"), value: $style.backgroundOpacity,
                       range: 0...1, format: "%.0f%%", scaled: true,
                       symbol: "rectangle.fill")
            } header: {
                Text(L10n.text("Appearance"))
            }

            Section {
                LabeledContent {
                    Text(style.isModified ? L10n.text("Changed") : L10n.text("Default"))
                        .foregroundStyle(.secondary)
                } label: {
                    FormLabel(symbol: "slider.horizontal.3", tint: .gray, title: L10n.text("Position"))
                }
                Button(L10n.text("Reset Position")) {
                    let fallback = CGPoint(x: SubtitleStyle.standard.centerX, y: SubtitleStyle.standard.centerY)
                    style.centerX = fallback.x
                    style.centerY = fallback.y
                    memory.store(fallback, for: positionKey)
                }
                Button(L10n.text("Reset Size and Transparency")) {
                    style = style.resettingAppearance()
                }
            } footer: {
                Text(L10n.text("Drag the subtitle over the picture to move it; it is remembered for this video."))
            }
        }
        .navigationTitle(L10n.text("Subtitles"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, format: String,
                        scaled: Bool = false, symbol: String) -> some View {
        // On the TV one press moves a twentieth of the range, so a value is reachable in a few clicks.
        #if os(tvOS)
        let step = (range.upperBound - range.lowerBound) / 20
        #endif
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                FormLabel(symbol: symbol, tint: .teal, title: title)
                Spacer(minLength: 8)
                Text(scaled ? String(format: format, value.wrappedValue * 100)
                            : String(format: format, value.wrappedValue))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            #if os(tvOS)
            // A TV remote cannot drag a slider; two presses move it instead.
            HStack(spacing: 20) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: {
                    Image(systemName: "minus.circle.fill")
                }
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: {
                    Image(systemName: "plus.circle.fill")
                }
            }
            .font(.title3)
            #else
            Slider(value: value, in: range)
            #endif
        }
        .padding(.vertical, 2)
    }
}

/// Offers the stream to another app, for when the built-in player cannot open the format.
///
/// The menu lists only players that are actually installed — a row that does nothing is worse than
/// no row, because it teaches the viewer that the menu cannot be trusted. Copying the address is
/// always offered, since it is the one action that works with nothing installed.
#if !os(macOS)
struct ExternalPlayerMenu: View {
    let stream: URL
    let headers: [String: String]
    @Environment(\.dismiss) private var dismiss
    @State private var installed: [ExternalPlayer] = []
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(installed) { player in
                        Button {
                            if player.open(stream) { dismiss() }
                        } label: {
                            FormLabel(symbol: "play.rectangle.fill", tint: .indigo, title: player.name)
                        }
                    }
                    // tvOS has no clipboard to copy an address into.
                    #if !os(tvOS)
                    Button {
                        UIPasteboard.general.string = stream.absoluteString
                        copied = true
                    } label: {
                        FormLabel(symbol: copied ? "checkmark.circle.fill" : "doc.on.doc.fill",
                                  tint: copied ? .green : .gray,
                                  title: copied ? L10n.text("Address Copied") : L10n.text("Copy Address"))
                    }
                    #endif
                } header: {
                    Text(L10n.text("Installed Players"))
                } footer: {
                    Text(L10n.text("Some formats the built-in player cannot decode. Handing the address to another app plays it."))
                }

                // The players that are not installed, named so the viewer knows what would work
                // rather than being told nothing.
                let missing = ExternalPlayer.known.filter { candidate in
                    !installed.contains { $0.scheme == candidate.scheme }
                }
                if !missing.isEmpty {
                    Section {
                        ForEach(missing) { player in
                            HStack {
                                Text(player.name).foregroundStyle(.secondary)
                                Spacer()
                                Text(L10n.text("Not Installed")).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    } footer: {
                        Text(L10n.text("Install one of these to open formats the built-in player cannot."))
                    }
                }

                if !headers.isEmpty {
                    Section {
                        Text(L10n.text("This stream needs headers, which another app cannot receive. Copy the address and add them there."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.text("Open in Another Player"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Cancel")) { dismiss() }
                }
            }
            .task { installed = ExternalPlayer.installed() }
        }
    }
}

#endif
