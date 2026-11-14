// Renders the Apple TV app icon layers, the top shelf images and the in-app mark from Aurora, the app's icon on
// iPhone, iPad and Mac (Config/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png, made by Design/make-app-icons.swift).
//
// Usage (from the repository root): swift Design/make-tvos-icon.swift Config/tvOS/Assets.xcassets
//
// Aurora is one flat, opaque picture: three translucent blades on a pale lavender background. An Apple TV icon is a
// stack of layers that the system tilts apart when the icon is focused, so the picture is taken apart here:
// - Back: the background alone. Its colour depends only on the distance from the centre (a soft radial wash), so it is
//   measured ring by ring from the pixels that are clearly background, and drawn at any size and aspect from that.
// - Front: the blades alone. Each pixel's opacity comes from how far it is from the background behind it, and its
//   colour is solved so that front over back gives the original pixel again. At rest the icon looks exactly like Aurora.
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
let sourceURL = URL(fileURLWithPath: "Config/iOS/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// RGBA8 pixels, premultiplied (opaque here).
struct Pixels {
    var width: Int, height: Int, data: [UInt8]
    init(width: Int, height: Int) { self.width = width; self.height = height; data = [UInt8](repeating: 0, count: width * height * 4) }
    init(_ image: CGImage) {
        self.init(width: image.width, height: image.height)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
    var image: CGImage {
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { fatalError("Can't read \(sourceURL.path)") }
let master = Pixels(sourceImage)
let side = master.width
let centre = Double(side) / 2

// 1. The background's colour by distance from the centre. Start from the corners' colour, take the pixels close to it
// as background, average them per one-pixel ring, then fill rings with no background pixels from their neighbours.
func colour(_ p: Pixels, _ i: Int) -> (Double, Double, Double) { (Double(p.data[i * 4]), Double(p.data[i * 4 + 1]), Double(p.data[i * 4 + 2])) }
func distance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double { max(abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2)) }
let corner = colour(master, 2 * side + 2)
let rings = Int(centre * 1.5) + 2
var sums = [(Double, Double, Double, Double)](repeating: (0, 0, 0, 0), count: rings)
for y in 0..<side {
    for x in 0..<side {
        let c = colour(master, y * side + x)
        guard distance(c, corner) < 14 else { continue }
        let r = Int(hypot(Double(x) + 0.5 - centre, Double(y) + 0.5 - centre))
        sums[r].0 += c.0; sums[r].1 += c.1; sums[r].2 += c.2; sums[r].3 += 1
    }
}
var ring = [(Double, Double, Double)?](repeating: nil, count: rings)
for r in 0..<rings where sums[r].3 >= 4 { ring[r] = (sums[r].0 / sums[r].3, sums[r].1 / sums[r].3, sums[r].2 / sums[r].3) }
let known = (0..<rings).filter { ring[$0] != nil }
guard let first = known.first, let last = known.last else { fatalError("No background found in \(sourceURL.path)") }
for r in 0..<rings where ring[r] == nil {
    if r < first { ring[r] = ring[first] } else if r > last { ring[r] = ring[last] } else {
        let below = known.last { $0 < r }!, above = known.first { $0 > r }!
        let t = Double(r - below) / Double(above - below), a = ring[below]!, b = ring[above]!
        ring[r] = (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
}
// Smooth the profile so the back layer has no rings.
var profile = ring.map { $0! }
for _ in 0..<3 {
    profile = (0..<rings).map { r in
        let window = max(0, r - 6)...min(rings - 1, r + 6)
        let n = Double(window.count)
        return (window.reduce(0) { $0 + profile[$1].0 } / n, window.reduce(0) { $0 + profile[$1].1 } / n, window.reduce(0) { $0 + profile[$1].2 } / n)
    }
}
/// The background at `r` master pixels from the centre.
func background(_ r: Double) -> (Double, Double, Double) {
    let r = min(max(r, 0), Double(rings - 1))
    let i = Int(r), j = min(i + 1, rings - 1), t = r - Double(i)
    let a = profile[i], b = profile[j]
    return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

// 2. The blades: opacity from the distance to the background (soft below `solid`), colour solved from
// pixel = alpha * blade + (1 - alpha) * background.
let faint = 5.0, solid = 70.0
var blades = Pixels(width: side, height: side)
for y in 0..<side {
    for x in 0..<side {
        let i = y * side + x
        let p = colour(master, i)
        let b = background(hypot(Double(x) + 0.5 - centre, Double(y) + 0.5 - centre))
        let d = distance(p, b)
        let alpha = min(1, max(0, (d - faint) / (solid - faint)))
        guard alpha > 0 else { continue }
        func channel(_ p: Double, _ b: Double) -> UInt8 {
            let f = min(255, max(0, b + (p - b) / alpha))
            return UInt8((f * alpha).rounded())
        }
        blades.data[i * 4] = channel(p.0, b.0)
        blades.data[i * 4 + 1] = channel(p.1, b.1)
        blades.data[i * 4 + 2] = channel(p.2, b.2)
        blades.data[i * 4 + 3] = UInt8((alpha * 255).rounded())
    }
}
let bladesImage = blades.image

enum Layer { case back, front, flat }

/// A `width` × `height` layer with Aurora's square centred, its side `glyph` × the height.
func render(width: Int, height: Int, layer: Layer, glyph: Double) -> Data {
    let squareSide = Double(height) * glyph
    let scale = Double(side) / squareSide
    var canvas = Pixels(width: width, height: height)
    if layer != .front {
        for y in 0..<height {
            for x in 0..<width {
                let r = hypot(Double(x) + 0.5 - Double(width) / 2, Double(y) + 0.5 - Double(height) / 2) * scale
                let c = background(r), i = (y * width + x) * 4
                canvas.data[i] = UInt8(c.0.rounded()); canvas.data[i + 1] = UInt8(c.1.rounded()); canvas.data[i + 2] = UInt8(c.2.rounded())
                canvas.data[i + 3] = 255
            }
        }
    }
    let image: CGImage = canvas.data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if layer != .back {
            context.interpolationQuality = .high
            context.draw(bladesImage, in: CGRect(x: (Double(width) - squareSide) / 2, y: (Double(height) - squareSide) / 2,
                                                 width: squareSide, height: squareSide))
        }
        return context.makeImage()!
    }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String, in folder: URL = brand) {
    let url = folder.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}
func json(_ object: Any, _ path: String, in folder: URL = brand) {
    write(try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), path, in: folder)
}
let info = ["author": "xcode", "version": 1] as [String: Any]

// Icon image stacks: a back and a front layer, so the system can add parallax. The blades stay inside the icon's
// safe zone, since the focused icon grows and the front layer moves.
for (name, width, height, scales) in [("App Icon - Small", 400, 240, [1, 2]), ("App Icon - Large", 1280, 768, [1])] {
    let stack = "\(name).imagestack"
    json(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]], "\(stack)/Contents.json")
    for (layerName, layer) in [("Front", Layer.front), ("Back", Layer.back)] {
        let dir = "\(stack)/\(layerName).imagestacklayer"
        json(["info": info], "\(dir)/Contents.json")
        var images: [[String: String]] = []
        for scale in scales {
            let file = "\(layerName.lowercased())@\(scale)x.png"
            write(render(width: width * scale, height: height * scale, layer: layer, glyph: 1.0), "\(dir)/Content.imageset/\(file)")
            images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
        }
        json(["images": images, "info": info], "\(dir)/Content.imageset/Contents.json")
    }
}

// Top shelf images are flat.
for (name, width, height) in [("Top Shelf Image", 1920, 720), ("Top Shelf Image Wide", 2320, 720)] {
    var images: [[String: String]] = []
    for scale in [1, 2] {
        let file = "top-shelf@\(scale)x.png"
        write(render(width: width * scale, height: height * scale, layer: .flat, glyph: 0.9), "\(name).imageset/\(file)")
        images.append(["filename": file, "idiom": "tv", "scale": "\(scale)x"])
    }
    json(["images": images, "info": info], "\(name).imageset/Contents.json")
}

json(["assets": [
    ["filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"],
    ["filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"],
    ["filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"],
    ["filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"],
], "info": info], "Contents.json")

// The mark inside the app (AppMark: Settings, the Watch Now welcome, the update sheet): Aurora itself, 512 px.
let mark: Data = {
    let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: 512, height: 512))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}()
write(mark, "AppMark.imageset/app-mark.png", in: root)
json(["images": [["filename": "app-mark.png", "idiom": "universal"]], "info": info], "AppMark.imageset/Contents.json", in: root)
json(["info": info], "Contents.json", in: root)
print("Wrote \(brand.path) and AppMark")
