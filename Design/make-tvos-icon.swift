// Renders the tvOS app icon layers and top shelf images from Design/yingxia-icon.png.
// Usage: swift Design/make-tvos-icon.swift <Assets.xcassets>
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let brand = root.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
let source = NSImage(contentsOfFile: "Design/yingxia-icon.png")!.cgImage(forProposedRect: nil, context: nil, hints: nil)!

/// The artwork's own corner colour, so the back layer continues it.
let edge: (CGFloat, CGFloat, CGFloat) = {
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(source.cropping(to: CGRect(x: 0, y: 0, width: 24, height: 24))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let p = context.data!.assumingMemoryBound(to: UInt8.self)
    return (CGFloat(p[0]) / 255, CGFloat(p[1]) / 255, CGFloat(p[2]) / 255)
}()

enum Layer { case back, front, flat }

func render(width: Int, height: Int, layer: Layer, glyph: CGFloat) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let size = CGSize(width: width, height: height)
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    if layer != .front {
        context.setFillColor(CGColor(srgbRed: edge.0, green: edge.1, blue: edge.2, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        // A soft blue glow behind the mark, as in the artwork.
        let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.05, green: 0.25, blue: 0.85, alpha: 0.55), CGColor(srgbRed: 0.05, green: 0.25, blue: 0.85, alpha: 0)] as CFArray, locations: [0, 1])!
        context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: max(size.width, size.height) * 0.55, options: [])
    }
    if layer != .back {
        // The square artwork, its own background faded out at the edges so only the mark stands out.
        let side = size.height * glyph
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let mask = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray, locations: [0, 0.62, 1])!
        mask.drawRadialGradient(fade, startCenter: center, startRadius: 0, endCenter: center, endRadius: side / 2, options: [])
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: size), mask: mask.makeImage()!)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        context.restoreGState()
    }
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    let url = brand.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}
func json(_ object: Any, _ path: String) {
    write(try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), path)
}
let info = ["author": "xcode", "version": 1] as [String: Any]

// Icon image stacks: a back and a front layer, so the system can add parallax.
for (name, width, height, scales) in [("App Icon - Small", 400, 240, [1, 2]), ("App Icon - Large", 1280, 768, [1])] {
    let stack = "\(name).imagestack"
    json(["info": info, "layers": [["filename": "Front.imagestacklayer"], ["filename": "Back.imagestacklayer"]]], "\(stack)/Contents.json")
    for (layerName, layer) in [("Front", Layer.front), ("Back", Layer.back)] {
        let dir = "\(stack)/\(layerName).imagestacklayer"
        json(["info": info], "\(dir)/Contents.json")
        var images: [[String: String]] = []
        for scale in scales {
            let file = "\(layerName.lowercased())@\(scale)x.png"
            write(render(width: width * scale, height: height * scale, layer: layer, glyph: 0.98), "\(dir)/Content.imageset/\(file)")
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
json(["info": info], "../Contents.json")
print("Wrote \(brand.path)")
