#if os(macOS)
import SwiftUI
import ColorfulX

/// The detail page's backdrop: the cover's colours drifting slowly behind the page, like the Apple TV and Music
/// apps' aurora. It starts as the flat backdrop and fades the colours in once the cover is read, from the posters'
/// cache, so a cover already on screen costs no download. Mac only: on iPhone, iPad and Apple TV it looked worse
/// than the flat backdrop.
struct DetailAurora: View {
    let poster: URL?
    var headers: [String: String] = [:]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var colors: [Color] = []
    var body: some View {
        ZStack {
            Backdrop()
            if !colors.isEmpty {
                // A soft gradient needs few pixels and no more than 30 frames a second.
                ColorfulView(color: colors, speed: .constant(reduceMotion ? 0 : 0.5), transitionSpeed: .constant(2),
                             frameLimit: .constant(30), renderScale: .constant(0.3))
                    .opacity(scheme == .dark ? 0.6 : 0.4)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: poster) {
            guard let poster else { return }
            let found = await PosterPalette.colors(poster, headers: headers)
            withAnimation(.easeInOut(duration: 0.8)) { colors = found }
        }
    }
}
#endif
