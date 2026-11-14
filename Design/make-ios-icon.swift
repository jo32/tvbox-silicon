// Renders the dark and tinted iOS app icons from the light one, for the Classic icon (the app's own before Aurora).
// Usage: swift Design/make-ios-icon.swift Config/iOS/Assets.xcassets/AppIcon-Classic.appiconset
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let source = NSImage(contentsOf: root.appendingPathComponent("AppIcon.png"))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let width = source.width, height = source.height

/// The light icon's pixels as RGBA bytes.
let pixels: [UInt8] = {
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
    return data
}()

func smoothstep(_ low: Double, _ high: Double, _ x: Double) -> Double {
    let t = min(max((x - low) / (high - low), 0), 1)
    return t * t * (3 - 2 * t)
}

/// How much of a pixel belongs to the mark. The background is deep blue with little red or green,
/// while the aqua glass and its teal glow are bright in green, so red and green key the mark out.
func coverage(_ r: Double, _ g: Double) -> Double {
    smoothstep(0.16, 0.55, max(r, g))
}

enum Appearance { case dark, tinted }

func render(_ appearance: Appearance) -> Data {
    // The tinted icon is opaque, so it is written without an alpha channel.
    let alpha = appearance == .dark ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    var out = [UInt8](repeating: 0, count: pixels.count)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
        let a = coverage(r, g)
        switch appearance {
        case .dark:
            // The mark on a transparent background; the system draws its dark backdrop behind it.
            for (k, c) in [r, g, b].enumerated() { out[i + k] = UInt8((c * a * 255).rounded()) }
            out[i + 3] = UInt8((a * 255).rounded())
        case .tinted:
            // A grayscale mark on black; the system tints it by brightness.
            let gray = UInt8(((0.2126 * r + 0.7152 * g + 0.0722 * b) * a * 255).rounded())
            (out[i], out[i + 1], out[i + 2], out[i + 3]) = (gray, gray, gray, 255)
        }
    }
    let context = CGContext(data: &out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}

try! render(.dark).write(to: root.appendingPathComponent("AppIcon-Dark.png"))
try! render(.tinted).write(to: root.appendingPathComponent("AppIcon-Tinted.png"))
print("Wrote \(root.path)")
