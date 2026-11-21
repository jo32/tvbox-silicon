import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Simplified and Traditional Chinese in the novel reader (#1007): a chapter is shown in the script the reader picks,
/// converted once when it arrives, never while pages turn. ICU's transforms convert phrases (头发 → 頭髮, 乾杯 → 干杯),
/// about 2 ms for a 10,000-character chapter.
public enum NovelScript: String, CaseIterable, Sendable {
    case original = "", traditional, simplified

    private var transform: StringTransform? {
        switch self {
        case .original: nil
        case .traditional: StringTransform("Hans-Hant")
        case .simplified: StringTransform("Hant-Hans")
        }
    }

    public func convert(_ text: String) -> String {
        guard let transform else { return text }
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    /// Many short texts in one pass (a chapter's paragraphs, a book's chapter titles): one transform call is far cheaper
    /// than thousands. A text holding the separator is converted on its own.
    public func convert(_ texts: [String]) -> [String] {
        guard transform != nil, !texts.isEmpty else { return texts }
        let separator: Character = "\u{1E}"
        guard !texts.contains(where: { $0.contains(separator) }) else { return texts.map(convert) }
        let parts = convert(texts.joined(separator: String(separator))).split(separator: separator, omittingEmptySubsequences: false)
        return parts.count == texts.count ? parts.map(String.init) : texts.map(convert)
    }

    public func convert(_ content: NovelContent) -> NovelContent {
        guard transform != nil else { return content }
        let converted = convert([content.title] + content.paragraphs)
        return NovelContent(title: converted[0], paragraphs: Array(converted.dropFirst()))
    }
}

/// The picture a reader can put behind the page (#1265), kept as one downscaled JPEG: a 48-megapixel photo would
/// otherwise be decoded at full size behind every page.
public enum NovelBackgroundImage {
    public static let maxPixels = 2048

    public static var file: URL { NovelLibrary.root.appending(path: "reader-background.jpg") }

    /// The picked image's data (JPEG, HEIC, PNG…) as a JPEG no larger than `maxPixels` on its longer side, upright.
    public static func prepare(_ data: Data, maxPixels: Int = maxPixels) -> Data? {
        guard let image = decode(data, maxPixels: maxPixels) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Decodes image data at most `maxPixels` on its longer side, ready to draw (decoded now, not on first draw).
    public static func decode(_ data: Data, maxPixels: Int = maxPixels) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The saved picture, decoded; nil when none is set.
    public static func load() -> CGImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return decode(data)
    }

    public static func save(_ jpeg: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: file, options: .atomic)
    }

    public static func remove() { try? FileManager.default.removeItem(at: file) }
}
