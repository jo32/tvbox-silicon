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
// Classic is the app's original look, navy canvases with a neutral highlight. Custom takes a colour the viewer picks for
// each part of the window (iPhone, iPad and Mac; Apple TV has no colour picker).

/// A colour theme the app ships with.
enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    case classic = "Classic", violet = "Violet", ocean = "Ocean", lagoon = "Lagoon", forest = "Forest", amber = "Amber"
    case sunset = "Sunset", rose = "Rose", crimson = "Crimson", orchid = "Orchid", graphite = "Graphite"
    // Mixed: as in an editor theme, each part of the window in a colour of its own (title bar, sidebar, canvas, status
    // strip) and four colours for icons.
    case sunshineBeach = "SunshineBeach", watermelon = "Watermelon", tropical = "Tropical", sunsetSky = "SunsetSky"
    case mintLemonade = "MintLemonade", peachSoda = "PeachSoda", neonNight = "NeonNight", aurora = "Aurora"
    case custom = "Custom"

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
        case .sunshineBeach: L10n.text("Sunshine Beach")
        case .watermelon: L10n.text("Watermelon")
        case .tropical: L10n.text("Tropical")
        case .sunsetSky: L10n.text("Sunset Sky")
        case .mintLemonade: L10n.text("Mint Lemonade")
        case .peachSoda: L10n.text("Peach Soda")
        case .neonNight: L10n.text("Neon Night")
        case .aurora: L10n.text("Aurora")
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
    /// The same, following the appearance; settings rows, white on light pages; the canvas and the panels.
    let accent: Color, onAccent: Color, canvas: Color, panel: Color
    var rowFill: Color
    /// A mixed theme's colours for each part of the window; nil in one-colour themes.
    var regions: ThemeRegions? = nil

    init(accentLight: Color, accentDark: Color, onAccentLight: Color, onAccentDark: Color, backdropLight: Color, backdropDark: Color,
         surfaceLight: Color, surfaceDark: Color, tvSurface: Color, tvRaised: Color) {
        (self.accentLight, self.accentDark, self.onAccentLight, self.onAccentDark) = (accentLight, accentDark, onAccentLight, onAccentDark)
        (self.backdropLight, self.backdropDark, self.surfaceLight, self.surfaceDark) = (backdropLight, backdropDark, surfaceLight, surfaceDark)
        (self.tvSurface, self.tvRaised) = (tvSurface, tvRaised)
        accent = Color(light: accentLight, dark: accentDark)
        onAccent = Color(light: onAccentLight, dark: onAccentDark)
        rowFill = Color(light: .white, dark: surfaceDark)
        canvas = Color(light: backdropLight, dark: backdropDark)
        panel = Color(light: surfaceLight, dark: surfaceDark)
    }

    /// A theme around one hue: canvases tinted with it, as Classic's navy is (`tint` 1; 0 gives greys), and a highlight
    /// that is deep on light pages and light on dark ones, so labels on it are white and near-black.
    static func hued(_ hue: Double, tint: Double = 1, light: Color, dark: Color, onLight: Color = .white,
                     onDark: Color = Color(white: 0.06)) -> ThemePalette {
        let h = hue / 360
        return ThemePalette(accentLight: light, accentDark: dark, onAccentLight: onLight, onAccentDark: onDark,
                            backdropLight: Color(hue: h, saturation: 0.07 * tint, brightness: 0.98),
                            backdropDark: Color(hue: h, saturation: 0.8 * tint, brightness: 0.12),
                            surfaceLight: Color(hue: h, saturation: 0.13 * tint, brightness: 0.95),
                            surfaceDark: Color(hue: h, saturation: 0.62 * tint, brightness: 0.23),
                            tvSurface: Color(hue: h, saturation: 0.6 * tint, brightness: 0.25),
                            tvRaised: Color(hue: h, saturation: 0.55 * tint, brightness: 0.33))
    }

    /// A mixed theme, coloured the way an editor theme colours its title bar, side bar, status bar and editor apart: a
    /// canvas running through the `canvas` hues, panels in the middle one, a sidebar and a title bar in hues of their own,
    /// a status strip, and four `decor` colours for icons in place of the app icon's cyan, indigo, teal and amber.
    static func mixed(canvas: [Double], sidebar: [Double], title: Double, status: Color, onStatus: Color = .white,
                      decor: [Color], light: Color, dark: Color, onLight: Color = .white,
                      onDark: Color = Color(white: 0.06)) -> ThemePalette {
        func tone(_ hue: Double, _ saturation: Double, _ brightness: Double) -> Color {
            Color(hue: hue / 360, saturation: saturation, brightness: brightness)
        }
        let middle = canvas[canvas.count / 2]
        var palette = ThemePalette(accentLight: light, accentDark: dark, onAccentLight: onLight, onAccentDark: onDark,
                                   backdropLight: tone(canvas[0], 0.2, 0.97), backdropDark: tone(canvas[0], 0.62, 0.24),
                                   surfaceLight: tone(middle, 0.1, 0.995), surfaceDark: tone(middle, 0.5, 0.29),
                                   tvSurface: tone(middle, 0.55, 0.27), tvRaised: tone(middle, 0.5, 0.36))
        let deeper = decor.map { ThemeRGB($0).mixed(with: ThemeRGB(0, 0, 0), by: 0.18).color }
        palette.regions = ThemeRegions(canvasLight: canvas.map { tone($0, 0.2, 0.97) }, canvasDark: canvas.map { tone($0, 0.62, 0.24) },
                                       sidebarLight: sidebar.map { tone($0, 0.3, 0.93) }, sidebarDark: sidebar.map { tone($0, 0.7, 0.16) },
                                       titleBarLight: tone(title, 0.42, 0.9), titleBarDark: tone(title, 0.78, 0.21),
                                       status: status, onStatus: onStatus,
                                       // Icons a little deeper on light pages, so a lemon or sand one still reads on a pale sidebar.
                                       decorLight: deeper, decorDark: decor)
        return palette
    }

    /// Custom: each element in exactly the colour picked for it, the same in light and dark mode (the app takes the
    /// appearance that suits the page background, see `ColorThemes.customScheme`).
    static func custom(_ colors: [CustomThemeElement: ThemeRGB]) -> ThemePalette {
        func rgb(_ element: CustomThemeElement) -> ThemeRGB { colors[element] ?? element.fallback }
        func color(_ element: CustomThemeElement) -> Color { rgb(element).color }
        func label(on element: CustomThemeElement) -> Color { rgb(element).luminance > 0.18 ? Color(white: 0.06) : .white }
        let highlight = color(.highlight), panel = color(.panel), top = color(.canvasTop)
        var palette = ThemePalette(accentLight: highlight, accentDark: highlight, onAccentLight: label(on: .highlight),
                                   onAccentDark: label(on: .highlight), backdropLight: top, backdropDark: top,
                                   surfaceLight: panel, surfaceDark: panel, tvSurface: panel, tvRaised: panel)
        palette.rowFill = panel
        let canvas = [top, color(.canvasBottom)], sidebar = [color(.sidebar), color(.sidebar)]
        let icons = [color(.icon1), color(.icon2), color(.icon3), color(.icon4)]
        palette.regions = ThemeRegions(canvasLight: canvas, canvasDark: canvas, sidebarLight: sidebar, sidebarDark: sidebar,
                                       titleBarLight: color(.titleBar), titleBarDark: color(.titleBar),
                                       status: color(.statusBar), onStatus: label(on: .statusBar), decorLight: icons, decorDark: icons)
        return palette
    }

    /// This theme's colours as Custom's elements, as they look in light or dark mode: a starting point for Custom.
    func customElements(dark: Bool) -> [CustomThemeElement: ThemeRGB] {
        let accent = dark ? accentDark : accentLight
        let canvas = regions.map { dark ? $0.canvasDark : $0.canvasLight } ?? [dark ? backdropDark : backdropLight]
        // One-colour themes draw settings rows white on light pages.
        let panel = dark ? surfaceDark : (regions == nil ? Color.white : surfaceLight)
        let sidebar = regions.map { (dark ? $0.sidebarDark : $0.sidebarLight)[0] } ?? (dark ? surfaceDark : surfaceLight)
        let title = regions.map { dark ? $0.titleBarDark : $0.titleBarLight } ?? canvas[0]
        let icons = regions.map { dark ? $0.decorDark : $0.decorLight } ?? ThemeRegions.standardDecor
        let colors: [(CustomThemeElement, Color)] = [
            (.highlight, accent), (.canvasTop, canvas[0]), (.canvasBottom, canvas[canvas.count - 1]), (.panel, panel),
            (.sidebar, sidebar), (.titleBar, title), (.statusBar, regions?.status ?? accent),
            (.icon1, icons[0]), (.icon2, icons[1]), (.icon3, icons[2]), (.icon4, icons[3]),
        ]
        return Dictionary(uniqueKeysWithValues: colors.map { ($0.0, ThemeRGB($0.1)) })
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color { Color(red: red, green: green, blue: blue) }

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
        // Sea, surf and sand under a coral strip, with the sun as the highlight.
        .sunshineBeach: mixed(canvas: [200, 180, 32], sidebar: [205, 192], title: 40, status: Color(red: 1.0, green: 0.45, blue: 0.32),
                              decor: [rgb(0.20, 0.78, 0.86), rgb(0.22, 0.52, 0.96), rgb(1.0, 0.46, 0.36), rgb(1.0, 0.78, 0.22)],
                              light: rgb(0.88, 0.40, 0.16), dark: rgb(1.0, 0.72, 0.28)),
        // Pink flesh on the canvas, a green-rind sidebar and title bar, red highlight.
        .watermelon: mixed(canvas: [345, 355, 95], sidebar: [150, 135], title: 140, status: Color(red: 0.88, green: 0.22, blue: 0.34),
                           decor: [rgb(1.0, 0.42, 0.52), rgb(0.16, 0.66, 0.42), rgb(0.58, 0.86, 0.34), rgb(1.0, 0.66, 0.72)],
                           light: rgb(0.85, 0.22, 0.33), dark: rgb(1.0, 0.48, 0.54)),
        // Lagoon, palm and mango, a hibiscus title bar and strip.
        .tropical: mixed(canvas: [175, 130, 40], sidebar: [170, 158], title: 330, status: Color(red: 0.92, green: 0.24, blue: 0.52),
                         decor: [rgb(0.10, 0.80, 0.78), rgb(1.0, 0.36, 0.60), rgb(0.32, 0.80, 0.40), rgb(1.0, 0.70, 0.20)],
                         light: rgb(0.85, 0.13, 0.42), dark: rgb(1.0, 0.45, 0.66)),
        // Indigo dusk through violet into the orange glow, with gold.
        .sunsetSky: mixed(canvas: [248, 292, 18], sidebar: [255, 272], title: 235, status: Color(red: 1.0, green: 0.52, blue: 0.20),
                          decor: [rgb(0.96, 0.38, 0.70), rgb(0.62, 0.48, 1.0), rgb(1.0, 0.52, 0.28), rgb(1.0, 0.80, 0.30)],
                          light: rgb(0.76, 0.47, 0.0), dark: rgb(1.0, 0.76, 0.30)),
        // Mint, lime and lemon, a lemon title bar, a mint strip.
        .mintLemonade: mixed(canvas: [160, 95, 55], sidebar: [165, 150], title: 55, status: Color(red: 0.08, green: 0.66, blue: 0.52),
                             decor: [rgb(0.30, 0.84, 0.66), rgb(0.36, 0.68, 1.0), rgb(0.60, 0.84, 0.24), rgb(1.0, 0.84, 0.20)],
                             light: rgb(0.04, 0.56, 0.48), dark: rgb(0.44, 0.89, 0.78)),
        // Peach and pink fizz on soda blue.
        .peachSoda: mixed(canvas: [22, 350, 190], sidebar: [192, 202], title: 20, status: Color(red: 0.94, green: 0.40, blue: 0.54),
                          decor: [rgb(0.32, 0.80, 0.90), rgb(1.0, 0.50, 0.64), rgb(1.0, 0.64, 0.44), rgb(1.0, 0.84, 0.46)],
                          light: rgb(0.87, 0.33, 0.45), dark: rgb(1.0, 0.62, 0.68)),
        // Synth-wave neon: deep purples, hot pink highlight, a cyan strip.
        .neonNight: mixed(canvas: [262, 288, 318], sidebar: [252, 268], title: 244, status: Color(red: 0.10, green: 0.82, blue: 0.92),
                          onStatus: Color(white: 0.06),
                          decor: [rgb(0.22, 0.90, 1.0), rgb(0.70, 0.46, 1.0), rgb(1.0, 0.30, 0.70), rgb(1.0, 0.90, 0.30)],
                          light: rgb(0.85, 0.15, 0.55), dark: rgb(1.0, 0.45, 0.80)),
        // Polar night lit green and violet.
        .aurora: mixed(canvas: [218, 192, 150], sidebar: [222, 232], title: 210, status: Color(red: 0.30, green: 0.86, blue: 0.60),
                       onStatus: Color(white: 0.06),
                       decor: [rgb(0.36, 0.90, 0.62), rgb(0.66, 0.52, 1.0), rgb(0.22, 0.80, 0.86), rgb(1.0, 0.52, 0.76)],
                       light: rgb(0.10, 0.55, 0.45), dark: rgb(0.45, 0.95, 0.70)),
        // Neutral greys with no tint, and a near-black canvas.
        .graphite: ThemePalette(accentLight: Color(white: 0.12), accentDark: Color(white: 0.92), onAccentLight: .white, onAccentDark: Color(white: 0.06),
                                backdropLight: Color(white: 0.965), backdropDark: Color(white: 0.02),
                                surfaceLight: Color(white: 0.92), surfaceDark: Color(white: 0.11),
                                tvSurface: Color(white: 0.13), tvRaised: Color(white: 0.19)),
    ]
}

/// A mixed theme's colours for the parts of the window an editor theme colours apart (see `ThemePalette.mixed`), and
/// Custom's.
struct ThemeRegions: Sendable {
    /// The app icon's cyan, indigo, teal and amber: the icon colours of every other theme.
    static let standardDecor = [Color(red: 0.30, green: 0.78, blue: 1.0), Color(red: 0.42, green: 0.50, blue: 1.0),
                                Color(red: 0.20, green: 0.84, blue: 0.80), Color(red: 1.0, green: 0.76, blue: 0.30)]
    /// The canvas, light and dark, from the top leading corner to the bottom trailing one.
    let canvasLight: [Color], canvasDark: [Color]
    /// The Mac sidebar, top to bottom.
    let sidebarLight: [Color], sidebarDark: [Color]
    /// The band under the Mac window's toolbar.
    let titleBarLight: Color, titleBarDark: Color
    /// The strip at the foot of the Mac sidebar, and its label colour.
    let status: Color, onStatus: Color
    /// Icons and decoration: this theme's Brand.cyan, .indigo, .teal and .amber.
    let decorLight: [Color], decorDark: [Color]
    /// The title bar and icon colours, following the appearance.
    let titleBar: Color, decor: [Color]

    init(canvasLight: [Color], canvasDark: [Color], sidebarLight: [Color], sidebarDark: [Color], titleBarLight: Color,
         titleBarDark: Color, status: Color, onStatus: Color, decorLight: [Color], decorDark: [Color]) {
        (self.canvasLight, self.canvasDark, self.sidebarLight, self.sidebarDark) = (canvasLight, canvasDark, sidebarLight, sidebarDark)
        (self.titleBarLight, self.titleBarDark, self.status, self.onStatus) = (titleBarLight, titleBarDark, status, onStatus)
        (self.decorLight, self.decorDark) = (decorLight, decorDark)
        titleBar = Color(light: titleBarLight, dark: titleBarDark)
        decor = zip(decorLight, decorDark).map { Color(light: $0, dark: $1) }
    }
}

/// One part of the window whose colour Custom lets the viewer pick.
enum CustomThemeElement: String, CaseIterable, Identifiable, Sendable {
    case highlight, canvasTop, canvasBottom, panel, sidebar, titleBar, statusBar, icon1, icon2, icon3, icon4

    var id: String { rawValue }
    /// The elements this device draws: the sidebar, its status strip and the title bar are the Mac's.
    static var editable: [CustomThemeElement] {
        #if os(macOS)
        allCases
        #else
        allCases.filter { ![.sidebar, .titleBar, .statusBar].contains($0) }
        #endif
    }

    var title: String {
        switch self {
        case .highlight: L10n.text("Highlight")
        case .canvasTop: L10n.text("Page Background, Top")
        case .canvasBottom: L10n.text("Page Background, Bottom")
        case .panel: L10n.text("Cards and Rows")
        case .sidebar: L10n.text("Sidebar")
        case .titleBar: L10n.text("Title Bar")
        case .statusBar: L10n.text("Status Bar")
        case .icon1: L10n.text("Icon Color %@", "1")
        case .icon2: L10n.text("Icon Color %@", "2")
        case .icon3: L10n.text("Icon Color %@", "3")
        case .icon4: L10n.text("Icon Color %@", "4")
        }
    }

    var detail: String {
        switch self {
        case .highlight: L10n.text("Selections, buttons and progress")
        case .canvasTop: L10n.text("Where the page background starts, at the top left")
        case .canvasBottom: L10n.text("Where it ends, at the bottom right. Pick the same color for a flat background.")
        case .panel: L10n.text("Cards, lists and settings rows")
        case .sidebar: L10n.text("Behind the sections on the left")
        case .titleBar: L10n.text("The band under the window's toolbar")
        case .statusBar: L10n.text("The version strip at the foot of the sidebar")
        case .icon1, .icon2, .icon3, .icon4: L10n.text("Section icons, settings icons and tiles")
        }
    }

    var symbol: String {
        switch self {
        case .highlight: "paintbrush.fill"
        case .canvasTop: "square.tophalf.filled"
        case .canvasBottom: "square.bottomhalf.filled"
        case .panel: "rectangle.on.rectangle"
        case .sidebar: "sidebar.left"
        case .titleBar: "macwindow"
        case .statusBar: "rectangle.bottomthird.inset.filled"
        case .icon1, .icon2, .icon3, .icon4: "paintpalette.fill"
        }
    }

    /// Until the viewer picks it: Violet's colour in dark mode.
    var fallback: ThemeRGB { Self.fallbacks[self] ?? ThemeRGB(0.5, 0.5, 0.5) }
    private static let fallbacks = ThemePalette.all[.violet]!.customElements(dark: true)
}

/// An sRGB colour as three numbers/// An sRGB colour as three numbers, for Custom's colours: saved as "r g b".
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
    static let customKey = "colorThemeCustom"

    private(set) var current: ColorTheme
    /// Custom's colours by element, as picked; the rest are Violet's.
    private(set) var custom: [CustomThemeElement: ThemeRGB]
    private(set) var customPalette: ThemePalette

    private init() {
        let defaults = UserDefaults.standard
        current = defaults.string(forKey: Self.key).flatMap(ColorTheme.init(rawValue:)) ?? .standard
        let saved = defaults.dictionary(forKey: Self.customKey) as? [String: String] ?? [:]
        let custom = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
            CustomThemeElement(rawValue: key).flatMap { element in ThemeRGB(saved: value).map { (element, $0) } }
        })
        self.custom = custom
        customPalette = ThemePalette.custom(custom)
    }

    func customColor(_ element: CustomThemeElement) -> ThemeRGB { custom[element] ?? element.fallback }
    /// Whether the viewer has picked any of Custom's colours yet.
    var customized: Bool { !custom.isEmpty }

    /// Sets one of Custom's colours, and makes Custom the theme in use.
    func setCustom(_ element: CustomThemeElement, to color: ThemeRGB) {
        guard custom[element] != color || current != .custom else { return }
        custom[element] = color
        saveCustom()
    }

    /// Starts Custom again from `theme`'s colours as they look in light or dark mode, and makes it the theme in use.
    func startCustom(from theme: ColorTheme, dark: Bool) {
        custom = theme.palette.customElements(dark: dark)
        saveCustom()
    }

    private func saveCustom() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: custom.map { ($0.key.rawValue, $0.value.saved) }), forKey: Self.customKey)
        customPalette = ThemePalette.custom(custom)
        choose(.custom)
    }

    /// Custom's colours are the same in light and dark mode, so the app takes the appearance whose text reads on its
    /// page background; every other theme follows the system.
    var customScheme: ColorScheme? {
        guard current == .custom else { return nil }
        return (customColor(.canvasTop).luminance + customColor(.canvasBottom).luminance) / 2 > 0.18 ? .light : .dark
    }

    func choose(_ theme: ColorTheme) {
        guard theme != current else { return }
        current = theme
        if theme == .standard { UserDefaults.standard.removeObject(forKey: Self.key) }
        else { UserDefaults.standard.set(theme.rawValue, forKey: Self.key) }
    }
}

/// The app-wide tint in the theme's highlight, and Custom's appearance. A modifier of its own, so a theme change redraws it.
struct ThemeTint: ViewModifier {
    func body(content: Content) -> some View { content.tint(Brand.accent).preferredColorScheme(ColorThemes.shared.customScheme) }
}

extension ColorThemes {
    /// Whether the Mac's own chrome (sidebar, Settings pages) takes the theme; Classic keeps the system's, as before themes.
    var tintsChrome: Bool { current != .classic }
}

#if os(macOS)
/// Under a Mac sidebar: the theme's panel colour (a mixed theme's sidebar colours), or nothing in Classic (the system's sidebar).
struct ThemedSidebarFill: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if ColorThemes.shared.tintsChrome {
            let palette = ColorThemes.shared.current.palette
            if let regions = palette.regions {
                LinearGradient(colors: scheme == .dark ? regions.sidebarDark : regions.sidebarLight, startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            } else {
                palette.panel.ignoresSafeArea()
            }
        }
    }
}

/// A mixed theme's title bar: a band of its colour under the window toolbar, over the page, as an editor theme colours
/// its title bar. Nothing in other themes. It takes no clicks and goes when the toolbar does (no top safe area).
struct ThemedTitleBand: View {
    var body: some View {
        if let color = ColorThemes.shared.current.palette.regions?.titleBar {
            GeometryReader { proxy in
                color.frame(height: proxy.safeAreaInsets.top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// A Mac Settings form on the theme's canvas, up under the title bar; Classic keeps the system's background.
struct ThemedFormBackground: ViewModifier {
    func body(content: Content) -> some View {
        if ColorThemes.shared.tintsChrome {
            content.scrollContentBackground(.hidden).background { Backdrop() }
        } else {
            content
        }
    }
}
#endif

// MARK: Settings › Color Theme

struct ColorThemeSettingsView: View {
    @State private var themes = ColorThemes.shared
    @Environment(\.colorScheme) private var scheme

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
                        Button {
                            // Custom starts from the theme in use, as it looks now.
                            if theme == .custom && !themes.customized {
                                themes.startCustom(from: themes.current == .custom ? .violet : themes.current, dark: scheme == .dark)
                            } else {
                                themes.choose(theme)
                            }
                        } label: {
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
                              footer: L10n.text("Each color is used exactly as picked, in light and dark mode. Text turns light or dark to match the page background.")) {
                    // A row like the others: its label at the leading edge, the menu at the trailing one.
                    LabeledContent {
                        Menu(L10n.text("Choose a Theme")) {
                            ForEach(ColorTheme.choices.filter { $0 != .custom }) { theme in
                                Button(theme.title) { themes.startCustom(from: theme, dark: scheme == .dark) }
                            }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("colorTheme.startFrom")
                    } label: {
                        FormLabel(symbol: "wand.and.stars", tint: Brand.accent, title: L10n.text("Start From a Theme"))
                    }
                    ForEach(CustomThemeElement.editable) { element in
                        ColorPicker(selection: Binding(get: { themes.customColor(element).color },
                                                       set: { themes.setCustom(element, to: ThemeRGB($0)) }),
                                    supportsOpacity: false) {
                            FormLabel(symbol: element.symbol, tint: themes.customColor(element).color, title: element.title,
                                      subtitle: element.detail)
                        }
                        .accessibilityIdentifier("colorTheme.custom.\(element.rawValue)")
                    }
                }
            }
            #endif
        }
    }

    private var note: String {
        L10n.text("Changes the app's colors: the highlight, page backgrounds, cards and icons, and on a Mac the sidebar and title bar. Classic is the app's original look.")
    }
}

/// A theme's canvas: one colour, or a mixed theme's running from the top leading corner to the bottom trailing one.
struct ThemeCanvas: View {
    let palette: ThemePalette
    let dark: Bool
    var body: some View {
        if let regions = palette.regions {
            LinearGradient(colors: dark ? regions.canvasDark : regions.canvasLight, startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            dark ? palette.backdropDark : palette.backdropLight
        }
    }
}

/// A theme in miniature: its canvas, a panel on it and a highlight bar.
struct ColorThemeSwatch: View {
    let palette: ThemePalette
    let dark: Bool
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            if let regions = palette.regions {
                // A window in miniature: title bar, sidebar with its icon colours and status strip, canvas with a panel.
                ZStack(alignment: .topLeading) {
                    ThemeCanvas(palette: palette, dark: dark)
                    LinearGradient(colors: dark ? regions.sidebarDark : regions.sidebarLight, startPoint: .top, endPoint: .bottom)
                        .frame(width: w * 0.3)
                    VStack(spacing: h * 0.06) {
                        ForEach(regions.decorDark.indices, id: \.self) { index in
                            Circle().fill((dark ? regions.decorDark : regions.decorLight)[index]).frame(width: h * 0.1, height: h * 0.1)
                        }
                    }
                    .frame(width: w * 0.3)
                    .offset(y: h * 0.24)
                    (dark ? regions.titleBarDark : regions.titleBarLight).frame(height: h * 0.15)
                    regions.status.frame(width: w * 0.3, height: h * 0.1).offset(y: h * 0.9)
                    RoundedRectangle(cornerRadius: h * 0.06, style: .continuous)
                        .fill(dark ? palette.surfaceDark : palette.surfaceLight)
                        .frame(width: w * 0.58, height: h * 0.3)
                        .offset(x: w * 0.36, y: h * 0.27)
                    Capsule().fill(dark ? palette.accentDark : palette.accentLight)
                        .frame(width: w * 0.32, height: h * 0.12)
                        .offset(x: w * 0.36, y: h * 0.68)
                }
                .environment(\.colorScheme, dark ? .dark : .light)
            } else {
            ZStack(alignment: .topLeading) {
                ThemeCanvas(palette: palette, dark: dark)
                RoundedRectangle(cornerRadius: h * 0.08, style: .continuous)
                    .fill(dark ? palette.surfaceDark : palette.surfaceLight)
                    .frame(width: w * 0.8, height: h * 0.42)
                    .offset(x: w * 0.1, y: h * 0.14)
                Capsule().fill(dark ? palette.accentDark : palette.accentLight)
                    .frame(width: w * 0.42, height: h * 0.16)
                    .offset(x: w * 0.1, y: h * 0.68)
            }
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
