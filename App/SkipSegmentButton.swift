import SwiftUI
import TVCore

/// The floating "skip intro" button.
///
/// Rex uses a floating button (`PlayerUIKit25PlayerSkipFloatButtonView`) rather than a dialog, and
/// that choice is the whole design: an intro is usually fifteen seconds long, and a sheet that has to
/// be dismissed takes longer to deal with than the intro itself. A button sits over the picture,
/// does one thing when tapped, and disappears on its own when the segment ends.
///
/// Three behaviours are worth stating:
///
/// * It only appears inside the segment, and goes away the moment the playhead leaves it — including
///   when the viewer seeks past it.
/// * It counts down, because "skip intro" that is about to vanish is more useful than one that does
///   not say so.
/// * It is never automatic unless the source is file-level. A public database's timings describe a
///   different cut, so jumping on its word would move the playhead to a wrong place with no undo.
struct SkipSegmentButton: View {
    let segment: SkipSegmentSources.Segment
    /// Current playhead, in seconds.
    let position: Double
    /// Whether this segment came from a source that knows this exact file.
    let isFileLevel: Bool
    var onSkip: () -> Void

    /// Only shown in the last stretch of the segment; before that the viewer is watching the intro.
    private var remaining: Double { max(0, segment.end - position) }
    private var shows: Bool { position >= segment.start && position < segment.end }

    var body: some View {
        if shows {
            Button(action: onSkip) {
                HStack(spacing: 7) {
                    Image(systemName: "forward.end.fill").font(.caption)
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.62), in: Capsule())
                .foregroundStyle(.white)
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            .animation(.easeOut(duration: 0.18), value: shows)
            .accessibilityLabel(title)
        }
    }

    private var title: String {
        let kind = segment.kind == .credits ? L10n.text("Skip Credits") : L10n.text("Skip Intro")
        // Count down only when the segment is short enough that the number is meaningful.
        guard remaining <= 20 else { return kind }
        return "\(kind) · \(Int(remaining.rounded(.up)))s"
    }
}
