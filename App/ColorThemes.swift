import Observation
import SwiftUI
import TVCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Color themes
// Settings › Color Theme. A theme sets the app's own colours (Brand.accent and Brand.onAccent, the page canvas, the panels
// on it and Apple TV's surfaces); artwork, the decorative colours (Brand.cyan…) and the system's accent stay as they are.
// Classic is the app's original look, navy canvases with a neutral highlight. Custom is made from two colours the viewer
// picks (iPhone, iPad and Mac; Apple TV has no colour picker).

/// A colour theme the app ships with.
enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    case classic = "Classic", violet = "Violet", ocean = "Ocean", lagoon = "Lagoon", forest = "Forest", amber = "Amber"
    case sunset = "Sunset", rose = "Rose", crimson = "Crimson", orchid = "Orchid", graphite = "Graphite", custom = "Custom"

    static let standard = ColorTheme.classic
    /// The themes the picker offers here.
    static var choices: [ColorTheme] {
        #if os(tvOS)
        allCases.filter { $0 != .custom }
        #else
        allCases
        #endif
    }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: L10n.text("Classic")
        case .violet: L10n.text("Violet")
        case .ocean: L10n.text("Ocean")
        case .lagoon: L10n.text("Lagoon")
        case .forest: L10n.text("Forest")
        case .amber: L10n.text("Amber")
        case .sunset: L10n.text("Sunset")
        case .rose: L10n.text("Rose")
        case .crimson: L10n.text("Crimson")
        case .orchid: L10n.text("Orchid")
        case .graphite: L10n.text("Graphite")
        case .custom: L10n.text("Custom")
        }
    }

    /// The theme's colours, made once (Custom's whenever its colours change).
    var palette: ThemePalette { self == .custom ? ColorThemes.shared.customPalette : ThemePalette.all[self]! }
}

/// One theme's colours, light and dark.
struct ThemePalette: Sendable {
    /// Selection, prominent actions and progress, and the label colour on it.
    var accentLight: Color, accentDark: Color
    var onAccentLight: Color, onAccentDark: Color
    /// The page canvas (Backdrop) and the panels on it (Surface, settings rows).
    var backdropLight: Color, backdropDark: Color
    var surfaceLight: Color, surfaceDark: Color
    /// Apple TV, always dark: tiles and the raised, focused version of them (TVStyle).
    var tvSurface: Color, tvRaised: Color
    /// The same, following the appearance; and settings rows, white on light pages.
    let accent: Color, onAccent: Color, rowFill: Color

    init(accentLight: Color, accentDark: Color, onAccentLight: Color, onAccentDark: Color, backdropLight: Color, backdropDark: Color,
         surfaceLight: Color, surfaceDark: Color, tvSurface: Color, tvRaised: Color) {
        (self.accentLight, self.accentDark, self.onAccentLight, self.onAccentDark) = (accentLight, accentDark, onAccentLight, onAccentDark)
        (self.backdropLight, self.backdropDark, self.surfaceLight, self.surfaceDark) = (backdropLight, backdropDark, surfaceLight, surfaceDark)
        (self.tvSurface, self.tvRaised) = (tvSurface, tvRaised)
        accent = Color(light: accentLight, dark: accentDark)
        onAccent = Color(light: onAccentLight, dark: onAccentDark)
        rowFill = Color(light: .white, dark: surfaceDark)
    }

    /// A theme around one hue: canvases tinted with it, as Classic's navy is (`tint` 1; 0 gives greys), and a highlight
    /// that is deep on light pages and light on dark ones, so labels on it are white and near-black.
    static func hued(_ hue: Double, tint: Double = 1, light: Color, dark: Color, onLight: Color = .white,
                     onDark: Color = Color(white: 0.06)) -> ThemePalette {
        let h = hue / 360
        return ThemePalette(accentLight: light, accentDark: dark, onAccentLight: onLight, onAccentDark: onDark,
                            backdropLight: Color(hue: h, saturation: 0.035 * tint, brightness: 0.985),
                            backdropDark: Color(hue: h, saturation: 0.72 * tint, brightness: 0.085),
                            surfaceLight: Color(hue: h, saturation: 0.06 * tint, brightness: 0.965),
                            surfaceDark: Color(hue: h, saturation: 0.55 * tint, brightness: 0.19),
                            tvSurface: Color(hue: h, saturation: 0.55 * tint, brightness: 0.22),
                            tvRaised: Color(hue: h, saturation: 0.5 * tint, brightness: 0.29))
    }

    /// Custom: `highlight` as it is on light pages, lifted towards white on dark ones if it is dark; the canvases tinted
    /// with `background`'s hue, as much as it is saturated (a grey gives grey canvases).
    static func custom(highlight: ThemeRGB, background: ThemeRGB) -> ThemePalette {
        let dark = highlight.luminance < 0.35 ? highlight.mixed(with: ThemeRGB(1, 1, 1), by: 0.45) : highlight
        func label(on color: ThemeRGB) -> Color { color.luminance > 0.5 ? Color(white: 0.06) : .white }
        let (hue, saturation, _) = background.hsb
        return hued(hue * 360, tint: min(1, saturation / 0.45), light: highlight.color, dark: dark.color,
                    onLight: label(on: highlight), onDark: label(on: dark))
    }

    static let all: [ColorTheme: ThemePalette] = [
        // The original colours (before themes), unchanged.
        .classic: ThemePalette(accentLight: Color(white: 0.12), accentDark: Color(white: 0.92), onAccentLight: .white, onAccentDark: Color(white: 0.06),
                               backdropLight: Color(red: 0.955, green: 0.965, blue: 0.985), backdropDark: Color(red: 0.020, green: 0.035, blue: 0.090),
                               surfaceLight: Color(red: 0.915, green: 0.935, blue: 0.965), surfaceDark: Color(red: 0.075, green: 0.105, blue: 0.19),
                               tvSurface: Color(red: 0.09, green: 0.125, blue: 0.22), tvRaised: Color(red: 0.13, green: 0.175, blue: 0.29)),
        // The purple of the app's icon (Pocket).
        .violet: hued(246, light: Color(red: 0.40, green: 0.33, blue: 0.95), dark: Color(red: 0.68, green: 0.62, blue: 1.0)),
        .ocean: hued(212, light: Color(red: 0.07, green: 0.45, blue: 0.86), dark: Color(red: 0.45, green: 0.72, blue: 1.0)),
        .lagoon: hued(180, light: Color(red: 0.0, green: 0.53, blue: 0.52), dark: Color(red: 0.35, green: 0.86, blue: 0.82)),
        .forest: hued(145, light: Color(red: 0.12, green: 0.52, blue: 0.30), dark: Color(red: 0.45, green: 0.84, blue: 0.58)),
        .amber: hued(40, light: Color(red: 0.66, green: 0.42, blue: 0.0), dark: Color(red: 1.0, green: 0.77, blue: 0.32)),
        .sunset: hued(20, light: Color(red: 0.82, green: 0.34, blue: 0.10), dark: Color(red: 1.0, green: 0.62, blue: 0.40)),
        .rose: hued(335, light: Color(red: 0.82, green: 0.22, blue: 0.50), dark: Color(red: 1.0, green: 0.56, blue: 0.75)),
        .crimson: hued(356, light: Color(red: 0.76, green: 0.15, blue: 0.20), dark: Color(red: 1.0, green: 0.46, blue: 0.46)),
        .orchid: hued(285, light: Color(red: 0.60, green: 0.26, blue: 0.80), dark: Color(red: 0.84, green: 0.63, blue: 1.0)),
        // Neutral greys with no tint, and a near-black canvas.
        .graphite: ThemePalette(accentLight: Color(white: 0.12), accentDark: Color(white: 0.92), onAccentLight: .white, onAccentDark: Color(white: 0.06),
                                backdropLight: Color(white: 0.965), backdropDark: Color(white: 0.02),
                                surfaceLight: Color(white: 0.92), surfaceDark: Color(white: 0.11),
                                tvSurface: Color(white: 0.13), tvRaised: Color(white: 0.19)),
    ]
}

/// An sRGB colour as three numbers, for Custom's two colours: saved as "r g b".
struct ThemeRGB: Equatable, Sendable {
    var red: Double, green: Double, blue: Double
    init(_ red: Double, _ green: Double, _ blue: Double) { (self.red, self.green, self.blue) = (red, green, blue) }
    init?(saved: String?) {
        let parts = (saved ?? "").split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        self.init(parts[0], parts[1], parts[2])
    }
    init(_ color: Color) {
        #if os(macOS)
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        #else
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(Double(r), Double(g), Double(b))
        #endif
        (red, green, blue) = (min(max(red, 0), 1), min(max(green, 0), 1), min(max(blue, 0), 1))
    }
    var saved: String { "\(red) \(green) \(blue)" }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    /// Relative luminance (WCAG).
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    /// Hue (0..<1), saturation and brightness.
    var hsb: (Double, Double, Double) {
        let high = max(red, green, blue), low = min(red, green, blue), range = high - low
        guard range > 0 else { return (0, 0, high) }
        var hue: Double
        if high == red { hue = (green - blue) / range } else if high == green { hue = 2 + (blue - red) / range } else { hue = 4 + (red - green) / range }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, range / high, high)
    }
    func mixed(with other: ThemeRGB, by fraction: Double) -> ThemeRGB {
        ThemeRGB(red + (other.red - red) * fraction, green + (other.green - green) * fraction, blue + (other.blue - blue) * fraction)
    }
}

/// The theme in use. Views that read `Brand.accent` and the other themed colours redraw when it changes.
@Observable final class ColorThemes: @unchecked Sendable {
    static let shared = ColorThemes()
    static let key = "colorTheme"
    static let highlightKey = "colorThemeHighlight", backgroundKey = "colorThemeBackground"

    private(set) var current: ColorTheme
    /// Custom's two colours; until picked, Violet's.
    private(set) var highlight: ThemeRGB
    private(set) var background: ThemeRGB
    private(set) var customPalette: ThemePalette

    private init() {
        let defaults = UserDefaults.standard
        current = defaults.string(forKey: Self.key).flatMap(ColorTheme.init(rawValue:)) ?? .standard
        let highlight = ThemeRGB(saved: defaults.string(forKey: Self.highlightKey)) ?? ThemeRGB(0.40, 0.33, 0.95)
        let background = ThemeRGB(saved: defaults.string(forKey: Self.backgroundKey)) ?? ThemeRGB(0.40, 0.33, 0.95)
        (self.highlight, self.background) = (highlight, background)
        customPalette = ThemePalette.custom(highlight: highlight, background: background)
    }

    /// Changes one of Custom's colours, and makes Custom the theme in use.
    func setCustom(highlight: ThemeRGB? = nil, background: ThemeRGB? = nil) {
        if let highlight, highlight != self.highlight {
            self.highlight = highlight
            UserDefaults.standard.set(highlight.saved, forKey: Self.highlightKey)
        }
        if let background, background != self.background {
            self.background = background
            UserDefaults.standard.set(background.saved, forKey: Self.backgroundKey)
        }
        customPalette = ThemePalette.custom(highlight: self.highlight, background: self.background)
        choose(.custom)
    }

    func choose(_ theme: ColorTheme) {
        guard theme != current else { return }
        current = theme
        if theme == .standard { UserDefaults.standard.removeObject(forKey: Self.key) }
        else { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }
}

/// The app-wide tint in the theme's highlight. A modifier of its own, so a theme change redraws it.
struct ThemeTint: ViewModifier {
    func body(content: Content) -> some View { content.tint(Brand.accent) }
}

// MARK: Settings › Color Theme

struct ColorThemeSettingsView: View {
    @State private var themes = ColorThemes.shared

    var body: some View {
        SettingsPage(title: L10n.text("Color Theme"), symbol: "swatchpalette") {
            #if os(tvOS)
            SettingsGroup(footer: note) {
                ForEach(ColorTheme.choices) { theme in
                    Button { themes.choose(theme) } label: {
                        TVSettingsRowLabel(title: theme.title) {
                            ColorThemeSwatch(palette: theme.palette, dark: true).frame(width: 96, height: 54)
                            Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold))
                                .opacity(themes.current == theme ? 1 : 0)
                        }
                    }
                    .glassRow()
                    .accessibilityAddTraits(themes.current == theme ? .isSelected : [])
                }
            }
            #else
            SettingsGroup(footer: note) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ColorThemeTile.width), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(ColorTheme.choices) { theme in
                        Button { themes.choose(theme) } label: {
                            ColorThemeTile(theme: theme, selected: themes.current == theme)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("colorTheme.\(theme.rawValue)")
                    }
                }
                .padding(.vertical, 10)
            }
            if themes.current == .custom {
                SettingsGroup(title: L10n.text("Custom"),
                              footer: L10n.text("The highlight is used for selections and buttons; the background color tints the pages. A gray background keeps them neutral.")) {
                    ColorPicker(selection: Binding(get: { themes.highlight.color }, set: { themes.setCustom(highlight: ThemeRGB($0)) }),
                                supportsOpacity: false) {
                        FormLabel(symbol: "paintbrush.fill", tint: themes.highlight.color, title: L10n.text("Highlight"))
                    }
                    .accessibilityIdentifier("colorTheme.highlight")
                    ColorPicker(selection: Binding(get: { themes.background.color }, set: { themes.setCustom(background: ThemeRGB($0)) }),
                                supportsOpacity: false) {
                        FormLabel(symbol: "square.fill", tint: themes.background.color, title: L10n.text("Background"))
                    }
                    .accessibilityIdentifier("colorTheme.background")
                }
            }
            #endif
        }
    }

    private var note: String {
        L10n.text("Changes the highlight color and the backgrounds of the app's pages. Classic is the app's original look.")
    }
}

/// A theme in miniature: its canvas, a panel on it and a highlight bar.
struct ColorThemeSwatch: View {
    let palette: ThemePalette
    let dark: Bool
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                dark ? palette.backdropDark : palette.backdropLight
                RoundedRectangle(cornerRadius: h * 0.08, style: .continuous)
                    .fill(dark ? palette.surfaceDark : palette.surfaceLight)
                    .frame(width: w * 0.8, height: h * 0.42)
                    .offset(x: w * 0.1, y: h * 0.14)
                Capsule().fill(dark ? palette.accentDark : palette.accentLight)
                    .frame(width: w * 0.42, height: h * 0.16)
                    .offset(x: w * 0.1, y: h * 0.68)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5) }
    }
}

#if !os(tvOS)
/// One theme in the picker: dark and light swatches, its name, and a check under the one in use.
private struct ColorThemeTile: View {
    #if os(macOS)
    static let width: CGFloat = 112
    #else
    static let width: CGFloat = 100
    #endif
    let theme: ColorTheme
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ColorThemeSwatch(palette: theme.palette, dark: true)
                ColorThemeSwatch(palette: theme.palette, dark: false)
            }
            .frame(width: Self.width - 12, height: (Self.width - 12) * 0.62)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(4)
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(selected ? systemAccent : .clear, lineWidth: 2.5)
            }
            Text(theme.title).font(.caption).foregroundStyle(selected ? .primary : .secondary).lineLimit(1).minimumScaleFactor(0.8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.body).foregroundStyle(selected ? AnyShapeStyle(systemAccent) : AnyShapeStyle(.tertiary))
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
