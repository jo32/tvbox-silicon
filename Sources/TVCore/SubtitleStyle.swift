import Foundation
import CoreGraphics

/// How subtitles look and where they sit, as five settings that survive a restart.
///
/// One (`com.ios151.one`) draws its own subtitle layer — `SubtitleOverlayView` and a draggable
/// `SubtitleBubbleView` — and stores five independent values: font size, text opacity, background
/// opacity, and an x/y position the user can drag the bubble to. 映匣 currently hands subtitles to
/// `AVPlayer`, which renders them itself: the *track* is selectable but its *appearance* is not.
/// AVTextStyleRule can change colour and size but not position, and it does not survive the
/// differences between a WebVTT cue and an in-manifest CEA-608 caption.
///
/// So this type does not try to restyle the player's own rendering. It stores what a custom
/// overlay needs, with defaults chosen so an untouched install looks like a normal player: a
/// readable size, near-opaque text, a faint plate behind it, and the bubble low and centred.
///
/// Stored as a plain `Codable` value: the caller owns persistence, so this stays usable outside
/// 映匣 entirely.
public struct SubtitleStyle: Codable, Equatable, Sendable {

    // MARK: 范围

    /// Font sizes a person may pick, in points. The span follows the same reasoning as a system
    /// font's: below 12 is unreadable over video, above 40 wraps every line on a phone.
    public static let fontSizeRange: ClosedRange<Double> = 12...40
    /// Default matches the system caption size on a phone.
    public static let defaultFontSize: Double = 17

    // MARK: 字段

    /// Point size of the caption text.
    public var fontSize: Double
    /// Opacity of the text itself, 0…1.
    public var textOpacity: Double
    /// Opacity of the plate drawn behind the text, 0…1. Zero means no plate, which is what a
    /// person wants when the video has its own dark band at the bottom.
    public var backgroundOpacity: Double
    /// Where the bubble sits horizontally, 0…1, where 0.5 is centred. Dragging the bubble right
    /// raises it.
    public var centerX: Double
    /// Where the bubble sits vertically, 0…1 from the top. 0.86 is low enough to sit under the
    /// picture's subject and above the scrubber.
    public var centerY: Double
    /// Whether subtitles are drawn at all. Kept here rather than in the player so one switch turns
    /// the whole layer off, including its plate.
    public var enabled: Bool

    public init(fontSize: Double = SubtitleStyle.defaultFontSize,
                textOpacity: Double = 0.96,
                backgroundOpacity: Double = 0.55,
                centerX: Double = 0.5,
                centerY: Double = 0.86,
                enabled: Bool = true) {
        self.fontSize = fontSize
        self.textOpacity = textOpacity
        self.backgroundOpacity = backgroundOpacity
        self.centerX = centerX
        self.centerY = centerY
        self.enabled = enabled
    }

    /// What an untouched install shows.
    public static let standard = SubtitleStyle()

    // MARK: 合法化

    /// Clamps every value into its range. Called on load and after every edit, so a hand-edited
    /// preferences file or a value from an older version cannot put the bubble off screen.
    public var sanitized: SubtitleStyle {
        var copy = self
        copy.fontSize = min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
        copy.textOpacity = min(max(textOpacity, 0), 1)
        copy.backgroundOpacity = min(max(backgroundOpacity, 0), 1)
        // Keep the bubble fully on screen: a centre at 0 or 1 would clip half of it.
        copy.centerX = min(max(centerX, 0.08), 0.92)
        copy.centerY = min(max(centerY, 0.10), 0.94)
        return copy
    }

    /// Whether anything differs from the default, so a settings row can say "changed".
    public var isModified: Bool { sanitized != SubtitleStyle.standard }

    // MARK: 派生

    /// The plate's corner radius, scaled with the text so the shape keeps its proportion.
    public var cornerRadius: Double { max(4, fontSize * 0.35) }
    /// Horizontal and vertical padding inside the plate.
    public var horizontalPadding: Double { fontSize * 0.55 }
    public var verticalPadding: Double { fontSize * 0.22 }
    /// How far the bubble may travel from where it is, given its own size — used by the drag
    /// gesture so a fast flick cannot send it off screen.
    public func clampedCenter(x: Double, y: Double) -> (x: Double, y: Double) {
        (min(max(x, 0.08), 0.92), min(max(y, 0.10), 0.94))
    }

    /// Everything but the position reset to the default, so "reset size and transparency" leaves
    /// the place where the user dragged the bubble alone.
    public func resettingAppearance() -> SubtitleStyle {
        var copy = SubtitleStyle.standard
        copy.centerX = centerX
        copy.centerY = centerY
        copy.enabled = enabled
        return copy
    }
}

// MARK: - 位置记忆

/// Remembers where the user dragged the subtitle bubble, so it stays there next time.
///
/// One keeps the position on the video and restores it when the same article opens again
/// (`positionX` / `positionY` / `onDragEnd`); a single global position would be wrong, because a
/// letterboxed film and a vertical short need the bubble in different places. This keeps one
/// position per key the caller supplies — a video id, a series id, or a player mode — and a global
/// fallback for anything unkeyed.
public struct SubtitlePositionMemory: Codable, Equatable, Sendable {
    /// Positions by key.
    public private(set) var positions: [String: CGPoint] = [:]
    /// Keys in least-recently-stored order. A dictionary's own order is unspecified, so eviction
    /// needs its own list; without it "drop the oldest" would drop a random entry.
    private var order: [String] = []
    /// Used when a key has no position of its own.
    public var fallback: CGPoint
    /// How many keys to keep. Old ones are dropped first; a person rarely adjusts more than a
    /// handful of titles.
    public var capacity: Int

    public init(fallback: CGPoint = CGPoint(x: 0.5, y: 0.86), capacity: Int = 40) {
        self.fallback = fallback
        self.capacity = max(1, capacity)
    }

    /// The position for `key`, or the fallback.
    public func position(for key: String?) -> CGPoint {
        guard let key, let stored = positions[key] else { return fallback }
        return stored
    }

    /// Stores a position. `key` nil updates the fallback instead.
    public mutating func store(_ point: CGPoint, for key: String?) {
        guard let key, !key.isEmpty else { fallback = point; return }
        positions[key] = point
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            positions.removeValue(forKey: oldest)
        }
    }

    /// Forgets one key, for a title the user deleted.
    public mutating func forget(_ key: String) {
        positions.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    /// Forgets everything, for a "reset all" button.
    public mutating func forgetAll() { positions.removeAll(); order.removeAll() }
}

// MARK: - 编解码（CGPoint 不是 Codable 的默认形态）

extension SubtitlePositionMemory {
    private enum CodingKeys: String, CodingKey { case positions, order, fallback, capacity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: [Double]].self, forKey: .positions) ?? [:]
        positions = raw.compactMapValues { pair in
            guard pair.count == 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])
        }
        let fallbackPair = try container.decodeIfPresent([Double].self, forKey: .fallback) ?? [0.5, 0.86]
        fallback = fallbackPair.count == 2 ? CGPoint(x: fallbackPair[0], y: fallbackPair[1]) : CGPoint(x: 0.5, y: 0.86)
        capacity = try container.decodeIfPresent(Int.self, forKey: .capacity) ?? 40
        // Older files have no order array; rebuild it from whatever survived.
        let stored = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        order = stored.filter { positions[$0] != nil }
        for key in positions.keys where !order.contains(key) { order.append(key) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(positions.mapValues { [Double($0.x), Double($0.y)] }, forKey: .positions)
        try container.encode(order, forKey: .order)
        try container.encode([Double(fallback.x), Double(fallback.y)], forKey: .fallback)
        try container.encode(capacity, forKey: .capacity)
    }
}
