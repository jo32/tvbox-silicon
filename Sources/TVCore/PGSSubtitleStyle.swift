import CoreGraphics
import Foundation

/// PGS stores the glyphs, outlines and line spacing together as pixels. Place the entire cue as one image.
public struct PGSSubtitleStyle: Codable, Equatable, Sendable {
    public static let key = "pgsSubtitleStyle"
    public static let changed = Notification.Name("PGSSubtitleStyleChanged")
    public static let scales = 0.5...2.0

    public var scale: Double
    /// Centre in the visible picture, measured from the top left. Nil follows each cue's authored position.
    public var position: CGPoint?

    public init(scale: Double = 1, position: CGPoint? = nil) {
        self.scale = scale
        self.position = position
    }

    private var clamped: Self {
        var style = self
        style.scale = scale.isFinite ? min(max(scale, Self.scales.lowerBound), Self.scales.upperBound) : 1
        style.position = position.flatMap { point in
            guard point.x.isFinite, point.y.isFinite else { return nil }
            return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        }
        return style
    }

    public static func load(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), let style = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return style.clamped
    }

    public func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(clamped) else { return }
        defaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    public func imageRect(for frame: StyledSubtitleFrame, in picture: CGRect, visible: CGRect) -> CGRect {
        let area = picture.intersection(visible)
        guard !area.isEmpty, !frame.rect.isEmpty, frame.size.width > 0, frame.size.height > 0 else { return .zero }
        let canvas = frame.canvasRect(in: picture, visible: visible)
        let authored = canvas.width / frame.size.width
        let style = clamped
        let factor = min(authored * style.scale, area.width / frame.rect.width, area.height / frame.rect.height)
        let width = min(area.width, frame.rect.width * factor), height = min(area.height, frame.rect.height * factor)
        let center = style.position.map { CGPoint(x: area.minX + area.width * $0.x, y: area.minY + area.height * $0.y) }
            ?? CGPoint(x: canvas.minX + frame.rect.midX * authored, y: canvas.minY + frame.rect.midY * authored)
        return CGRect(x: min(max(area.minX, center.x - width / 2), area.maxX - width),
                      y: min(max(area.minY, center.y - height / 2), area.maxY - height), width: width, height: height)
    }
}
