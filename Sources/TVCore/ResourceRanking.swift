import Foundation

/// Orders playable resources by the attributes a viewer actually chooses between.
///
/// When one title has several files — different sources, different resolutions, HDR and SDR copies,
/// a small fast one and a big slow one — "which do I play" is a decision, and the source's own order
/// is not an answer. Rex settles this with a rule the viewer composes: up to four attributes, each
/// ascending or descending, applied in order, with three presets on top
/// (`settings.aggregated.resource.*`). 映匣 has the data — `SourceProbeResult` already carries
/// resolution and throughput — but no way to express the preference.
///
/// The four attributes are the four that change the answer:
///
/// * **Resolution** — what most people mean by "better".
/// * **Bitrate** — what "better" means when resolution ties, and what predicts buffering.
/// * **File size** — what matters on a metered connection or a full disk.
/// * **Colour range** — whether the copy is HDR. Worth its own key because an HDR copy is *better*
///   on an HDR screen and *worse* on an SDR one, so it cannot be folded into resolution.
///
/// Ties fall through to the next key, and a resource missing an attribute sorts last among its peers
/// rather than being dropped: a file with no bitrate reading is still playable.
public struct ResourceRanking: Codable, Hashable, Sendable {

    /// One attribute, with the direction to sort it.
    public struct Key: Codable, Hashable, Sendable, Identifiable {
        public enum Attribute: String, Codable, Sendable, CaseIterable {
            case resolution, bitrate, fileSize, colourRange

            /// Whether the source speed test can supply this attribute at all.
            ///
            /// It measures what a source's newest video declares (its height) and how fast the host
            /// serves bytes. Bitrate, file size and HDR belong to one *file*, and a source is not a
            /// file: the sweep never reads them, so ordering sources by them changes nothing. The
            /// settings page says so instead of offering three switches that do nothing.
            public var speedTestProvides: Bool { self == .resolution }
        }
        public var attribute: Attribute
        /// True when larger is better (resolution, bitrate, HDR). False when smaller is better.
        public var descending: Bool

        public var id: String { attribute.rawValue + (descending ? "↓" : "↑") }

        public init(_ attribute: Attribute, descending: Bool = true) {
            self.attribute = attribute
            self.descending = descending
        }
    }

    /// The keys, most significant first.
    public var keys: [Key]

    public init(keys: [Key]) { self.keys = keys }

    // MARK: Presets

    /// What a person wants when they say nothing: the sharpest copy, breaking ties by bitrate.
    public static let standard = ResourceRanking(keys: [Key(.resolution), Key(.bitrate)])

    /// For a viewer who wants the best picture and does not care what it costs.
    public static let quality = ResourceRanking(keys: [
        Key(.resolution), Key(.colourRange), Key(.bitrate),
    ])

    /// For a viewer on a weak connection: the smallest thing that still looks acceptable.
    public static let speed = ResourceRanking(keys: [
        Key(.bitrate, descending: false), Key(.fileSize, descending: false),
    ])

    public static let presets: [(name: String, ranking: ResourceRanking)] = [
        ("Default", standard), ("Quality", quality), ("Speed", speed),
    ]

    // MARK: Ranking

    /// The attributes of one candidate. Every field is optional because a probe may not know it.
    public struct Candidate: Sendable {
        public var resolutionHeight: Int?
        public var bitrateBitsPerSecond: Int?
        public var fileSizeBytes: Int64?
        /// True for HDR/Dolby Vision, false for SDR, nil when unknown.
        public var isHDR: Bool?

        public init(resolutionHeight: Int? = nil, bitrateBitsPerSecond: Int? = nil,
                    fileSizeBytes: Int64? = nil, isHDR: Bool? = nil) {
            self.resolutionHeight = resolutionHeight
            self.bitrateBitsPerSecond = bitrateBitsPerSecond
            self.fileSizeBytes = fileSizeBytes
            self.isHDR = isHDR
        }

        /// Builds from a probe result, so the two never drift apart.
        public init(_ probe: SourceProbeResult, fileSizeBytes: Int64? = nil, isHDR: Bool? = nil) {
            self.resolutionHeight = probe.resolutionHeight
            // The probe measures throughput, not the file's own bitrate. Using it as a stand-in
            // would rank a fast server above a high-bitrate file, which is the opposite of the
            // question being asked — so leave it nil unless the caller knows the real figure.
            self.bitrateBitsPerSecond = nil
            self.fileSizeBytes = fileSizeBytes
            self.isHDR = isHDR
        }

        func value(for attribute: Key.Attribute) -> Double? {
            switch attribute {
            case .resolution: return resolutionHeight.map(Double.init)
            case .bitrate: return bitrateBitsPerSecond.map(Double.init)
            case .fileSize: return fileSizeBytes.map(Double.init)
            case .colourRange: return isHDR.map { $0 ? 1 : 0 }
            }
        }
    }

    /// Sorts `items` by the keys, most significant first.
    ///
    /// A missing attribute is "unknown", not "worst": it sorts after every candidate that has a value
    /// for that key, but before falling through to the next key. Dropping such candidates would hide
    /// playable files; treating them as zero would rank them as terrible, which is a different claim.
    public func sort<T>(_ items: [T], by candidate: (T) -> Candidate) -> [T] {
        guard !keys.isEmpty else { return items }
        return items.enumerated().sorted { lhs, rhs in
            let a = candidate(lhs.element), b = candidate(rhs.element)
            for key in keys {
                let av = a.value(for: key.attribute), bv = b.value(for: key.attribute)
                switch (av, bv) {
                case let (x?, y?) where x != y:
                    return key.descending ? x > y : x < y
                case (nil, _?):
                    return false          // unknown goes after a known value
                case (_?, nil):
                    return true
                default:
                    continue              // equal, or both unknown: try the next key
                }
            }
            // Fully tied — keep the source's order, which is at least stable.
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
