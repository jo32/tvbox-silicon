import SwiftUI
import CoreText
import TVCore
#if os(macOS)
import AppKit
typealias NovelPlatformFont = NSFont
typealias NovelPlatformColor = NSColor
#else
import UIKit
typealias NovelPlatformFont = UIFont
typealias NovelPlatformColor = UIColor
#endif

/// How a chapter is set: the type, its colour and the space around lines and paragraphs.
struct NovelTypeStyle: Hashable {
    var fontSize: Double
    var lineHeight: Double
    var font: NovelFontChoice
    var text: Color
    /// Bumped when a downloaded font arrives, so pages set in the fallback are set again.
    var fontsReady: Int

    func bodyFont() -> NovelPlatformFont { font.platformFont(size: fontSize, bold: false) }
    func headingFont() -> NovelPlatformFont { font.platformFont(size: fontSize * 1.45, bold: true) }

    /// A chapter as attributed text: a chapter opening set as books print it ("第一章" small and spaced above the
    /// title, centred, a short rule under it, with air above), then the paragraphs, justified, each first line
    /// indented two characters, on a fixed line pitch so every page has the same rhythm.
    func text(_ content: NovelContent) -> NSAttributedString {
        let body = bodyFont()
        let color = NovelPlatformColor(text)
        let result = NSMutableAttributedString()
        let opening = Self.opening(content.title)
        let air = fontSize * 4.2

        func centred(_ size: CGFloat, before: CGFloat, after: CGFloat, pitch: CGFloat) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byWordWrapping
            style.minimumLineHeight = pitch
            style.maximumLineHeight = pitch
            style.paragraphSpacingBefore = before
            style.paragraphSpacing = after
            return style
        }
        // TextKit drops the space before a text's first paragraph, so the air above the opening is an empty line.
        result.append(NSAttributedString(string: "\n", attributes: [
            .font: body, .paragraphStyle: centred(body.pointSize, before: 0, after: 0, pitch: air),
        ]))
        if let kicker = opening.kicker {
            let small = font.platformFont(size: fontSize * 0.92, bold: false)
            result.append(NSAttributedString(string: kicker + "\n", attributes: [
                .font: small, .foregroundColor: color.withAlphaComponent(0.6), .kern: fontSize * 0.3,
                .paragraphStyle: centred(small.pointSize, before: 0, after: fontSize * 0.5, pitch: small.pointSize * 1.5),
            ]))
        }
        let heading = headingFont()
        let pitch = heading.pointSize * 1.35
        result.append(NSAttributedString(string: opening.title + "\n", attributes: [
            .font: heading, .foregroundColor: color, .kern: fontSize * 0.08,
            .paragraphStyle: centred(heading.pointSize, before: 0, after: fontSize * 0.7, pitch: pitch),
            .baselineOffset: (pitch - heading.lineHeightValue) / 2,
        ]))
        let rule = font.platformFont(size: fontSize * 0.7, bold: false)
        result.append(NSAttributedString(string: Self.rule + "\n", attributes: [
            .font: rule, .foregroundColor: color.withAlphaComponent(0.3),
            .paragraphStyle: centred(rule.pointSize, before: 0, after: fontSize * 2.4, pitch: rule.pointSize * 1.4),
        ]))

        let line = fontSize * lineHeight
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.firstLineHeadIndent = fontSize * 2
        paragraph.minimumLineHeight = line
        paragraph.maximumLineHeight = line
        paragraph.paragraphSpacing = fontSize * 0.4
        paragraph.hyphenationFactor = 0.8
        result.append(NSAttributedString(string: Self.paragraphs(content).joined(separator: "\n"), attributes: [
            .font: body, .foregroundColor: color, .paragraphStyle: paragraph,
            .baselineOffset: (line - body.lineHeightValue) / 2,
        ]))
        return result
    }

    private static let rule = "\u{2014}\u{2014}"

    nonisolated(unsafe) private static let openingPattern = try! NSRegularExpression(
        pattern: #"^(第[0-9０-９〇零一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+[章节回卷集部篇话])[\s:：、.．·\-—_]*(.+)$"#)

    /// "第一章：海洋时代" as ("第一章", "海洋时代"); a title without a chapter number stays whole.
    static func opening(_ title: String) -> (kicker: String?, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = openingPattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let kicker = Range(match.range(at: 1), in: title), let rest = Range(match.range(at: 2), in: title) else {
            return (nil, title)
        }
        return (String(title[kicker]), String(title[rest]))
    }

    /// The chapter's paragraphs without the indents and blank lines sites put in, and without a first line that only
    /// repeats the title.
    static func paragraphs(_ content: NovelContent) -> [String] {
        var paragraphs = content.paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}\u{00A0}"))) }
            .filter { !$0.isEmpty }
        if let first = paragraphs.first, NovelChapterTitle.key(first) == NovelChapterTitle.key(content.title) { paragraphs.removeFirst() }
        return paragraphs
    }

    /// The length of `text(content)`, which does not depend on the style: positions are kept as a share of it.
    static func length(_ content: NovelContent) -> Int {
        let opening = opening(content.title)
        var length = 1 + (opening.title as NSString).length + 1 + (rule as NSString).length + 1
        if let kicker = opening.kicker { length += (kicker as NSString).length + 1 }
        return length + (paragraphs(content).joined(separator: "\n") as NSString).length
    }
}

private extension NovelPlatformFont {
    var lineHeightValue: CGFloat {
        #if os(macOS)
        ascender - descender + leading
        #else
        lineHeight
        #endif
    }
}

/// The reader's typefaces. Songti and Kaiti come with macOS; iPhone, iPad and Apple TV download them from Apple the
/// first time they are picked, setting the text in the system font until they arrive.
enum NovelFontChoice: String, CaseIterable, Identifiable {
    case system, songti, kaiti
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: L10n.text("System")
        case .songti: L10n.text("Songti")
        case .kaiti: L10n.text("Kaiti")
        }
    }
    fileprivate func postScriptName(bold: Bool) -> String? {
        switch self {
        case .system: nil
        case .songti: bold ? "STSongti-SC-Bold" : "STSongti-SC-Regular"
        case .kaiti: bold ? "STKaitiSC-Bold" : "STKaitiSC-Regular"
        }
    }

    func platformFont(size: Double, bold: Bool) -> NovelPlatformFont {
        if let name = postScriptName(bold: bold), let font = NovelPlatformFont(name: name, size: size) { return font }
        if bold, let name = postScriptName(bold: false), let font = NovelPlatformFont(name: name, size: size) { return font }
        return NovelPlatformFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    /// The face for SwiftUI text, such as the scroll layout and the font buttons.
    func font(size: Double, bold: Bool = false) -> Font { Font(platformFont(size: size, bold: bold) as CTFont) }

    var isInstalled: Bool {
        guard let name = postScriptName(bold: false) else { return true }
        return NovelPlatformFont(name: name, size: 12) != nil
    }
}

/// Downloads the system's optional Chinese book faces on demand.
@MainActor @Observable final class NovelFonts {
    static let shared = NovelFonts()
    /// Changes as each font arrives.
    private(set) var generation = 0
    private(set) var downloading: Set<NovelFontChoice> = []

    func prepare(_ choice: NovelFontChoice) {
        guard !choice.isInstalled, !downloading.contains(choice) else { return }
        let names = [choice.postScriptName(bold: false), choice.postScriptName(bold: true)].compactMap { $0 }
        downloading.insert(choice)
        let descriptors = names.map { CTFontDescriptorCreateWithNameAndSize($0 as CFString, 0) } as CFArray
        CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors, nil) { state, _ in
            switch state {
            case .didFinish:
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        NovelFonts.shared.downloading.remove(choice)
                        NovelFonts.shared.generation += 1
                    }
                }
            default: break
            }
            return true
        }
    }
}

/// A chapter laid out in columns of one size, for the page layout. Each column is a TextKit text container, so a page
/// shows exactly the lines that fit and the next page starts at the next line.
@MainActor final class NovelPages {
    let chapter: Int
    let length: Int
    let columns: Int
    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private var containers: [NSTextContainer] = []
    /// The first character of each column.
    private var starts: [Int] = []

    init(chapter: Int, text: NSAttributedString, column: CGSize, columns: Int) {
        self.chapter = chapter
        self.columns = max(1, columns)
        length = text.length
        storage = NSTextStorage(attributedString: text)
        manager.allowsNonContiguousLayout = false
        manager.usesFontLeading = false
        storage.addLayoutManager(manager)
        let glyphs = manager.numberOfGlyphs
        while containers.count < 4000 {
            let container = NSTextContainer(size: column)
            container.lineFragmentPadding = 0
            manager.addTextContainer(container)
            let range = manager.glyphRange(for: container)
            if range.length == 0, !containers.isEmpty { manager.removeTextContainer(at: containers.count); break }
            containers.append(container)
            starts.append(manager.characterIndexForGlyph(at: range.location))
            if NSMaxRange(range) >= glyphs { break }
        }
    }

    /// Screens (one column, or two side by side on wide screens).
    var spreadCount: Int { max(1, (containers.count + columns - 1) / columns) }
    func spread(containing location: Int) -> Int {
        let column = (starts.lastIndex { $0 <= location }) ?? 0
        return min(spreadCount - 1, column / columns)
    }
    func location(ofSpread spread: Int) -> Int {
        let column = min(max(0, spread * columns), starts.count - 1)
        return starts.isEmpty ? 0 : starts[column]
    }
    func hasColumn(_ index: Int) -> Bool { containers.indices.contains(index) }

    /// Draws one column with its top-left corner at `origin`, in a flipped context.
    func draw(column index: Int, at origin: CGPoint) {
        guard containers.indices.contains(index) else { return }
        let range = manager.glyphRange(for: containers[index])
        manager.drawBackground(forGlyphRange: range, at: origin)
        manager.drawGlyphs(forGlyphRange: range, at: origin)
    }
}

/// One column of a chapter, drawn by TextKit.
struct NovelColumn: View {
    let pages: NovelPages
    let index: Int
    var body: some View { NovelColumnCanvas(pages: pages, index: index) }
}

#if os(macOS)
private struct NovelColumnCanvas: NSViewRepresentable {
    let pages: NovelPages
    let index: Int
    func makeNSView(context: Context) -> ColumnView { ColumnView() }
    func updateNSView(_ view: ColumnView, context: Context) {
        if view.pages !== pages || view.index != index { view.pages = pages; view.index = index; view.needsDisplay = true }
    }
    final class ColumnView: NSView {
        var pages: NovelPages?
        var index = 0
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { MainActor.assumeIsolated { pages?.draw(column: index, at: .zero) } }
    }
}
#else
private struct NovelColumnCanvas: UIViewRepresentable {
    let pages: NovelPages
    let index: Int
    func makeUIView(context: Context) -> ColumnView {
        let view = ColumnView()
        view.isOpaque = false
        view.backgroundColor = .clear
        view.contentMode = .redraw
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: ColumnView, context: Context) {
        if view.pages !== pages || view.index != index { view.pages = pages; view.index = index; view.setNeedsDisplay() }
    }
    final class ColumnView: UIView {
        var pages: NovelPages?
        var index = 0
        override func draw(_ rect: CGRect) { MainActor.assumeIsolated { pages?.draw(column: index, at: .zero) } }
    }
}
#endif
