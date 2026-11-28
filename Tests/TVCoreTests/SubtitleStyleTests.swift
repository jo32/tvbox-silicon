import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import TVCore

struct SubtitleStyleTests {
    private func value<T>(_ attributes: [String: Any], _ key: CFString, as: T.Type = T.self) -> T? {
        attributes[key as String] as? T
    }

    /// #547: the standard style has no box behind the letters, and a shadow keeps them readable instead.
    @Test func standardSubtitlesHaveNoBoxAndAShadow() throws {
        let style = SubtitleStyle()
        #expect(style.backdrop == .none && style.backdrop.opacity == 0 && style.edge == .shadow)
        #expect(style.x == 0.5 && style.y == SubtitleStyle.bottom && style.width == 0.9)
        let attributes = style.attributes
        #expect(value(attributes, kCMTextMarkupAttribute_ForegroundColorARGB, as: [Double].self) == [1, 1, 1, 1])
        #expect(value(attributes, kCMTextMarkupAttribute_CharacterEdgeStyle, as: String.self) == kCMTextMarkupCharacterEdgeStyle_DropShadow as String)
        #expect(value(attributes, kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight, as: Double.self) == 5)
        #expect(value(attributes, kCMTextMarkupAttribute_BoldStyle, as: Bool.self) == false)
        #expect(value(attributes, kCMTextMarkupAttribute_FontFamilyName, as: String.self) == nil)
        // AVPlayer's renderer places a cue itself (the app's overlay does the placing), so the rule says nothing about it.
        #expect(attributes[kCMTextMarkupAttribute_OrthogonalLinePositionPercentageRelativeToWritingDirection as String] == nil)
        // AVFoundation takes them as one rule over every cue.
        #expect(AVTextStyleRule(textMarkupAttributes: attributes) != nil)
    }

    @Test func choicesBecomeTextMarkup() throws {
        var style = SubtitleStyle()
        style.x = 0.3; style.size = 7; style.font = "Georgia"
        style.bold = true; style.italic = true; style.color = .yellow; style.edge = .outline; style.backdrop = .translucent
        let attributes = style.attributes
        #expect(value(attributes, kCMTextMarkupAttribute_BaseFontSizePercentageRelativeToVideoHeight, as: Double.self) == 7)
        #expect(value(attributes, kCMTextMarkupAttribute_FontFamilyName, as: String.self) == "Georgia")
        #expect(value(attributes, kCMTextMarkupAttribute_BoldStyle, as: Bool.self) == true)
        #expect(value(attributes, kCMTextMarkupAttribute_ItalicStyle, as: Bool.self) == true)
        #expect(value(attributes, kCMTextMarkupAttribute_ForegroundColorARGB, as: [Double].self) == [1, 1, 0.86, 0.2])
        #expect(value(attributes, kCMTextMarkupAttribute_CharacterEdgeStyle, as: String.self) == kCMTextMarkupCharacterEdgeStyle_Uniform as String)
        #expect(AVTextStyleRule(textMarkupAttributes: attributes) != nil)
        // Centred at 30% across, the box the lines wrap in is 60% wide, so it stays on the picture.
        #expect(abs(style.width - 0.6) < 1e-9)
    }

    @Test func outOfRangeValuesStayOnThePicture() {
        var style = SubtitleStyle()
        style.x = -3; style.y = .infinity; style.size = 40; style.font = "  "
        let clamped = style.clamped
        #expect(clamped.x == 0.15 && clamped.y == SubtitleStyle.bottom && clamped.size == SubtitleStyle.sizes.upperBound && clamped.font == nil)
        #expect(clamped.width > 0.29 && clamped.width < 0.31)
        style.y = -1
        #expect(style.clamped.y == 0)
    }

    @Test func savedStylesComeBackAndOddOnesFallBack() throws {
        let defaults = try #require(UserDefaults(suiteName: "SubtitleStyleTests-\(UUID().uuidString)"))
        #expect(SubtitleStyle.load(defaults) == SubtitleStyle())
        var style = SubtitleStyle()
        style.y = 0.3; style.edge = .raised; style.font = "Menlo"
        style.save(defaults)
        #expect(SubtitleStyle.load(defaults) == style)
        // A newer app's colour, or a field an older one never wrote, falls back to the standard choice.
        defaults.set(Data(#"{"color":"ultraviolet","bold":true,"size":2}"#.utf8), forKey: SubtitleStyle.key)
        let odd = SubtitleStyle.load(defaults)
        #expect(odd.color == .white && odd.bold && odd.size == SubtitleStyle.sizes.lowerBound && odd.y == SubtitleStyle.bottom)
        defaults.set(Data("not json".utf8), forKey: SubtitleStyle.key)
        #expect(SubtitleStyle.load(defaults) == SubtitleStyle())
    }

    /// #2725: the script is a new field, so a style saved before it must still read, in the script the text arrived in.
    @Test func stylesSavedBeforeTheScriptChoiceStillLoad() throws {
        let defaults = try #require(UserDefaults(suiteName: "SubtitleStyleTests-\(UUID().uuidString)"))
        // Exactly what 1.8.33 saved: no "script" key.
        let old = #"{"x":0.5,"y":0.92,"size":6,"bold":true,"italic":false,"color":"yellow","edge":"outline","backdrop":"none","positionWasChosen":false}"#
        defaults.set(Data(old.utf8), forKey: SubtitleStyle.key)
        let style = SubtitleStyle.load(defaults)
        #expect(style.script == .original)
        #expect(style.size == 6 && style.bold && style.color == .yellow && style.edge == .outline)
        // A JSON object with nothing in it at all must not throw either.
        #expect((try? JSONDecoder().decode(SubtitleStyle.self, from: Data("{}".utf8)))?.script == .original)
    }

    @Test func theScriptChoiceRoundTrips() throws {
        var style = SubtitleStyle()
        style.script = .traditional
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(SubtitleStyle.self, from: data).script == .traditional)
        // A choice a newer app wrote falls back to the standard one rather than failing to read the style.
        let odd = #"{"script":"bopomofo"}"#
        #expect(try JSONDecoder().decode(SubtitleStyle.self, from: Data(odd.utf8)).script == .original)
        // Equatable still tells the choices apart.
        var other = style
        other.script = .simplified
        #expect(style != other)
        #expect(SubtitleStyle().script == .original)
    }

    /// #2725: the lines are converted after `lines(_:)` has broken the cues up, in the chosen script's own phrases.
    @Test func theScriptConvertsSubtitleLines() {
        var style = SubtitleStyle()
        style.script = .traditional
        let lines = SubtitleStyle.lines(["头发很长\n后来我们干杯了"])
        #expect(style.script.convert(lines) == ["頭髮很長", "後來我們乾杯了"])
        style.script = .original
        #expect(style.script.convert(lines) == lines)
    }

    /// A legible output hands over one string for each cue on screen, each perhaps several lines.
    @Test func cuesBecomeLines() {
        #expect(SubtitleStyle.lines(["你好\n世界 ", "", "  Second\r\n\nthird"]) == ["你好", "世界", "Second", "third"])
        #expect(SubtitleStyle.lines([]).isEmpty)
    }
}
