import Foundation

/// One bullet comment (弹幕): text shown over the video at a moment of its timeline.
public struct Danmaku: Sendable, Hashable {
    public enum Position: Sendable, Hashable { case scroll, top, bottom }
    public let time: Double
    public let position: Position
    /// 0xRRGGBB.
    public let color: UInt32
    /// Relative to the standard size (Bilibili's 25 is 1).
    public let scale: Double
    public let text: String
    public init(time: Double, position: Position, color: UInt32 = 0xFFFFFF, scale: Double = 1, text: String) {
        self.time = time; self.position = position; self.color = color; self.scale = scale; self.text = text
    }
}

/// Which comments belong to which playback. Sources register the media address they resolve, and the
/// player asks for that address's comments when it starts.
public enum DanmakuSource {
    private struct Track { let cid: String; let duration: Double? }
    nonisolated(unsafe) private static var tracks: [String: Track] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    private static let lock = NSLock()

    static func register(_ url: URL, bilibiliCID cid: String, duration: Double?) {
        lock.withLock {
            tracks[url.absoluteString] = Track(cid: cid, duration: duration); order.append(url.absoluteString)
            while order.count > 8 { tracks[order.removeFirst()] = nil }
        }
    }

    /// A Bilibili media address cast by the phone (…/upgcxcode/…/<cid>-<n>-<quality>.mp4) names its part's cid,
    /// which is all the comments need. Returns whether the address had one.
    @discardableResult public static func registerBilibiliMedia(_ url: URL) -> Bool {
        guard url.path.contains("xcode"), let match = url.lastPathComponent.firstMatch(of: /^(\d+)-\d+-\d+\.(mp4|m4s|flv)$/),
              let cid = Int(match.1), cid > 0 else { return false }
        register(url, bilibiliCID: String(cid), duration: nil)
        return true
    }

    /// Whether the address has comments to load.
    public static func has(_ url: URL) -> Bool { lock.withLock { tracks[url.absoluteString] != nil } }

    /// The comments for a media address in time order, or nil when it has none.
    public static func comments(for url: URL, session: URLSession = .shared) async -> [Danmaku]? {
        guard let track = lock.withLock({ tracks[url.absoluteString] }) else { return nil }
        return await BilibiliDanmaku.load(cid: track.cid, duration: track.duration, session: session)
    }
}

/// Bilibili serves comments as protobuf in six-minute segments (`DmSegMobileReply`).
enum BilibiliDanmaku {
    static let segment = 360.0

    static func load(cid: String, duration: Double?, session: URLSession) async -> [Danmaku] {
        // Unknown length: try the first hour; segments past the end come back empty.
        let count = max(1, min(60, Int(((duration ?? 3600) / segment).rounded(.up))))
        let segments = await withTaskGroup(of: [Danmaku].self) { group in
            for index in 1...count {
                group.addTask { await fetch(cid: cid, index: index, session: session) }
            }
            return await group.reduce(into: [[Danmaku]]()) { $0.append($1) }
        }
        let all = segments.flatMap { $0 }.sorted { $0.time < $1.time }
        Diagnostics.shared.record(.info, "danmaku", "cid=\(cid) segments=\(count) comments=\(all.count)")
        return all
    }

    private static func fetch(cid: String, index: Int, session: URLSession) async -> [Danmaku] {
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/dm/web/seg.so")!
        components.queryItems = [URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "oid", value: cid), URLQueryItem(name: "segment_index", value: String(index))]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        Bilibili.mediaHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }

    /// `DmSegMobileReply { repeated DanmakuElem elems = 1; }`, where DanmakuElem has progress (2, ms),
    /// mode (3), fontsize (4), color (5) and content (7). Modes 1–3 scroll, 4 is bottom, 5 is top,
    /// 6 scrolls the other way (shown as scroll); 7+ (positioned, code, BAS) are left out.
    static func parse(_ data: Data) -> [Danmaku] {
        var reader = ProtobufReader(data)
        var comments: [Danmaku] = []
        while let (field, value) = reader.next() {
            guard field == 1, case .bytes(let element) = value else { continue }
            var fields = ProtobufReader(element)
            var time = 0, mode = 1, size = 25, color = 0xFFFFFF, text = ""
            while let (number, item) = fields.next() {
                switch (number, item) {
                case (2, .varint(let v)): time = Int(truncatingIfNeeded: v)
                case (3, .varint(let v)): mode = Int(truncatingIfNeeded: v)
                case (4, .varint(let v)): size = Int(truncatingIfNeeded: v)
                case (5, .varint(let v)): color = Int(truncatingIfNeeded: v)
                case (7, .bytes(let bytes)): text = String(decoding: bytes, as: UTF8.self)
                default: break
                }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, (1...6).contains(mode) else { continue }
            let position: Danmaku.Position = mode == 4 ? .bottom : mode == 5 ? .top : .scroll
            comments.append(Danmaku(time: Double(time) / 1000, position: position, color: UInt32(truncatingIfNeeded: color) & 0xFFFFFF,
                                    scale: min(1.5, max(0.7, Double(size) / 25)), text: String(trimmed.prefix(100))))
        }
        return comments
    }
}

/// A minimal protobuf wire-format reader: varints and length-delimited fields; fixed-width ones are skipped.
struct ProtobufReader {
    enum Value { case varint(UInt64), bytes(Data) }
    private let bytes: [UInt8]
    private var cursor = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    private mutating func varint() -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while cursor < bytes.count, shift < 64 {
            let byte = bytes[cursor]; cursor += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    mutating func next() -> (Int, Value)? {
        while cursor < bytes.count {
            guard let key = varint() else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: guard let value = varint() else { return nil }; return (field, .varint(value))
            case 1: cursor += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - cursor) else { return nil }
                let start = cursor; cursor += Int(length)
                return (field, .bytes(Data(bytes[start..<cursor])))
            case 5: cursor += 4
            default: return nil
            }
        }
        return nil
    }
}

/// How much of the picture comments may use, from the top (弹幕区域): a quarter or a half keeps them off faces
/// and subtitles. Stored in percent under `key`; three quarters is where comments always scrolled.
public enum DanmakuArea: Int, CaseIterable, Sendable {
    case quarter = 25, half = 50, threeQuarters = 75, full = 100
    public static let key = "danmakuArea"
    public static let standard = DanmakuArea.threeQuarters
    public var share: Double { Double(rawValue) / 100 }
    public var title: String {
        switch self {
        case .quarter: L10n.text("Top Quarter")
        case .half: L10n.text("Top Half")
        case .threeQuarters: L10n.text("Top Three Quarters")
        case .full: L10n.text("Whole Screen")
        }
    }
    /// The choice after this one, for a row that steps through them with each press.
    public var next: DanmakuArea { Self.allCases[((Self.allCases.firstIndex(of: self) ?? 0) + 1) % Self.allCases.count] }
}

/// Places comments in lanes as their time comes, so none overlap: a scrolling comment takes a lane once
/// the lane's previous comment has fully entered and cannot be caught before it leaves; a fixed one
/// takes a lane whose previous fixed comment has gone. Comments that find no lane are dropped, which is
/// how dense moments thin out.
public struct DanmakuLayout {
    public struct Placement: Sendable {
        public let comment: Danmaku
        public let start: Double
        public let width: Double
        public let lane: Int
        /// Points per second; zero for fixed comments.
        public let speed: Double
    }
    public let width: Double
    public let laneHeight: Double
    public let scrollLanes: Int
    public let fixedLanes: Int
    public let scrollDuration: Double
    public let fixedDuration: Double
    private var scrolling: [Placement?]
    private var top: [Placement?]
    private var bottom: [Placement?]

    public init(width: Double, height: Double, laneHeight: Double, scrollArea: Double = 0.75, scrollDuration: Double = 9, fixedDuration: Double = 4) {
        self.width = width; self.laneHeight = laneHeight; self.scrollDuration = scrollDuration; self.fixedDuration = fixedDuration
        scrollLanes = max(1, Int(height * scrollArea / laneHeight))
        // Top comments stay inside the scrolling area when that is smaller than their usual 30%.
        fixedLanes = max(1, Int(height * min(0.3, scrollArea) / laneHeight))
        scrolling = Array(repeating: nil, count: scrollLanes)
        top = Array(repeating: nil, count: fixedLanes)
        bottom = Array(repeating: nil, count: fixedLanes)
    }

    /// How long a placement stays on screen.
    public func duration(_ placement: Placement) -> Double { placement.speed > 0 ? (width + placement.width) / placement.speed : fixedDuration }

    public mutating func place(_ comment: Danmaku, width textWidth: Double, at time: Double) -> Placement? {
        switch comment.position {
        case .scroll:
            let speed = (width + textWidth) / scrollDuration
            let gap = laneHeight
            for lane in scrolling.indices {
                if let last = scrolling[lane] {
                    let elapsed = time - last.start
                    // The previous comment's tail must be on screen with a gap behind it,
                    let tail = width - elapsed * last.speed + last.width
                    guard tail <= width - gap else { continue }
                    // and the new one must not reach the left edge before that tail has left.
                    let leaves = last.start + (width + last.width) / last.speed
                    guard time + width / speed >= leaves else { continue }
                }
                // Top comments share these rows, so it must not reach one that is still pinned there.
                if lane < top.count, let pinned = top[lane], time - pinned.start < fixedDuration {
                    let right = (width + pinned.width) / 2
                    guard time + (width - right) / speed >= pinned.start + fixedDuration else { continue }
                }
                let placement = Placement(comment: comment, start: time, width: textWidth, lane: lane, speed: speed)
                scrolling[lane] = placement
                return placement
            }
            return nil
        case .top, .bottom:
            let lanes = comment.position == .top ? top : bottom
            guard let lane = lanes.indices.first(where: { lane in
                guard lanes[lane].map({ time - $0.start >= fixedDuration }) ?? true else { return false }
                // A top comment also keeps clear of scrolling comments crossing the centre of its row while it shows.
                guard comment.position == .top, lane < scrolling.count, let moving = scrolling[lane] else { return true }
                let left = (width - textWidth) / 2, right = left + textWidth
                let passed = width - (time - moving.start) * moving.speed + moving.width <= left
                let arrives = width - (time + fixedDuration - moving.start) * moving.speed < right
                return passed || !arrives
            }) else { return nil }
            let placement = Placement(comment: comment, start: time, width: textWidth, lane: lane, speed: 0)
            if comment.position == .top { top[lane] = placement } else { bottom[lane] = placement }
            return placement
        }
    }
}
