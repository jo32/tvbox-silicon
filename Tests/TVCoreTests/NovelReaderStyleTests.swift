import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import TVCore

/// #1007: chapters shown in the script the reader picks, phrases converted as phrases.
@Test func novelScriptConvertsBetweenSimplifiedAndTraditional() {
    #expect(NovelScript.traditional.convert("头发很长，后来我们干杯了") == "頭髮很長，後來我們乾杯了")
    #expect(NovelScript.simplified.convert("頭髮很長，後來我們乾杯了") == "头发很长，后来我们干杯了")
    #expect(NovelScript.original.convert("头发") == "头发")

    let content = NovelContent(title: "第一章 归来", paragraphs: ["他说：“这里发生了什么？”", "", "联系我们"])
    let converted = NovelScript.traditional.convert(content)
    #expect(converted.title == "第一章 歸來")
    #expect(converted.paragraphs == ["他說：“這裡發生了什麼？”", "", "聯繫我們"])
    #expect(NovelScript.original.convert(content) == content)

    // Titles in one pass, the same as one by one; a title holding the separator still comes back in its place.
    let titles = ["第一章 归来", "第二章 后会有期", "", "第三章 \u{1E}发"]
    #expect(NovelScript.traditional.convert(titles) == titles.map(NovelScript.traditional.convert))
}

/// #1265: a picked photo is kept as one upright JPEG no larger than the reader draws.
@Test func novelBackgroundImageIsDownscaledToAJPEG() throws {
    let context = try #require(CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
    let png = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    let jpeg = try #require(NovelBackgroundImage.prepare(png as Data))
    let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
    let image = try #require(NovelBackgroundImage.decode(jpeg))
    #expect(image.width == 2048 && image.height == 1536)
    #expect(NovelBackgroundImage.prepare(Data("not an image".utf8)) == nil)
}
