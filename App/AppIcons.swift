import ImageIO
import SwiftUI
import TVCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: App icons
// Settings › App Icon. iPhone and iPad switch to an alternate icon that ships in the app
// (Config/iOS/Assets.xcassets/AppIcon-<name>), Apple TV to its wide version (Config/tvOS/Assets.xcassets, from
// Design/make-tvos-icon.swift); the Mac has no alternate icons, so it draws the chosen one, or a
// picture of the viewer's own, as its Dock icon while it runs, and sets it on the app itself for when it's closed. The artwork of each icon, for the picker and the Dock,
// is AppIconArt-<name> in Config/AppIcons.xcassets. All of them come from Design/make-app-icons.swift.

/// An icon the app ships with. Pocket (MediaPocketPurple) is the app's own; the rest are alternates.
enum AppIconChoice: String, CaseIterable, Identifiable {
    // Keep in step with ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES (project.yml) and Design/make-app-icons.swift.
    case pocket = "MediaPocketPurple", grayPocket = "MediaPocketGray", layers = "MediaLayers", play = "PlayTriangle"
    case seal = "SealMusic", shiba = "ShibaManga", cat = "CatCinema", friends = "AnimalTrio"
    case panda = "Panda", arc = "Arc"
    case classic = "Classic", aurora = "Aurora", porcelain = "Porcelain", obsidian = "Obsidian", azure = "Azure"
    case daybreak = "Daybreak", iris = "Iris", lagoon = "Lagoon", roseQuartz = "RoseQuartz", citrus = "Citrus", cosmic = "Cosmic"

    static let standard = AppIconChoice.pocket
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pocket: L10n.text("Pocket")
        case .grayPocket: L10n.text("Gray Pocket")
        case .layers: L10n.text("Layers")
        case .play: L10n.text("Glass Play")
        case .seal: L10n.text("Seal")
        case .shiba: L10n.text("Shiba")
        case .cat: L10n.text("Cat")
        case .friends: L10n.text("Friends")
        case .panda: L10n.text("Panda")
        case .arc: L10n.text("Arc")
        case .classic: L10n.text("Classic")
        case .aurora: L10n.text("Aurora")
        case .porcelain: L10n.text("Porcelain")
        case .obsidian: L10n.text("Obsidian")
        case .azure: L10n.text("Azure")
        case .daybreak: L10n.text("Daybreak")
        case .iris: L10n.text("Iris")
        case .lagoon: L10n.text("Lagoon")
        case .roseQuartz: L10n.text("Rose Quartz")
        case .citrus: L10n.text("Citrus")
        case .cosmic: L10n.text("Cosmic")
        }
    }
    /// The artwork's image set.
    var art: String { "AppIconArt-\(rawValue)" }
    /// The alternate icon's name on iPhone, iPad and Apple TV; nil for the app's own.
    var alternateName: String? { self == .standard ? nil : "AppIcon-\(rawValue)" }
}

/// The icon in use and the way to change it.
@MainActor @Observable final class AppIcons {
    static let shared = AppIcons()

    /// The icon in use; nil while the Mac shows a picture of the viewer's own.
    private(set) var current: AppIconChoice? = .standard
    /// Why the last change didn't happen.
    var failure: String?

    /// The name Settings shows beside App Icon.
    var title: String { current?.title ?? L10n.text("Custom") }

    /// The icon's artwork as the app draws it on its own pages (AppMark).
    var artwork: Image {
        #if os(macOS)
        if current == nil, let custom { return Image(nsImage: custom.art) }
        #endif
        return Image((current ?? .standard).art)
    }

    #if os(iOS) || os(tvOS)
    /// False where the system offers no alternate icons, such as an iPad app running on a Mac.
    static var isAvailable: Bool { UIApplication.shared.supportsAlternateIcons }

    private init() {
        let name = UIApplication.shared.alternateIconName
        current = AppIconChoice.allCases.first { $0.alternateName == name } ?? .standard
    }

    /// Switches the Home Screen icon; the system tells the viewer in an alert of its own.
    func choose(_ choice: AppIconChoice) async {
        failure = nil
        guard choice != current else { return }
        // The check moves at once: the call returns only after the system's alert is closed.
        let previous = current
        current = choice
        do {
            try await UIApplication.shared.setAlternateIconName(choice.alternateName)
        } catch {
            current = previous
            failure = L10n.text("Couldn't change the app icon: %@", error.localizedDescription)
        }
    }
    #endif

    #if os(macOS)
    static let isAvailable = true
    /// The chosen icon's raw value, or `customValue`; missing for the app's own icon.
    static let key = "appIcon"
    private static let customValue = "Custom"
    /// The viewer's picture, as a 1024 px square.
    private static var customFile: URL {
        URL.applicationSupportDirectory.appending(path: "com.tvbox.yingxia/AppIcon/custom.png")
    }

    /// A picture of the viewer's own. It stays until removed, also while another icon is in use, so going back to it
    /// is one click.
    struct CustomIcon {
        let art: NSImage
        /// It came with clear corners, such as an icon made for the Mac, so the Dock shows it as it is rather than on
        /// the plate.
        let shaped: Bool
    }
    private(set) var custom: CustomIcon?

    private init() {
        custom = Self.loadCustom()
        let saved = UserDefaults.standard.string(forKey: Self.key)
        if saved == Self.customValue, custom != nil { current = nil }
        else { current = saved.flatMap(AppIconChoice.init(rawValue:)) ?? .standard }
    }

    /// Puts the icon in use in the Dock. At launch, and after every change.
    func apply() {
        if current == nil, let custom {
            NSApp.applicationIconImage = custom.shaped ? custom.art : Self.dockImage(custom.art)
            applyToBundle(NSApp.applicationIconImage, id: Self.customValue + Self.customStamp)
        } else if let current, current != .standard, let art = NSImage(named: current.art) {
            NSApp.applicationIconImage = Self.dockImage(art)
            applyToBundle(NSApp.applicationIconImage, id: current.rawValue)
        } else {
            // The app's own icon, from its bundle.
            NSApp.applicationIconImage = nil
            applyToBundle(nil, id: nil)
        }
        #if DEBUG
        // `-qaDockIcon <path>` writes the Dock icon to a PNG, as the Dock can't be seen from a QA run.
        if let path = UserDefaults.standard.string(forKey: "qaDockIcon"), let tiff = NSApp.applicationIconImage?.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        #endif
    }

    /// The Dock draws `applicationIconImage` only while the app runs; once it quits, the Dock, Finder and Launchpad
    /// show the icon of the app itself (#1135). So the chosen icon is set on the app too, as Finder's Get Info does it
    /// (an `Icon\r` file in the bundle). An update replaces the bundle and the icon with it, so it's checked at every
    /// launch, but written only when it's missing or another one was chosen.
    private func applyToBundle(_ image: NSImage?, id: String?) {
        let bundle = Bundle.main.bundleURL.path
        let hasIcon = FileManager.default.fileExists(atPath: bundle + "/Icon\r")
        let written = UserDefaults.standard.string(forKey: Self.bundleKey)
        guard let id, let image else {
            if hasIcon { NSWorkspace.shared.setIcon(nil, forFile: bundle, options: []) }
            UserDefaults.standard.removeObject(forKey: Self.bundleKey)
            return
        }
        guard !hasIcon || written != id else { return }
        if NSWorkspace.shared.setIcon(image, forFile: bundle, options: []) {
            UserDefaults.standard.set(id, forKey: Self.bundleKey)
        } else {
            // Such as an account that isn't an administrator, or an app opened from a disk image.
            UserDefaults.standard.removeObject(forKey: Self.bundleKey)
            failure = L10n.text("Yingxia can't change its own icon where it's installed, so the Dock shows this icon only while Yingxia is open.")
        }
    }
    /// The icon last set on the app itself.
    private static let bundleKey = "appIconOnBundle"
    /// Tells one picture from the next, so a new one is set on the app too.
    private static var customStamp: String {
        let changed = (try? FileManager.default.attributesOfItem(atPath: customFile.path))?[.modificationDate] as? Date
        return "-\(Int(changed?.timeIntervalSince1970 ?? 0))"
    }

    func choose(_ choice: AppIconChoice) async {
        failure = nil
        current = choice
        if choice == .standard { UserDefaults.standard.removeObject(forKey: Self.key) }
        else { UserDefaults.standard.set(choice.rawValue, forKey: Self.key) }
        apply()
    }

    /// Back to the picture chosen earlier.
    func chooseCustom() {
        failure = nil
        guard custom != nil else { return }
        current = nil
        UserDefaults.standard.set(Self.customValue, forKey: Self.key)
        apply()
    }

    /// Makes a picture the icon: the middle square of it, at 1024 px.
    func importPicture(_ url: URL) {
        failure = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
              let square = Self.square(picture), let png = Self.png(square) else {
            failure = L10n.text("Couldn't open that picture.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: Self.customFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: Self.customFile, options: .atomic)
        } catch {
            failure = L10n.text("Couldn't change the app icon: %@", error.localizedDescription)
            return
        }
        custom = Self.loadCustom()
        chooseCustom()
    }

    /// Forgets the picture, and goes back to the app's own icon if it was in use.
    func removeCustom() {
        try? FileManager.default.removeItem(at: Self.customFile)
        custom = nil
        if current == nil { Task { await choose(.standard) } }
    }

    private static func loadCustom() -> CustomIcon? {
        guard let source = CGImageSourceCreateWithURL(customFile as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CustomIcon(art: NSImage(cgImage: image, size: NSSize(width: 512, height: 512)), shaped: hasClearCorner(image))
    }

    /// The middle square of `image`, scaled to 1024 px; transparency kept.
    private static func square(_ image: CGImage) -> CGImage? {
        let side = min(image.width, image.height)
        guard side > 0, let crop = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side))
        else { return nil }
        return render(size: 1024) { $0.draw(crop, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }
    }

    /// Whether the top-left corner is see-through, as on an icon drawn for the Mac or iPhone.
    private static func hasClearCorner(_ image: CGImage) -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        // Drawn at full size with its top-left pixel on the context's only one.
        context.draw(image, in: CGRect(x: 0, y: 1 - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        return pixel[3] < 128
    }

    /// The artwork on the Mac's icon plate, as Design/make-app-icons.swift draws the app's own Mac icon: an 824 px
    /// rounded square in a 1024 px canvas with a soft shadow under it.
    static func dockImage(_ art: NSImage) -> NSImage {
        guard let artwork = art.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let plated = render(size: 1024, draw: { context in
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
                  context.draw(artwork, in: body)
              }) else { return art }
        return NSImage(cgImage: plated, size: NSSize(width: 1024, height: 1024))
    }

    private static func render(size: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        draw(context)
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    #endif
}

// MARK: Settings › App Icon

struct AppIconSettingsView: View {
    @State private var icons = AppIcons.shared
    #if os(macOS)
    @State private var choosesPicture = false
    #endif
    #if os(tvOS)
    /// The row in focus, whose icon the left of the page shows.
    @FocusState private var focused: AppIconChoice?
    #endif

    var body: some View {
        Group {
            #if os(tvOS)
            TVSettingsSubpage(title: L10n.text("App Icon")) {
                AppIconPreview(choice: focused ?? icons.current ?? .standard)
            } content: {
            SettingsGroup(footer: icons.failure ?? note) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button { Task { await icons.choose(choice) } } label: {
                        TVSettingsRowLabel(title: choice.title) {
                            Image(choice.art).resizable().interpolation(.high).scaledToFill()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold))
                                .opacity(icons.current == choice ? 1 : 0)
                        }
                    }
                    .glassRow()
                    .focused($focused, equals: choice)
                    .accessibilityIdentifier("appIcon.\(choice.rawValue)")
                    .accessibilityAddTraits(icons.current == choice ? .isSelected : [])
                }
            }
            }
            #else
            SettingsPage(title: L10n.text("App Icon"), symbol: "app.badge") {
            SettingsGroup(footer: icons.failure ?? note) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: AppIconTile.width), spacing: 12, alignment: .top)], spacing: 18) {
                    ForEach(AppIconChoice.allCases) { choice in
                        Button { Task { await icons.choose(choice) } } label: {
                            AppIconTile(image: Image(choice.art), title: choice.title, selected: icons.current == choice)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("appIcon.\(choice.rawValue)")
                    }
                    #if os(macOS)
                    if let custom = icons.custom {
                        Button { icons.chooseCustom() } label: {
                            AppIconTile(image: Image(nsImage: custom.art), title: L10n.text("Custom"), selected: icons.current == nil,
                                        masked: !custom.shaped)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("appIcon.Custom")
                    }
                    #endif
                }
                .padding(.vertical, 10)
            }
            #if os(macOS)
            SettingsGroup(footer: L10n.text("A square picture works best. One with see-through corners, such as an icon made for the Mac, shows as it is.")) {
                Button { choosesPicture = true } label: {
                    FormLabel(symbol: "photo.fill", tint: .blue, title: L10n.text("Choose Picture…"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .formRowButton()
                .accessibilityIdentifier("appIcon.choosePicture")
                if icons.custom != nil {
                    Button { icons.removeCustom() } label: {
                        FormLabel(symbol: "trash.fill", tint: .red, title: L10n.text("Remove Custom Picture"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .formRowButton()
                }
            }
            .fileImporter(isPresented: $choosesPicture, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { icons.importPicture(url) }
            }
            #endif
            }
            #endif
        }
        #if DEBUG && (os(iOS) || os(tvOS))
        // `-qaChooseIcon <name>` picks that icon as a tap would. Not on the Mac, where the choice is saved in the
        // viewer's own defaults; pass `-appIcon <name>` there instead.
        .task {
            if let name = UserDefaults.standard.string(forKey: "qaChooseIcon"), let choice = AppIconChoice(rawValue: name) {
                // Once launched: during launch the system cancels the change.
                try? await Task.sleep(for: .seconds(3))
                await icons.choose(choice)
            }
        }
        #elseif DEBUG && os(macOS)
        // `-qaImportIcon <path>` takes that picture as Choose Picture… would. It saves "appIcon" in the real defaults
        // even with CFFIXED_USER_HOME; `defaults delete com.jo32.yingxia.mac appIcon` afterwards.
        .task {
            if let path = UserDefaults.standard.string(forKey: "qaImportIcon") { icons.importPicture(URL(fileURLWithPath: path)) }
        }
        #endif
    }

    private var note: String {
        #if os(macOS)
        L10n.text("The Dock and Finder show the icon you pick, also while Yingxia is closed.")
        #elseif os(tvOS)
        // The top shelf image belongs to the app, not the icon.
        L10n.text("The icon on the Home Screen. When Yingxia sits in the top row, the picture above it stays Pocket.")
        #else
        L10n.text("The icon on your Home Screen. The system confirms the change with a short message.")
        #endif
    }
}

#if os(tvOS)
/// An icon as the Apple TV Home Screen shows it: the wide image stack from Config/tvOS/Assets.xcassets, flattened.
private struct AppIconPreview: View {
    let choice: AppIconChoice
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        Group {
            if let stack = UIImage(named: choice.alternateName ?? "App Icon - Small") {
                Image(uiImage: stack).resizable()
            } else {
                Image(choice.art).resizable().scaledToFill()
            }
        }
        .frame(width: 400, height: 240)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.45), radius: 30, y: 16)
        .accessibilityHidden(true)
    }
}
#else
/// One icon in the picker: the artwork as an icon, its name, and a check under the one in use.
private struct AppIconTile: View {
    #if os(macOS)
    static let width: CGFloat = 76, size: CGFloat = 60
    #else
    static let width: CGFloat = 78, size: CGFloat = 64
    #endif
    let image: Image
    let title: String
    let selected: Bool
    /// False for a picture that brings its own shape.
    var masked = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.size * 0.225, style: .continuous)
        VStack(spacing: 6) {
            Group {
                if masked {
                    image.resizable().interpolation(.high).scaledToFill()
                        .frame(width: Self.size, height: Self.size)
                        .clipShape(shape)
                        // Porcelain's white would melt into a white row without an edge.
                        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5) }
                } else {
                    image.resizable().interpolation(.high).scaledToFit()
                        // The plate of a Mac icon fills about 80% of its square.
                        .frame(width: Self.size * 1.24, height: Self.size * 1.24)
                        .frame(width: Self.size, height: Self.size)
                }
            }
            .padding(4)
            .overlay {
                RoundedRectangle(cornerRadius: Self.size * 0.225 + 4, style: .continuous)
                    .strokeBorder(selected ? systemAccent : .clear, lineWidth: 2.5)
            }
            Text(title).font(.caption).foregroundStyle(selected ? .primary : .secondary).lineLimit(1).minimumScaleFactor(0.8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.body).foregroundStyle(selected ? AnyShapeStyle(systemAccent) : AnyShapeStyle(.tertiary))
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
#endif
