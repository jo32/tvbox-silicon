import SwiftUI
import TVCore

/// Covers the app's content while it is in the background, so the thumbnail iOS keeps in the app
/// switcher cannot show a frame of a film, a poster, or a hidden list.
///
/// The system takes its snapshot the moment the app leaves the foreground, which is earlier than
/// most apps react. Two things make this reliable:
///
/// * The shade is part of the view tree from launch and only changes its opacity, so nothing has to
///   be built while the app is being backgrounded — a view that appears at that moment is usually
///   too late to be in the snapshot.
/// * It sits above everything, including sheets and the player, because the snapshot is of the whole
///   window.
///
/// One (`com.ios151.one`) does the same thing with `backgroundBlur` and `_privacyMode`, and keeps
/// `previousKey` so the picture comes back rather than restarting. Nothing here restarts anything:
/// it only hides.
struct PrivacyShade: ViewModifier {
    /// Whether to cover at all. A person who does not care about the app switcher can turn it off.
    var enabled: Bool = true
    @Environment(\.scenePhase) private var scenePhase
    /// Held separately from `scenePhase` so the shade can fade in over the interval the system
    /// takes to snapshot, rather than snapping.
    @State private var covered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled {
                    // A flat colour, not a blur: a blurred snapshot is still a readable one, and a
                    // blur costs a render pass at the worst possible moment.
                    shadeColor
                        .ignoresSafeArea()
                        .opacity(covered ? 1 : 0)
                        .allowsHitTesting(covered)
                        // The app's name, so a person returning knows which app this is, and nothing
                        // about what was on screen.
                        .overlay {
                            if covered {
                                VStack(spacing: 10) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 34, weight: .light))
                                    Text(L10n.text("Locked"))
                                        .font(.footnote)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .animation(.easeOut(duration: 0.12), value: covered)
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Cover on anything that is not active: inactive is the state during the app
                // switcher and during a call banner, which is exactly when the snapshot is taken.
                covered = enabled && phase != .active
            }
    }

    /// The cover's colour. tvOS has no `systemBackground` and is dark only, so it is flat black there.
    private var shadeColor: Color {
        #if os(tvOS)
        Color.black
        #else
        Color(.systemBackground)
        #endif
    }
}

extension View {
    /// Hides the window's content from the app switcher.
    func privacyShade(enabled: Bool = true) -> some View {
        modifier(PrivacyShade(enabled: enabled))
    }
}
