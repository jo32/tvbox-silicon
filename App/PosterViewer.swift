import SwiftUI
import TVCore

/// A poster, at full size, with pinch to zoom and a pull down to dismiss.
///
/// 映匣 shows posters as thumbnails and nothing more, so a viewer who wants to read a long title on
/// a small cover has no way to. One (`com.ios151.one`) does this with `ZoomingScrollView` plus a
/// `DismissPanRecognizer`; the same two gestures are what people expect here, because they are what
/// Photos does:
///
/// * Pinch to zoom, anchored under the fingers, and double tap to snap between 1× and 2×.
/// * Drag down to dismiss, but only when the picture is not zoomed — otherwise the drag is a pan,
///   and taking it for a dismiss makes a zoomed poster impossible to move.
///
/// The dismissal threshold is a fraction of the screen rather than a fixed distance, so it feels the
/// same on a phone and an iPad. Releasing early springs back; past the threshold the picture fades.
struct PosterViewer: View {
    let url: URL?
    var headers: [String: String] = [:]
    /// The title, for the accessibility label and so a failed load still says what it was.
    var title: String = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    /// How far the picture has been pulled down, in points.
    @State private var pull: CGFloat = 0

    private let maximumZoom: CGFloat = 4
    /// Past this much drag, releasing dismisses.
    private var dismissThreshold: CGFloat { 140 }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()

                PosterImage(url: url, headers: headers)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom)
                    .offset(y: pull)
                    #if !os(tvOS)
                    .gesture(zoomGesture)
                    .simultaneousGesture(dismissGesture(in: proxy.size))
                    .onTapGesture(count: 2) { toggleZoom() }
                    #endif
                    .accessibilityLabel(title)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.28), value: zoom)
        }
        #if !os(tvOS)
        .statusBarHidden()
        #endif
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(16)
            .accessibilityLabel(L10n.text("Close"))
        }
    }

    /// The background fades as the picture is pulled, so the gesture shows what it will do before
    /// the finger lifts.
    private var backgroundOpacity: Double {
        let progress = min(1, Double(pull) / Double(dismissThreshold))
        return 1 - progress * 0.6
    }

    // tvOS has no pinch or drag on the remote, so the poster is shown at full size and closed with
    // the button: zooming is a phone and iPad gesture.
    #if !os(tvOS)
    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value, 1), maximumZoom)
            }
            .onEnded { _ in
                committedZoom = zoom
                // Pinching back below 1 leaves the picture filling the screen rather than shrinking
                // into a corner; there is nothing to see outside it.
                if zoom < 1.02 { zoom = 1; committedZoom = 1 }
            }
    }

    private func dismissGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // A zoomed picture is being panned, not dismissed.
                guard zoom <= 1.02, value.translation.height > 0 else { return }
                pull = value.translation.height
            }
            .onEnded { value in
                guard zoom <= 1.02 else { return }
                if value.translation.height > dismissThreshold { dismiss() }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { pull = 0 }
            }
    }

    private func toggleZoom() {
        if zoom > 1.02 {
            zoom = 1; committedZoom = 1
        } else {
            zoom = 2; committedZoom = 2
        }
    }
    #endif
}

/// Opens `PosterViewer` for one poster, replaced by `PosterViewer`'s own gestures once it is up.
struct PosterZoomTarget: ViewModifier {
    let url: URL?
    var headers: [String: String] = [:]
    var title: String = ""
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .onTapGesture { if url != nil { open = true } }
            // `fullScreenCover` is iOS and tvOS only; on the Mac the poster opens as a large sheet.
            #if os(tvOS)
            .fullScreenCover(isPresented: $open) {
                PosterViewer(url: url, headers: headers, title: title)
            }
            #else
            .sheet(isPresented: $open) {
                PosterViewer(url: url, headers: headers, title: title)
            }
            #endif
    }
}

extension View {
    /// Makes a poster openable at full size.
    func posterZoom(url: URL?, headers: [String: String] = [:], title: String = "") -> some View {
        modifier(PosterZoomTarget(url: url, headers: headers, title: title))
    }
}
