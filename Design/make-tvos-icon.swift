// Renders the Apple TV app icons and the top shelf images from the app's icons on iPhone, iPad and Mac
// (Config/iOS/Assets.xcassets/AppIcon[-<name>].appiconset/AppIcon.png, made by Design/make-app-icons.swift).
//
// Usage (from the repository root): swift Design/make-tvos-icon.swift Config/tvOS/Assets.xcassets
//
// - The app's own icon (Pocket) and the top shelf images go in "App Icon & Top Shelf Image.brandassets".
// - Each alternate the iPhone has (AppIcon-<name>.appiconset) becomes AppIcon-<name>.imagestack, the icon Settings ›
//   App Icon switches to on Apple TV. The top shelf image is the app's, whichever icon is in use, so it stays Pocket.
//
// The icon is one square, opaque picture, while an Apple TV icon is wider (5:3) and a stack of layers the system tilts
// apart when the icon is focused. So:
// - Back: the picture's background colours, measured at its side edges, carried across the width, so the square
//   continues to the left and right.
// - Front: the square itself, as tall as the icon, its left and right edges faded into the back layer.
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
let iosIcons = URL(fileURLWithPath: "Config/iOS/Assets.xcassets")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// One square icon picture and the colours of its back layer.
struct Icon {
    let source: CGImage
    let side: Int
    /// The colour of each row of the back layer (top row first).
    let edgeRows: [(Double, Double, Double)]

    /// `oneTone`: the background is one colour, the top one. For pictures whose subject reaches the lower edges (the
    /// animals), where a second colour measured there would be the subject's, carried across as a band.
    init(_ url: URL, oneTone: Bool = false) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { fatalError("Can't read \(url.path)") }
        self.source = source
        side = source.width
        edgeRows = Icon.edgeRows(source, oneTone: oneTone)
    }

    /// The picture's background can be two-tone (MediaPocketPurple: purple above its pocket, lavender below), so it is
    /// measured from thin strips at the left and right edges: the top colour near the top, the bottom one near the
    /// foot, and the row where the left edge turns from one to the other, with a soft step between. Rows taken straight
    /// from the edges would carry streaks of whatever touches them.
    private static func edgeRows(_ source: CGImage, oneTone: Bool) -> [(Double, Double, Double)] {
        let side = source.width
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        let strip = max(2, side / 64)
        func mean(rows: Range<Int>, columns: [Int]) -> (Double, Double, Double) {
            var sum = (0.0, 0.0, 0.0)
            for y in rows { for x in columns {
                let i = (y * side + x) * 4
                sum.0 += Double(data[i]); sum.1 += Double(data[i + 1]); sum.2 += Double(data[i + 2])
            } }
            let n = Double(rows.count * columns.count)
            return (sum.0 / n, sum.1 / n, sum.2 / n)
        }
        func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) }
        let edges = Array(0..<strip) + Array((side - strip)..<side)
        let top = mean(rows: (side * 2 / 100)..<(side * 15 / 100), columns: edges)
        if oneTone { return Array(repeating: top, count: side) }
        let bottom = mean(rows: (side * 80 / 100)..<(side * 97 / 100), columns: edges)
        let left = Array(0..<strip)
        let split = ((side / 5)..<(side * 4 / 5)).first { y in
            let c = mean(rows: y..<(y + 1), columns: left)
            return distance(c, bottom) < distance(c, top)
        } ?? side / 2
        let soft = Double(side) * 0.04
        return (0..<side).map { y in
            let t = min(1, max(0, (Double(y - split) + soft / 2) / soft))
            let s = t * t * (3 - 2 * t)
            return (top.0 + (bottom.0 - top.0) * s, top.1 + (bottom.1 - top.1) * s, top.2 + (bottom.2 - top.2) * s)
        }
    }
}

enum Layer { case back, front, flat }

/// A `width` × `height` layer of `icon` with the square centred, its side `glyph` × the height.
func render(_ icon: Icon, width: Int, height: Int, layer: Layer, glyph: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let squareSide = CGFloat(height) * glyph
    let square = CGRect(x: (CGFloat(width) - squareSide) / 2, y: (CGFloat(height) - squareSide) / 2, width: squareSide, height: squareSide)
    if layer != .front {
        // Row by row; CG's origin is at the foot, the rows' at the top. Above and below a square shorter than the
        // layer, the first and last rows carry on.
        for y in 0..<height {
            let row = Int(((CGFloat(height - 1 - y) + 0.5 - square.minY) / squareSide * CGFloat(icon.side)).rounded(.down))
            let c = icon.edgeRows[min(max(row, 0), icon.side - 1)]
            context.setFillColor(CGColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
    }
    if layer != .back {
        // The square, its outer eighth on each side fading out.
        let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                              colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                              locations: [0, 0.125, 0.875, 1])!
        mask.clip(to: square)
        mask.drawLinearGradient(fade, start: CGPoint(x: square.minX, y: 0), end: CGPoint(x: square.maxX, y: 0), options: [])
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: mask.makeImage()!)
        context.interpolationQuality = .high
        context.draw(icon.source, in: square)
        context.restoreGState()
    }
    return context.makeImage()!
}

func png(_ image: CGImage) -> Data { NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])! }
func write(_ data: Data, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}
func json(_ object: Any, _ url: URL) {
    write(try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), url)
}
let info = ["author": "xcode", "version": 1] as [String: Any]

/// An icon image stack: a back and a front layer, so the system can add parallax.
func writeStack(_ icon: Icon, _ stack: URL, width: Int, height: Int, scales: [Int]) {
    try? FileManager.default.removeItem(at: stack)
    json(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]], stack.appendingPathComponent("Contents.json"))
    for (layerName, layer) in [("Front", Layer.front), ("Back", Layer.back)] {
        let dir = stack.appendingPathComponent("\(layerName).imagestacklayer")
        json(["info": info], dir.appendingPathComponent("Contents.json"))
        var images: [[String: String]] = []
        for scale in scales {
            let file = "\(layerName.lowercased())@\(scale)x.png"
            write(png(render(icon, width: width * scale, height: height * scale, layer: layer, glyph: 1)), dir.appendingPathComponent("Content.imageset/\(file)"))
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        }
        json(["images": images, "info": info], dir.appendingPathComponent("Content.imageset/Contents.json"))
    }
}

// The app's own icon and the top shelf images.
let pocket = Icon(iosIcons.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))
for (name, width, height, scales) in [("App Icon - Small", 400, 240, [1, 2]), ("App Icon - Large", 1280, 768, [1])] {
    writeStack(pocket, brand.appendingPathComponent("\(name).imagestack"), width: width, height: height, scales: scales)
}
// Top shelf images are flat.
for (name, width, height) in [("Top Shelf Image", 1920, 720), ("Top Shelf Image Wide", 2320, 720)] {
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let file = "top-shelf@\(scale)x.png"
        write(png(render(pocket, width: width * scale, height: height * scale, layer: .flat, glyph: 1)), brand.appendingPathComponent("\(name).imageset/\(file)"))
        images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
    }
    json(["images": images, "info": info], brand.appendingPathComponent("\(name).imageset/Contents.json"))
}
json(["assets": [
    ["filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
], "info": info], brand.appendingPathComponent("Contents.json"))
json(["info": info], root.appendingPathComponent("Contents.json"))
print("Wrote \(brand.path)")

// The alternates, at the Home Screen size only (the App Store's large icon is the app's own). An alternate on Apple TV
// is a top-level image stack, not part of the brand assets.
let alternates = try! FileManager.default.contentsOfDirectory(atPath: iosIcons.path)
    .filter { $0.hasPrefix("AppIcon-") && $0.hasSuffix(".appiconset") }.sorted()
for set in alternates {
    let name = (set as NSString).deletingPathExtension
    let icon = Icon(iosIcons.appendingPathComponent("\(set)/AppIcon.png"),
                    oneTone: ["AppIcon-SealMusic", "AppIcon-ShibaManga", "AppIcon-CatCinema", "AppIcon-AnimalTrio", "AppIcon-Panda"].contains(name))
    writeStack(icon, root.appendingPathComponent("\(name).imagestack"), width: 400, height: 240, scales: [1, 2])
    print("Wrote \(name)")
}
