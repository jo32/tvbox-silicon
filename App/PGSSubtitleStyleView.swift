import SwiftUI
import TVCore

struct PGSSubtitleStyleView: View {
    @State private var style = PGSSubtitleStyle.load()
    #if os(tvOS)
    @State private var positioning = false
    #endif
    private var sizeTitle: String { style.scale.formatted(.percent.precision(.fractionLength(0))) }

    var body: some View {
        page.onChange(of: style) { _, style in style.save() }
    }

    @ViewBuilder private var page: some View {
        #if os(tvOS)
        TVSettingsSubpage(title: L10n.text("PGS Bitmap Subtitles")) {
            PGSSubtitlePreview(style: $style)
        } content: {
            TVSettingsSection {
                TVSettingsAction(title: L10n.text("Size"), value: sizeTitle) {
                    let next = style.scale + 0.25
                    style.scale = next <= PGSSubtitleStyle.scales.upperBound ? next : PGSSubtitleStyle.scales.lowerBound
                }
                TVSettingsAction(title: L10n.text("Adjust Position"), value: positionTitle) { positioning = true }
                TVSettingsAction(title: L10n.text("Use Source Position")) { style.position = nil }
                    .disabled(style.position == nil)
                SettingsActionRow(title: L10n.text("Reset to Standard")) { style = PGSSubtitleStyle() }
                    .disabled(style == PGSSubtitleStyle())
            }
        }
        .fullScreenCover(isPresented: $positioning) {
            TVSubtitlePositioner {
                PGSSubtitlePreview(style: $style)
            } move: { dx, dy in
                let picture = CGRect(origin: .zero, size: PGSSubtitlePreview.sample.size)
                style.position = PGSSubtitlePreview.movedCenter(style, in: picture, dx: dx, dy: dy)
            }
        }
        #else
        Form {
            Section {
                LabeledContent(L10n.text("Size")) { Text(sizeTitle).monospacedDigit() }
                Slider(value: $style.scale, in: PGSSubtitleStyle.scales, step: 0.05) { Text(L10n.text("Size")) }
                LabeledContent(L10n.text("Position")) {
                    Menu(positionTitle) {
                        Button(L10n.text("Source Position")) { style.position = nil }
                        ForEach(SubtitleSpot.allCases, id: \.self) { spot in
                            Button(spot.title) { style.position = CGPoint(x: 0.5, y: spot.y) }
                        }
                    }
                }
                SettingsActionRow(title: L10n.text("Reset to Standard")) { style = PGSSubtitleStyle() }
                    .disabled(style == PGSSubtitleStyle())
            } footer: {
                Text(L10n.text("Drag the bilingual subtitle in the preview to move both lines."))
            }
            .settingsRows()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            PGSSubtitlePreview(style: $style)
                .frame(maxWidth: 560)
                .padding(.horizontal, Layout.gutter).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .settingsForm(L10n.text("PGS Bitmap Subtitles"))
        #endif
    }

    private var positionTitle: String {
        guard let point = style.position else { return L10n.text("Source Position") }
        return SubtitleSpot.allCases.first { point == CGPoint(x: 0.5, y: $0.y) }?.title ?? L10n.text("Custom")
    }
}

/// A single raster cue with two authored lines, placed by the same view as a decoded PGS cue.
struct PGSSubtitlePreview: View {
    @Binding var style: PGSSubtitleStyle
    @GestureState private var translation: CGSize = .zero

    static let sample: StyledSubtitleFrame = {
        let canvas = CGSize(width: 1280, height: 720)
        let image = ImageRenderer(content: BilingualSample()).cgImage
        let size = CGSize(width: image?.width ?? 0, height: image?.height ?? 0)
        let rect = CGRect(x: (canvas.width - size.width) / 2, y: canvas.height * 0.94 - size.height,
                          width: size.width, height: size.height)
        return StyledSubtitleFrame(image: image, rect: rect, size: canvas, fitsCanvas: true)
    }()

    private struct BilingualSample: View {
        var body: some View {
            VStack(spacing: 2) {
                Text(verbatim: "我们快到了。").font(.system(size: 46, weight: .semibold))
                Text(verbatim: "We're almost there.").font(.system(size: 32).italic())
            }
            .fixedSize().foregroundStyle(.white).shadow(color: .black, radius: 2).padding(4)
        }
    }

    /// Start at the displayed centre, including when the size limit has pulled a cue away from an edge.
    static func movedCenter(_ style: PGSSubtitleStyle, in picture: CGRect, dx: Double, dy: Double) -> CGPoint {
        let rect = style.imageRect(for: sample, in: picture, visible: picture)
        let x = (rect.midX - picture.minX) / picture.width + dx
        let y = (rect.midY - picture.minY) / picture.height + dy
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let picture = CGRect(origin: .zero, size: proxy.size)
            ZStack {
                SubtitleScene()
                PGSSubtitleImage(frame: Self.sample, style: moved(by: translation, in: picture), picture: picture, visible: picture)
            }
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture().updating($translation) { value, translation, _ in
                translation = value.translation
            }.onEnded { value in
                style = moved(by: value.translation, in: picture)
            })
            #endif
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("PGS Bitmap Subtitles"))
    }

    private func moved(by translation: CGSize, in picture: CGRect) -> PGSSubtitleStyle {
        guard translation != .zero, !picture.isEmpty else { return style }
        var moved = style
        moved.position = Self.movedCenter(style, in: picture, dx: translation.width / picture.width, dy: translation.height / picture.height)
        return moved
    }
}
