import CoreGraphics
import Foundation
import Testing
@testable import TVCore

/// 禁漫天堂 sends its pages cut into bands in reverse order, and its `modifyImage` script puts them back. The
/// reader loads several pages at once; each one must come out whole, not as stacked bands (#836).
@Test func mangaPagesUnscrambleWhileSeveralLoadAtOnce() async throws {
    let key = "unscrambletest"
    // The 禁漫天堂 script's unscrambling, with a fixed number of bands.
    let code = """
    class UnscrambleTest extends ComicSource {
        name = "Unscramble Test"
        key = "\(key)"
        version = "1.0.0"
        minAppVersion = "1.0.0"
        url = ""
        comic = {
            onImageLoad: (url, comicId, epId) => ({
                modifyImage: `
                    let modifyImage = (image) => {
                        const num = 4
                        let blockSize = Math.floor(image.height / num)
                        let remainder = image.height % num
                        let res = Image.empty(image.width, image.height)
                        let y = 0
                        for (let i = num - 1; i >= 0; i--) {
                            let height = blockSize + (i !== num - 1 ? 0 : remainder)
                            res.fillImageRangeAt(0, y, image, 0, i * blockSize, image.width, height)
                            y += height
                        }
                        return res
                    }
                `
            })
        }
    }
    """
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("manga-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let session = try await MangaRuntime.start(key: key, code: code, revision: "", profile: folder)
    defer { session.script.close() }
    let answer = await session.script.evaluate("__venera.imageConfig('image', 'https://example.com/1.jpg', '1', '300000').then(JSON.stringify)", within: 10)
    let config = try #require(answer["value"]?.string.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
    let value = try #require(config["value"] as? [String: Any], "\(config)")
    #expect(value["modifyImage"] as? Bool == true)
    let id = try #require((value["id"] as? NSNumber)?.intValue)

    let pages = 8
    let runtime = MangaRuntime()
    let results = try await withThrowingTaskGroup(of: (Int, [[UInt8]]).self) { group in
        for number in 0..<pages {
            let scrambled = UnscramblePage.make(number, scrambled: true)
            group.addTask { (number, UnscramblePage.rows(try await runtime.modify(in: session, config: id, image: scrambled))) }
        }
        return try await group.reduce(into: [Int: [[UInt8]]]()) { $0[$1.0] = $1.1 }
    }
    for number in 0..<pages {
        #expect(results[number] == UnscramblePage.rows(UnscramblePage.make(number, scrambled: false)), "page \(number) is not put back together")
    }
}

/// Test pages: 4 bands of 10 rows, every row a different shade of red, and the page's number in green.
private enum UnscramblePage {
    static let width = 6, height = 40

    static func make(_ number: Int, scrambled: Bool) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let source = scrambled ? (3 - row / 10) * 10 + row % 10 : row
            for column in 0..<width {
                let at = (row * width + column) * 4
                pixels[at] = UInt8(source * 6); pixels[at + 1] = UInt8(number * 20); pixels[at + 2] = 0
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// Each row's red and green.
    static func rows(_ image: CGImage) -> [[UInt8]] {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<height).map { row in [pixels[row * width * 4], pixels[row * width * 4 + 1]] }
    }
}
