import SwiftUI
import CoreImage
import ImageIO
import TVCore

/// A bounded, off-main-thread paint pass. The bottom of a cover gradually loses detail and
/// merges into its own colour, so the full-screen background and the scrolling shelves join.
struct DiscoverPaint: @unchecked Sendable {
    let image: CGImage
    let red: Double
    let green: Double
    let blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    var isDark: Bool { red * 0.2126 + green * 0.7152 + blue * 0.0722 < 0.58 }
}

actor DiscoverPainter {
    static let shared = DiscoverPainter()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cache: [URL: DiscoverPaint] = [:]
    private var order: [URL] = []
    private var pending: [URL: Task<DiscoverPaint?, Never>] = [:]

    func paint(_ source: URL) async -> DiscoverPaint? {
        if let cached = cache[source] { return cached }
        if let task = pending[source] { return await task.value }
        // The rails use w500; the full-width cover needs enough pixels for the phone's display.
        let url = source.host == "image.tmdb.org"
            ? URL(string: source.absoluteString.replacingOccurrences(of: "/w500/", with: "/w1280/").replacingOccurrences(of: "/w780/", with: "/w1280/")) ?? source : source
        let task = Task { await self.render(url) }
        pending[source] = task
        let result = await task.value
        pending[source] = nil
        if let result {
            cache[source] = result
            order.append(source)
            if order.count > 12 { cache.removeValue(forKey: order.removeFirst()) }
        }
        return result
    }

    private func render(_ url: URL) async -> DiscoverPaint? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let rgb = palette(decoded)
        let image = CIImage(cgImage: decoded)
        let rect = image.extent
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: rect.width * 0.055]).cropped(to: rect)
        let mask = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: rect.height * 0.62),
            "inputPoint1": CIVector(x: 0, y: rect.height * 0.38),
            "inputColor0": CIColor.black, "inputColor1": CIColor.white,
        ])!.outputImage!.cropped(to: rect)
        let progressive = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
        let tint = CIColor(red: rgb.0, green: rgb.1, blue: rgb.2)
        let fade = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: rect.height * 0.52),
            "inputPoint1": CIVector(x: 0, y: rect.height * 0.015),
            "inputColor0": CIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0),
            "inputColor1": tint,
        ])!.outputImage!.cropped(to: rect)
        let composited = fade.composited(over: progressive)
        guard let result = context.createCGImage(composited, from: rect) else { return nil }
        return DiscoverPaint(image: result, red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private func palette(_ image: CGImage) -> (Double, Double, Double) {
        let width = 24, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let bitmap = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (0.08, 0.08, 0.08)
        }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        struct Bin { var weight = 0.0; var r = 0.0; var g = 0.0; var b = 0.0 }
        var bins: [Int: Bin] = [:]
        // CGContext's first row is the image's bottom. Prefer the lower half; ignore printed
        // white credits and near-black letterboxing when choosing a surrounding surface.
        for y in 0..<22 {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let high = max(r, g, b), low = min(r, g, b)
                guard high > 0.055, low < 0.88 else { continue }
                let saturation = high > 0 ? (high - low) / high : 0
                let weight = (0.35 + saturation * 1.65) * (1 - Double(y) / 45)
                let key = Int(r * 5) * 36 + Int(g * 5) * 6 + Int(b * 5)
                var bin = bins[key, default: Bin()]
                bin.weight += weight; bin.r += r * weight; bin.g += g * weight; bin.b += b * weight
                bins[key] = bin
            }
        }
        guard let dominant = bins.values.max(by: { $0.weight < $1.weight }), dominant.weight > 0 else { return (0.08, 0.08, 0.08) }
        return (dominant.r / dominant.weight, dominant.g / dominant.weight, dominant.b / dominant.weight)
    }
}

/// Lives behind the scroll view. Only the cover responds to scroll; the sampled surface stays
/// screen-sized. The image is already progressively blurred, avoiding live full-screen blur passes.
struct DiscoverBackdrop: View {
    let paint: DiscoverPaint?
    let width: CGFloat
    let heroHeight: CGFloat
    let scrollY: CGFloat
    let trailer: TMDBMatch.Trailer?
    let playsTrailer: Bool
    @State private var videoReady = false
    var body: some View {
        #if os(tvOS)
        ZStack(alignment: .top) {
            Color(red: 0.018, green: 0.028, blue: 0.035)
            ZStack {
                if let paint {
                    Image(decorative: paint.image, scale: 1).resizable().scaledToFill()
                        .frame(width: width, height: heroHeight).clipped()
                }
                if let trailer, playsTrailer {
                    DiscoverTrailer(trailer: trailer).frame(width: width, height: heroHeight).clipped()
                }
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: Color(red: 0.018, green: 0.028, blue: 0.035), location: 1)], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: width, height: heroHeight)
            .offset(y: -max(0, scrollY) * 0.6)
            .opacity(max(0, 1 - max(0, scrollY) / heroHeight))
        }.ignoresSafeArea().accessibilityHidden(true).allowsHitTesting(false)
        #else
        ZStack(alignment: .top) {
            (paint?.color ?? Color(white: 0.06))
            if let paint {
                Image(decorative: paint.image, scale: 1).resizable().scaledToFill()
                    .frame(width: width, height: heroHeight)
                    .scaleEffect(1.2 + max(0, -scrollY) / max(heroHeight, 1), anchor: .center)
                    .offset(y: -scrollY * 0.78)
                    .opacity(max(0, 1 - max(0, scrollY - heroHeight * 0.45) / (heroHeight * 0.55)))
                    .opacity(videoReady ? 0 : 1)
                    .frame(width: width, height: heroHeight, alignment: .top).clipped()
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.72),
                                               .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
            }
            if let trailer, playsTrailer {
                DiscoverTrailer(trailer: trailer) { ready in
                    withAnimation(.easeOut(duration: 0.4)) { videoReady = ready }
                }
                    .frame(width: width, height: heroHeight)
                    .clipped()
                    .offset(y: -max(0, scrollY) * 0.78)
                    .opacity(max(0, 1 - max(0, scrollY) / (heroHeight * 0.35)))
                    .allowsHitTesting(false)
            }
        }
        .discoverFullBleed()
        .accessibilityHidden(true)
        .onChange(of: trailer?.key) { _, _ in videoReady = false }
        .onChange(of: playsTrailer) { _, plays in if !plays { videoReady = false } }
        #endif
    }
}
