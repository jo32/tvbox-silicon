// Builds the app icons that Settings › App Icon offers (App/AppIconChoice.swift) from the "Tobe / 10 Color Themes"
// delivery: a folder of NN-name/NN-name-1024.png, opaque full-square masters.
//
// Usage (from the repository root): swift Design/make-app-icons.swift <themes folder>
//
// Writes:
// - Config/iOS/Assets.xcassets/AppIcon.appiconset: Aurora, the app's own icon on iPhone and iPad.
// - Config/iOS/Assets.xcassets/AppIcon-<Name>.appiconset: the other themes, as alternate icons. AppIcon-Classic, the
//   icon before Aurora, is kept as it is (its dark and tinted versions come from Design/make-ios-icon.swift).
// - Config/macOS/Assets.xcassets/AppIcon.appiconset: Aurora on the Mac's rounded plate with its margin and shadow.
// - Config/AppIcons.xcassets/AppIconArt-<Name>.imageset: 512 px artwork of every icon, Classic too, for the picker
//   and for the Mac, which draws the chosen one on the same plate as its Dock icon (AppIcons.dockImage).
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Folder in the delivery → icon name. Keep in step with AppIconChoice.
let themes: [(folder: String, name: String)] = [
    ("01-porcelain", "Porcelain"), ("02-obsidian", "Obsidian"), ("03-azure", "Azure"), ("04-aurora", "Aurora"),
    ("05-daybreak", "Daybreak"), ("06-iris", "Iris"), ("07-lagoon", "Lagoon"), ("08-rose-quartz", "RoseQuartz"),
    ("09-citrus", "Citrus"), ("10-cosmic", "Cosmic"),
]
/// The app's own icon; every other one is an alternate.
let primary = "Aurora"

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift Design/make-app-icons.swift <themes folder>\n".data(using: .utf8)!)
    exit(2)
}
let delivery = URL(fileURLWithPath: CommandLine.arguments[1])
let iosCatalog = URL(fileURLWithPath: "Config/iOS/Assets.xcassets")
let macCatalog = URL(fileURLWithPath: "Config/macOS/Assets.xcassets")
let artCatalog = URL(fileURLWithPath: "Config/AppIcons.xcassets")
let manager = FileManager.default

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Can't read \(url.path)")
    }
    return image
}

func write(_ image: CGImage, to url: URL) {
    try! manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Can't write \(url.path)") }
}

func writeJSON(_ object: Any, to url: URL) {
    try! manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! (data + Data("\n".utf8)).write(to: url)
}

/// `image` drawn at `size` px, opaque (the App Store refuses icons with alpha) unless `alpha`.
func render(size: Int, alpha: Bool = false, _ draw: (CGContext) -> Void) -> CGImage {
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    context.interpolationQuality = .high
    draw(context)
    return context.makeImage()!
}

func scaled(_ image: CGImage, to size: Int) -> CGImage {
    render(size: size) { $0.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size)) }
}

/// The Mac's icon plate, as Apple's template and the icon before Aurora have it: an 824 pt rounded square in a
/// 1024 pt canvas, corner radius 185, with a soft shadow under it. AppIcons.dockImage draws the same.
func macPlate(_ art: CGImage) -> CGImage {
    render(size: 1024, alpha: true) { context in
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let plate = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(plate)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
        context.addPath(plate)
        context.clip()
        context.draw(art, in: body)
    }
}

func iosIconSet(_ image: CGImage, at folder: URL) {
    if manager.fileExists(atPath: folder.path) { try! manager.removeItem(at: folder) }
    write(scaled(image, to: 1024), to: folder.appendingPathComponent("AppIcon.png"))
    writeJSON([
        "images": [["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
        "info": ["author": "xcode", "version": 1],
    ], to: folder.appendingPathComponent("Contents.json"))
}

func artSet(_ image: CGImage, name: String) {
    let folder = artCatalog.appendingPathComponent("AppIconArt-\(name).imageset")
    if manager.fileExists(atPath: folder.path) { try! manager.removeItem(at: folder) }
    write(scaled(image, to: 512), to: folder.appendingPathComponent("art.png"))
    writeJSON([
        "images": [["filename": "art.png", "idiom": "universal"]],
        "info": ["author": "xcode", "version": 1],
    ], to: folder.appendingPathComponent("Contents.json"))
}

writeJSON(["info": ["author": "xcode", "version": 1]], to: artCatalog.appendingPathComponent("Contents.json"))

for theme in themes {
    let master = load(delivery.appendingPathComponent(theme.folder).appendingPathComponent("\(theme.folder)-1024.png"))
    guard master.width == 1024, master.height == 1024 else { fatalError("\(theme.folder) is not 1024 × 1024") }
    let set = theme.name == primary ? "AppIcon" : "AppIcon-\(theme.name)"
    iosIconSet(master, at: iosCatalog.appendingPathComponent("\(set).appiconset"))
    artSet(master, name: theme.name)
    if theme.name == primary {
        let plate = macPlate(master)
        let folder = macCatalog.appendingPathComponent("AppIcon.appiconset")
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let size = points * scale
                let image = render(size: size, alpha: true) { $0.draw(plate, in: CGRect(x: 0, y: 0, width: size, height: size)) }
                write(image, to: folder.appendingPathComponent("icon_\(points)x\(points)@\(scale)x.png"))
            }
        }
    }
    print("\(theme.name) → \(set)")
}

// The icon before Aurora: artwork from its iOS set, which this script leaves alone.
artSet(load(iosCatalog.appendingPathComponent("AppIcon-Classic.appiconset/AppIcon.png")), name: "Classic")
print("Classic → AppIconArt-Classic")
