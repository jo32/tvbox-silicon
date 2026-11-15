// Builds the app icons that Settings › App Icon offers (App/AppIcons.swift) from two deliveries, each optional:
// - --set: "iOS App Icons PNG Set", whose 02_1024x1024_FullBleed_PNG/NN_Name_1024x1024.png are opaque full-square
//   masters. Its MediaPocketPurple is the app's own icon on every platform.
// - --themes: "Tobe / 10 Color Themes", a folder of NN-name/NN-name-1024.png, opaque full-square masters.
//
// Usage (from the repository root): swift Design/make-app-icons.swift [--set <folder>] [--themes <folder>]
// Then run Design/make-tvos-icon.swift, which draws the Apple TV icon from the iOS one.
//
// Writes:
// - Config/iOS/Assets.xcassets/AppIcon.appiconset and Config/macOS/Assets.xcassets/AppIcon.appiconset: the app's own
//   icon; on the Mac on its rounded plate with a margin and a shadow, as macOS 15 and earlier draw icons as they are.
// - Config/iOS/Assets.xcassets/AppIcon-<Name>.appiconset: every other icon, as alternate icons. Classic, the icon
//   before MediaPocketPurple (AppIcon-Classic), is left as it is; its dark and tinted versions come from
//   Design/make-ios-icon.swift.
// - Config/AppIcons.xcassets/AppIconArt-<Name>.imageset: 512 px artwork of every icon, Classic too, for the picker
//   and for the Mac, which draws the chosen one on the same plate as its Dock icon (AppIcons.dockImage).
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Folder in the Tobe delivery → icon name. Keep in step with AppIconChoice.
let themes: [(folder: String, name: String)] = [
    ("01-porcelain", "Porcelain"), ("02-obsidian", "Obsidian"), ("03-azure", "Azure"), ("04-aurora", "Aurora"),
    ("05-daybreak", "Daybreak"), ("06-iris", "Iris"), ("07-lagoon", "Lagoon"), ("08-rose-quartz", "RoseQuartz"),
    ("09-citrus", "Citrus"), ("10-cosmic", "Cosmic"),
]
/// Icons in the PNG set, by their file name's middle part, which is also the icon name. Keep in step with AppIconChoice.
let setIcons = ["01_MediaLayers", "02_MediaPocketPurple", "03_PlayTriangle", "04_MediaPocketGray", "05_SealMusic",
                "06_ShibaManga", "07_CatCinema", "08_AnimalTrio"]
/// The app's own icon; every other one is an alternate.
let primary = "MediaPocketPurple"

var options: [String: URL] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard ["--set", "--themes"].contains(flag), let folder = arguments.popFirst() else {
        FileHandle.standardError.write("usage: swift Design/make-app-icons.swift [--set <folder>] [--themes <folder>]\n".data(using: .utf8)!)
        exit(2)
    }
    options[flag] = URL(fileURLWithPath: folder)
}
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

/// The Mac's icon plate, as Apple's template has it: an 824 pt rounded square in a 1024 pt canvas, corner radius 185,
/// with a soft shadow under it. AppIcons.dockImage draws the same.
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

/// One icon: its iOS set, its artwork, and for the app's own icon the Mac's set.
func make(_ master: CGImage, name: String) {
    guard master.width == 1024, master.height == 1024 else { fatalError("\(name) is not 1024 × 1024") }
    let set = name == primary ? "AppIcon" : "AppIcon-\(name)"
    iosIconSet(master, at: iosCatalog.appendingPathComponent("\(set).appiconset"))
    artSet(master, name: name)
    if name == primary {
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
    print("\(name) → \(set)")
}

if let delivery = options["--set"] {
    let masters = delivery.appendingPathComponent("02_1024x1024_FullBleed_PNG")
    for file in setIcons {
        make(load(masters.appendingPathComponent("\(file)_1024x1024.png")), name: String(file.drop { $0 != "_" }.dropFirst()))
    }
}
if let delivery = options["--themes"] {
    for theme in themes {
        make(load(delivery.appendingPathComponent(theme.folder).appendingPathComponent("\(theme.folder)-1024.png")), name: theme.name)
    }
}

// The icon before MediaPocketPurple: artwork from its iOS set, which this script leaves alone.
artSet(load(iosCatalog.appendingPathComponent("AppIcon-Classic.appiconset/AppIcon.png")), name: "Classic")
print("Classic → AppIconArt-Classic")
