// Builds the app icons that Settings › App Icon offers (App/AppIconChoice.swift) from the "Tobe / 10 Color Themes"
// delivery: a folder of NN-name/NN-name-1024.png, opaque full-square masters.
//
// Usage (from the repository root): swift Design/make-app-icons.swift <themes folder>
//
// Writes:
// - Config/iOS/Assets.xcassets/AppIcon-<Name>.appiconset: every theme, as alternate icons. The app's own icon,
//   Classic (Config/iOS/Assets.xcassets/AppIcon.appiconset and the Mac's AppIcon.appiconset), is left as it is; its
//   dark and tinted versions come from Design/make-ios-icon.swift.
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

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift Design/make-app-icons.swift <themes folder>\n".data(using: .utf8)!)
    exit(2)
}
let delivery = URL(fileURLWithPath: CommandLine.arguments[1])
let iosCatalog = URL(fileURLWithPath: "Config/iOS/Assets.xcassets")
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
    let set = "AppIcon-\(theme.name)"
    iosIconSet(master, at: iosCatalog.appendingPathComponent("\(set).appiconset"))
    artSet(master, name: theme.name)
    print("\(theme.name) → \(set)")
}

// The app's own icon: artwork from its iOS set, which this script leaves alone.
artSet(load(iosCatalog.appendingPathComponent("AppIcon.appiconset/AppIcon.png")), name: "Classic")
print("Classic → AppIconArt-Classic")
