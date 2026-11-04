import Foundation

/// Where a "skip the intro" marker comes from, and which source wins when they disagree.
///
/// The interesting part of skipping an intro is not the seeking — it is that four different parties
/// claim to know where the intro ends, and they do not agree:
///
/// * The viewer marked it by hand. Highest authority: they were watching this exact file.
/// * The media server (Emby/Jellyfin) ships chapters with the file. Authoritative for that file,
///   but chapters are often "Chapter 1" spanning the whole episode, so they need filtering.
/// * Public timestamp databases (TheIntroDB, IntroDB, PublicMetaDB) know nothing about this file —
///   only about the title. They are a guess, but a good one for anything widely watched.
///
/// Rex resolves this with an ordered list the viewer drags (`settings.aggregated.sources.skip.footer`:
/// "拖动可调整优先级，排在前面的来源优先使用；关闭后不再使用该来源的标记"). This type is that
/// list, plus the rule that makes it useful: the first source that produces a *plausible* segment
/// wins, and "plausible" is a real check rather than a guess.
public struct SkipSegmentSources: Codable, Hashable, Sendable {

    /// The parties that can claim a segment.
    public enum Source: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The viewer's own marker, stored locally.
        case manual
        /// Chapters carried by the media server's file.
        case mediaServer
        /// Public timestamp databases.
        case theIntroDB
        case introDB
        case publicMetaDB

        public var id: String { rawValue }

        /// Whether this source describes *this file* or only the title.
        ///
        /// File-level sources can be trusted about exact times; title-level ones describe a
        /// different release with different timings, so their answer needs a sanity check.
        public var isFileLevel: Bool {
            switch self {
            case .manual, .mediaServer: return true
            case .theIntroDB, .introDB, .publicMetaDB: return false
            }
        }

        /// Whether anything in the app can ask this source yet.
        ///
        /// The viewer's markers are stored locally and the chapters come with the file, so both
        /// answer offline. The public databases need a network call that is not written yet, and a
        /// switch that changes nothing is worse than one that says so — the settings page greys
        /// those out rather than pretending they take part.
        public var isConnected: Bool {
            switch self {
            case .manual, .mediaServer: return true
            case .theIntroDB, .introDB, .publicMetaDB: return false
            }
        }
    }

    /// One segment a source found, in seconds from the start.
    public struct Segment: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case intro, credits, recap, preview, unknown }
        public var kind: Kind
        public var start: Double
        public var end: Double

        public init(kind: Kind, start: Double, end: Double) {
            self.kind = kind
            self.start = start
            self.end = end
        }

        public var duration: Double { max(0, end - start) }
    }

    /// Sources in priority order. Order is the whole point, so it is an array, not a set.
    public var order: [Source]
    /// Sources the viewer switched off. Kept rather than removed, so a drag does not lose them.
    public var disabled: Set<Source>

    public init(order: [Source] = Source.allCases, disabled: Set<Source> = []) {
        self.order = order
        self.disabled = disabled
    }

    /// The sources that may be consulted, in order.
    public var active: [Source] { order.filter { !disabled.contains($0) } }

    /// Whether a source takes part. Dragging a disabled source does not enable it.
    public func isActive(_ source: Source) -> Bool { !disabled.contains(source) }

    /// Moves a source to a new position, keeping the array a permutation of `allCases`.
    public mutating func move(_ source: Source, to index: Int) {
        guard let from = order.firstIndex(of: source) else { return }
        var next = order
        let moved = next.remove(at: from)
        next.insert(moved, at: min(max(0, index), next.count))
        order = next
    }

    /// Picks the segment to use, given what each source reported.
    ///
    /// The first active source with a *usable* segment wins. A segment is unusable when it is empty,
    /// backwards, or — for a title-level source — implausible for a file of this length. That last
    /// check is what keeps a public database's timings for a 24-minute broadcast from being applied
    /// to a 42-minute cut: the intro cannot be longer than the file.
    public func choose(kind: Segment.Kind,
                       duration: Double,
                       reported: [Source: Segment],
                       minimumDuration: Double = 3) -> (source: Source, segment: Segment)? {
        for source in active {
            guard let segment = reported[source], segment.kind == kind else { continue }
            guard segment.duration >= minimumDuration else { continue }
            guard segment.start >= 0, segment.end > segment.start else { continue }
            if duration > 0 {
                guard segment.end <= duration + 1 else { continue }
                // A title-level source cannot claim half the file is an intro.
                if !source.isFileLevel, segment.duration > duration * 0.5 { continue }
            }
            return (source, segment)
        }
        return nil
    }
}
