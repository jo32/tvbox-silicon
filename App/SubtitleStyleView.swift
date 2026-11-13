import SwiftUI
import TVCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Settings › Subtitle Style (#547): a picture with a sample subtitle on it, and the choices beside it, like a
/// presentation app's text panel. On iPhone, iPad and the Mac the subtitle is dragged where it should sit; on Apple TV
/// it is moved with the remote over a full-screen picture. Every change is saved at once and the player picks it up
/// (`SubtitleStyle.changed`).
struct SubtitleStyleView: View {
    @State private var style = SubtitleStyle.load()
    /// How late subtitles show (#599), saved as the slider moves.
    @State private var delay = SubtitleDelay.load()
    /// While a drag or a slider is moving, the style is saved once, when it stops.
    @State private var adjusting = false

    var body: some View {
        page
            .onChange(of: style) { _, new in if !adjusting { new.save() } }
            .onChange(of: adjusting) { _, now in if !now { style.save() } }
            .onChange(of: delay) { _, new in SubtitleDelay.save(new) }
            // The player's menu steps the delay too (the Mac shows Settings beside the player).
            .onReceive(NotificationCenter.default.publisher(for: SubtitleDelay.changed)) { _ in delay = SubtitleDelay.load() }
    }

    @ViewBuilder private var page: some View {
        #if os(tvOS)
        TVSubtitleStylePage(style: $style, delay: $delay)
        #else
        FormSubtitleStylePage(style: $style, adjusting: $adjusting, delay: $delay)
        #endif
    }
}

/// The positions one choice puts a subtitle back to, centred across.
enum SubtitleSpot: CaseIterable, Hashable {
    case top, middle, bottom
    var y: Double {
        switch self {
        case .top: SubtitleStyle.top
        case .middle: SubtitleStyle.middle
        case .bottom: SubtitleStyle.bottom
        }
    }
    var title: String {
        switch self {
        case .top: L10n.text("Top")
        case .middle: L10n.text("Middle")
        case .bottom: L10n.text("Bottom")
        }
    }
    /// The spot `style` sits at, or nil when it was moved somewhere else.
    static func of(_ style: SubtitleStyle) -> SubtitleSpot? {
        allCases.first { abs(style.x - 0.5) < 0.001 && abs(style.y - $0.y) < 0.001 }
    }
}

extension SubtitleStyle {
    var positionTitle: String { SubtitleSpot.of(self)?.title ?? L10n.text("Custom") }
    /// The size as a share of the standard one: 100% is the standard size.
    var sizeTitle: String { (size / SubtitleStyle().size).formatted(.percent.precision(.fractionLength(0))) }
    /// Moved by `dx` and `dy` (fractions of the picture) and kept on the picture. A drag `snaps` to the centre line
    /// when it comes close; the remote's steps land on it by themselves.
    func moved(dx: Double, dy: Double, from start: SubtitleStyle, snaps: Bool = true) -> SubtitleStyle {
        var moved = self
        moved.x = start.x + dx
        moved.y = start.y + dy
        if snaps, abs(moved.x - 0.5) < 0.025 { moved.x = 0.5 }
        if !snaps { moved.x = (moved.x * 1000).rounded() / 1000; moved.y = (moved.y * 1000).rounded() / 1000 }
        return moved.clamped
    }
}

/// The font families a subtitle can use: the ones on this list installed on the device, which AVPlayer's subtitle
/// renderer finds too. Letters a family lacks (Chinese in a Latin font) come from the system's font.
enum SubtitleFonts {
    private static let candidates = [
        "PingFang SC", "PingFang TC", "Songti SC", "Kaiti SC", "Hiragino Sans", "Helvetica Neue", "Avenir Next",
        "Futura", "Gill Sans", "Optima", "Georgia", "Baskerville", "Times New Roman", "American Typewriter",
        "Menlo", "Courier New", "Marker Felt", "Noteworthy", "Chalkboard SE",
    ]
    static let installed: [String] = {
        #if canImport(UIKit)
        let families = Set(UIFont.familyNames)
        #else
        let families = Set(NSFontManager.shared.availableFontFamilies)
        #endif
        return candidates.filter(families.contains)
    }()
    /// The system's font first, as nil.
    static var choices: [String?] { [nil] + installed.map(Optional.some) }
    static func title(_ family: String?) -> String { family ?? L10n.text("System") }
}

/// A still of a film with the sample subtitle on it, drawn and placed as the player draws a subtitle in `style`
/// (`SubtitleLines`, `subtitlePlacement`).
struct SubtitlePreview: View {
    @Binding var style: SubtitleStyle
    /// Drags the subtitle (iPhone, iPad and Mac); `adjusting` is true while a finger or the pointer holds it.
    var draggable = false
    var adjusting: Binding<Bool> = .constant(false)
    /// The title-safe frame and the centre line, while the subtitle is being moved.
    var guides = false
    var cornerRadius: CGFloat = 12
    @State private var start: SubtitleStyle?

    private static let picture = "subtitlePreview.picture"
    static var sample: [String] { [L10n.text("This is how subtitles will look"), L10n.text("on every video you play")] }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let shown = style.clamped
            let moving = guides || start != nil
            ZStack(alignment: .topLeading) {
                SubtitleScene()
                if moving {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .padding(.horizontal, size.width * 0.05).padding(.vertical, size.height * 0.05)
                    if shown.x == 0.5 {
                        Rectangle().fill(Brand.amber).frame(width: 1.5, height: size.height).offset(x: size.width / 2 - 0.75)
                    }
                }
                SubtitleLines(lines: Self.sample, style: shown, letters: size.height * shown.size / 100, oneLine: true)
                    .contentShape(Rectangle())
                    #if !os(tvOS)
                    .gesture(drag(in: size), including: draggable ? .all : .none)
                    #endif
                    .subtitlePlacement(shown, in: CGRect(origin: .zero, size: size))
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.picture))
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #if !os(tvOS)
        .sensoryFeedback(.alignment, trigger: style.x == 0.5) { _, centred in centred && start != nil }
        #endif
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("Subtitle Style"))
        .accessibilityValue(style.positionTitle)
    }

    #if !os(tvOS)
    /// Measured on the picture, which stays put. In the subtitle's own space (the default) every step it moved
    /// shifted the finger's position inside it back, so the drag came out short, then jumped: a jittery drag.
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.picture))
            .onChanged { value in
                if start == nil { start = style; adjusting.wrappedValue = true }
                guard let start, size.width > 0, size.height > 0 else { return }
                style = style.moved(dx: value.translation.width / size.width, dy: value.translation.height / size.height, from: start)
            }
            .onEnded { _ in start = nil; adjusting.wrappedValue = false }
    }
    #endif
}

/// A dusk sky over dark hills: bright and dark parts, so a subtitle can be judged over both.
struct SubtitleScene: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: [Color(red: 0.09, green: 0.12, blue: 0.3), Color(red: 0.5, green: 0.3, blue: 0.5),
                                        Color(red: 0.97, green: 0.6, blue: 0.38), Color(red: 1, green: 0.8, blue: 0.55)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color(red: 1, green: 0.93, blue: 0.75))
                    .frame(width: proxy.size.height * 0.2)
                    .position(x: proxy.size.width * 0.68, y: proxy.size.height * 0.6)
                Hills(top: 0.62, phase: 0.8).fill(Color(red: 0.24, green: 0.16, blue: 0.3))
                Hills(top: 0.74, phase: 2.6).fill(Color(red: 0.07, green: 0.06, blue: 0.13))
            }
        }
        .accessibilityHidden(true)
    }

    private struct Hills: Shape {
        let top: Double, phase: Double
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for step in 0...32 {
                let t = Double(step) / 32
                let height = top + 0.05 * sin(t * 9 + phase) + 0.025 * sin(t * 23 + phase * 2)
                path.addLine(to: CGPoint(x: rect.minX + rect.width * t, y: rect.minY + rect.height * height))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

#if !os(tvOS)
// MARK: iPhone, iPad and Mac

/// The preview pinned over a settings form: drag the subtitle on the picture, and pick the rest below it.
private struct FormSubtitleStylePage: View {
    @Binding var style: SubtitleStyle
    @Binding var adjusting: Bool
    @Binding var delay: Double

    var body: some View {
        Form {
            Group {
                Section {
                    Picker(L10n.text("Position"), selection: Binding(get: { SubtitleSpot.of(style) },
                                                                  set: { if let spot = $0 { style.x = 0.5; style.y = spot.y } })) {
                        ForEach(SubtitleSpot.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text(L10n.text("Position"))
                } footer: {
                    Text(L10n.text("Drag the subtitle on the picture to put it anywhere. It snaps to the center line."))
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent {
                            Text(style.sizeTitle).monospacedDigit().foregroundStyle(.secondary)
                        } label: {
                            FormLabel(symbol: "textformat.size", tint: .orange, title: L10n.text("Size"))
                        }
                        Slider(value: $style.size, in: SubtitleStyle.sizes) {
                            Text(L10n.text("Size"))
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller").accessibilityLabel(L10n.text("Smaller"))
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger").accessibilityLabel(L10n.text("Larger"))
                        } onEditingChanged: { adjusting = $0 }
                        .labelsHidden()
                    }
                    Picker(selection: $style.font) {
                        ForEach(SubtitleFonts.choices, id: \.self) { family in
                            Text(SubtitleFonts.title(family)).tag(family)
                        }
                    } label: {
                        FormLabel(symbol: "textformat", tint: .indigo, title: L10n.text("Font"))
                    }
                    LabeledContent {
                        HStack(spacing: 8) {
                            StyleButton(symbol: "bold", title: L10n.text("Bold"), isOn: $style.bold)
                            StyleButton(symbol: "italic", title: L10n.text("Italic"), isOn: $style.italic)
                        }
                    } label: {
                        FormLabel(symbol: "bold.italic.underline", tint: .pink, title: L10n.text("Style"))
                    }
                    LabeledContent {
                        HStack(spacing: 10) {
                            ForEach(SubtitleStyle.TextColor.allCases, id: \.self) { color in
                                ColorSwatch(color: color, selected: style.color == color) { style.color = color }
                            }
                        }
                    } label: {
                        FormLabel(symbol: "paintpalette.fill", tint: .purple, title: L10n.text("Color"))
                    }
                } header: {
                    Text(L10n.text("Text"))
                }
                Section {
                    Picker(selection: $style.edge) {
                        ForEach(SubtitleStyle.Edge.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        FormLabel(symbol: "shadow", tint: .gray, title: L10n.text("Shadow"))
                    }
                    Picker(selection: $style.backdrop) {
                        ForEach(SubtitleStyle.Backdrop.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        FormLabel(symbol: "rectangle.fill", tint: .gray, title: L10n.text("Background"))
                    }
                } header: {
                    Text(L10n.text("Effects"))
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent {
                            Text(SubtitleDelay.title(delay)).monospacedDigit().foregroundStyle(.secondary)
                        } label: {
                            FormLabel(symbol: "clock.arrow.circlepath", tint: .teal, title: L10n.text("Subtitle Delay"))
                        }
                        Slider(value: $delay, in: SubtitleDelay.range, step: SubtitleDelay.step) {
                            Text(L10n.text("Subtitle Delay"))
                        } minimumValueLabel: {
                            Image(systemName: "minus").accessibilityLabel(L10n.text("Smaller"))
                        } maximumValueLabel: {
                            Image(systemName: "plus").accessibilityLabel(L10n.text("Larger"))
                        }
                        .labelsHidden()
                    }
                    if delay != 0 {
                        Button(L10n.text("Reset")) { delay = 0 }
                            .formRowButton()
                    }
                } header: {
                    Text(L10n.text("Timing"))
                } footer: {
                    Text(L10n.text("Positive values show subtitles later. Applies to the video playing now."))
                }
                Section {
                    Button(L10n.text("Reset to Standard")) { style = SubtitleStyle() }
                        .formRowButton()
                        .disabled(style == SubtitleStyle())
                } footer: {
                    Text(L10n.text("Applies to subtitles in every video, including one that is playing."))
                }
            }
            .settingsRows()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SubtitlePreview(style: $style, draggable: true, adjusting: $adjusting)
                .frame(maxWidth: 560)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, Layout.gutter).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
        }
        .settingsForm(L10n.text("Subtitle Style"))
    }
}

/// A bold or italic switch drawn as a formatting button, like a word processor's.
private struct StyleButton: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 38, height: 30)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? AnyShapeStyle(systemAccent) : AnyShapeStyle(Color.primary.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct ColorSwatch: View {
    let color: SubtitleStyle.TextColor
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            let (red, green, blue) = color.rgb
            Circle().fill(Color(red: red, green: green, blue: blue))
                .frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                .padding(3)
                .overlay(Circle().strokeBorder(systemAccent, lineWidth: 2).opacity(selected ? 1 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif

#if os(tvOS)
// MARK: Apple TV

/// A large preview on the left and the choices on the right. Each row steps through its choices with a press, as
/// rows in the TV's own Settings do; Adjust Position moves the subtitle over a full-screen picture.
private struct TVSubtitleStylePage: View {
    @Binding var style: SubtitleStyle
    @Binding var delay: Double
    @State private var positioning = false
    private static let sizes: [Double] = [3.5, 4.25, 5, 6, 7, 8.5]

    var body: some View {
        HStack(alignment: .center, spacing: 72) {
            VStack(spacing: 30) {
                SubtitlePreview(style: $style, cornerRadius: 24)
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
                Text(L10n.text("Subtitle Style")).font(.system(size: 44, weight: .bold))
            }
            .frame(width: 860)
            .frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    TVSettingsSection(title: L10n.text("Position"),
                                      footer: L10n.text("Adjust Position shows the subtitle over the whole screen. Move it with the remote, then press Select.")) {
                        TVSettingsAction(title: L10n.text("Position"), value: style.positionTitle) {
                            let spots = SubtitleSpot.allCases
                            let next = SubtitleSpot.of(style).flatMap { spots.firstIndex(of: $0) }.map { spots[($0 + 1) % spots.count] } ?? .bottom
                            style.x = 0.5; style.y = next.y
                        }
                        TVSettingsAction(title: L10n.text("Adjust Position")) { positioning = true }
                    }
                    TVSettingsSection(title: L10n.text("Text")) {
                        TVSettingsAction(title: L10n.text("Size"), value: style.sizeTitle) {
                            style.size = Self.sizes.first { $0 > style.size + 0.01 } ?? Self.sizes[0]
                        }
                        TVSettingsLink(title: L10n.text("Font"), value: SubtitleFonts.title(style.font)) { TVSubtitleFontPage(style: $style) }
                        TVSettingsToggle(title: L10n.text("Bold"), isOn: $style.bold)
                        TVSettingsToggle(title: L10n.text("Italic"), isOn: $style.italic)
                        TVSettingsAction(title: L10n.text("Color"), value: style.color.title) { style.color = Self.next(style.color) }
                    }
                    TVSettingsSection(title: L10n.text("Effects"),
                                      footer: L10n.text("Applies to subtitles in every video, including one that is playing.")) {
                        TVSettingsAction(title: L10n.text("Shadow"), value: style.edge.title) { style.edge = Self.next(style.edge) }
                        TVSettingsAction(title: L10n.text("Background"), value: style.backdrop.title) { style.backdrop = Self.next(style.backdrop) }
                    }
                    TVSettingsSection(title: L10n.text("Timing"),
                                      footer: L10n.text("Positive values show subtitles later. Applies to the video playing now.")) {
                        TVSettingsAction(title: L10n.text("Subtitle Delay"), value: SubtitleDelay.title(delay)) {
                            delay = delay >= SubtitleDelay.range.upperBound ? 0 : min(delay + SubtitleDelay.step, SubtitleDelay.range.upperBound)
                        }
                    }
                    TVSettingsSection {
                        TVSettingsAction(title: L10n.text("Reset to Standard")) { style = SubtitleStyle() }
                            .disabled(style == SubtitleStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassRowInsets()
                .padding(.vertical, 40)
            }
            .scrollClipDisabled()
            .tvFocusSection()
        }
        .padding(.horizontal, Layout.gutter)
        .screenBackdrop()
        .screenTitle("")
        .fullScreenCover(isPresented: $positioning) { TVSubtitlePositioner(style: $style) }
    }

    private static func next<Choice: CaseIterable & Equatable>(_ choice: Choice) -> Choice where Choice.AllCases == [Choice] {
        let all = Choice.allCases
        return all[((all.firstIndex(of: choice) ?? 0) + 1) % all.count]
    }
}

/// The subtitle over the whole screen, at the size it plays: each press of an arrow (or swipe) moves it a step,
/// Select or Menu puts it down. The picture is the only thing that can be focused, so the arrows can't leave it.
private struct TVSubtitlePositioner: View {
    @Binding var style: SubtitleStyle
    @Environment(\.dismiss) private var dismiss
    private let step = 0.02

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            SubtitlePreview(style: $style, guides: true, cornerRadius: 0)
            Label(L10n.text("Swipe or press the arrows to move the subtitle. Press Select when it's in place."),
                  systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 26, weight: .medium))
                .padding(.horizontal, 28).padding(.vertical, 14)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 60)
            // The one focusable thing on screen: it takes the arrows, and Select puts the subtitle down.
            Button { dismiss() } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                .buttonStyle(BareButtonStyle())
                .onMoveCommand { direction in
                    switch direction {
                    case .up: style = style.moved(dx: 0, dy: -step, from: style, snaps: false)
                    case .down: style = style.moved(dx: 0, dy: step, from: style, snaps: false)
                    case .left: style = style.moved(dx: -step, dy: 0, from: style, snaps: false)
                    case .right: style = style.moved(dx: step, dy: 0, from: style, snaps: false)
                    @unknown default: break
                    }
                }
                .accessibilityLabel(L10n.text("Adjust Position"))
        }
        .ignoresSafeArea()
    }

    private struct BareButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
}

/// The fonts installed on the TV, the chosen one ticked.
private struct TVSubtitleFontPage: View {
    @Binding var style: SubtitleStyle
    var body: some View {
        TVSettingsSubpage(symbol: "textformat", title: L10n.text("Font")) {
            TVSettingsSection {
                ForEach(SubtitleFonts.choices, id: \.self) { family in
                    Button { style.font = family } label: {
                        TVSettingsRowLabel(title: SubtitleFonts.title(family)) {
                            if style.font == family { Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold)) }
                        }
                    }
                    .glassRow()
                }
            }
        }
    }
}
#endif
