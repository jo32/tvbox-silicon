//
//  SeriesSuggestion.swift
//  TVCore
//
//  What to offer when a video's last episode finishes.
//
//  Priority, per the requirement
//  -----------------------------
//  1. Same source, same show, different season — "红果" style series where the
//     follow-up is the same title with another season number.
//  2. Same source, same title family (a stripped season suffix still matches).
//  3. Anything else the caller wants to pass in as a fallback row.
//
//  Matching is deliberately conservative: a wrong "next season" is worse than no
//  suggestion, because the player auto-advances after a countdown. Titles are
//  compared after normalisation, and a season delta of exactly +1 is required
//  before a candidate is treated as "the next season".
//

import Foundation

// MARK: - Title normalisation

public enum SeriesTitleMatcher {
    /// Season wording this matcher understands, mapped to the number it implies.
    /// Kept narrow on purpose: only forms that unambiguously carry a season.
    private static let markers: [(pattern: String, season: Int?)] = [
        (#"第\s*([一二三四五六七八九十百\d]+)\s*季"#, nil),   // handled below
        (#"season\s*(\d+)"#, nil),
        (#"\bS(\d{1,2})\b"#, nil),
    ]

    private static let chineseDigits: [Character: Int] = [
        "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
        "六": 6, "七": 7, "八": 8, "九": 9, "十": 10,
    ]

    /// Splits a title into a base and a season number.
    /// "庆余年 第二季" -> ("庆余年", 2); "Show S02" -> ("Show", 2);
    /// "庆余年" -> ("庆余年", nil).
    public static func split(_ raw: String) -> (base: String, season: Int?) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ("", nil) }

        // 第N季 / 第N部 (Chinese numeral or Arabic)
        if let range = title.range(of: #"第\s*[一二三四五六七八九十百\d]+\s*[季部]"#, options: .regularExpression) {
            let token = String(title[range])
            let digits = token.filter { $0.isNumber || chineseDigits[$0] != nil }
            let season = seasonNumber(from: digits)
            title.removeSubrange(range)
            return (title.trimmingCharacters(in: .whitespacesAndNewlines), season)
        }

        // Season N / Season N (English, case-insensitive)
        if let range = title.range(of: #"[Ss]eason\s*\d+"#, options: .regularExpression) {
            let season = seasonNumber(from: String(title[range]).filter(\.isNumber))
            title.removeSubrange(range)
            return (title.trimmingCharacters(in: .whitespacesAndNewlines), season)
        }

        // Trailing S01 / S1
        if let range = title.range(of: #"\bS\d{1,2}\b"#, options: .regularExpression) {
            let season = seasonNumber(from: String(title[range]).filter(\.isNumber))
            title.removeSubrange(range)
            return (title.trimmingCharacters(in: .whitespacesAndNewlines), season)
        }

        return (title, nil)
    }

    private static func seasonNumber(from digits: String) -> Int? {
        guard !digits.isEmpty else { return nil }
        if let arabic = Int(digits) { return arabic }
        // Compound Chinese numerals up to 99: 十 = 10, 十二 = 12, 二十 = 20, 二十三 = 23.
        var total = 0
        var pending: Int?
        for character in digits {
            if character == "百" { total += (pending ?? 1) * 100; pending = nil; continue }
            if character == "十" { total += (pending ?? 1) * 10; pending = nil; continue }
            if let value = chineseDigits[character] { pending = value }
        }
        if let pending { total += pending }
        return total > 0 ? total : nil
    }

    /// Comparison key: base title with punctuation and spacing removed, lowercased.
    public static func key(_ raw: String) -> String {
        let base = split(raw).base
        let filtered = base.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) && !CharacterSet.decimalDigits.contains(scalar)
                || scalar.value > 0x2E80     // keep CJK
        }
        return String(String.UnicodeScalarView(filtered)).lowercased()
    }
}

// MARK: - Suggestion

/// One row on the end-of-series screen.
public struct SeriesSuggestion: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// Same source, same base title, season +1. Auto-advances on timeout.
        case nextSeason
        /// Same source, same base title, some other season.
        case siblingSeason
        /// Same source, different title, same category — a weaker fallback.
        case relatedTitle

        public var autoAdvances: Bool { self == .nextSeason }
    }

    public let video: Video
    public let kind: Kind
    public let sourceKey: String
    public let sourceName: String
    public let origin: URL

    public var id: String { "\(sourceKey)|\(video.id)" }

    public init(video: Video, kind: Kind, sourceKey: String, sourceName: String, origin: URL) {
        self.video = video
        self.kind = kind
        self.sourceKey = sourceKey
        self.sourceName = sourceName
        self.origin = origin
    }

    public var badge: String {
        switch kind {
        case .nextSeason: return L10n.text("Next season")
        case .siblingSeason: return L10n.text("Another season")
        case .relatedTitle: return L10n.text("Related")
        }
    }
}

// MARK: - Ranker

public enum SeriesSuggestionRanker {
    /// How many seconds the end screen waits before playing the next season.
    public static let autoAdvanceSeconds = 10

    /// Ranked suggestions for a finished video.
    ///
    /// - Parameters:
    ///   - finished: the video whose last episode ended.
    ///   - candidates: other videos already known in the same source (typically
    ///     the source's list/search result the player still holds).
    ///   - sourceKey/sourceName/origin: identity of that source.
    public static func rank(
        finished video: Video,
        candidates: [Video],
        sourceKey: String,
        sourceName: String,
        origin: URL,
        limit: Int = 12
    ) -> [SeriesSuggestion] {
        let current = SeriesTitleMatcher.split(video.name)
        let currentKey = SeriesTitleMatcher.key(video.name)
        guard !currentKey.isEmpty else { return [] }

        var scored: [(SeriesSuggestion, Int)] = []

        for candidate in candidates where candidate.id != video.id {
            let other = SeriesTitleMatcher.split(candidate.name)
            let otherKey = SeriesTitleMatcher.key(candidate.name)
            guard !otherKey.isEmpty else { continue }

            let kind: SeriesSuggestion.Kind
            var score = 0

            if otherKey == currentKey {
                // Same show. A season one step ahead is the headline case.
                // A title with no season wording is season 1 by convention on
                // these sources, so "Show" → "Show 第二季" is a real step forward
                // rather than an ambiguity.
                let finishedSeason = current.season ?? 1
                if let b = other.season {
                    if b == finishedSeason + 1 {
                        kind = .nextSeason
                        score = 1_000
                    } else if b != finishedSeason {
                        kind = .siblingSeason
                        score = 600 - abs(b - finishedSeason) * 20
                    } else {
                        continue     // the same season we just finished
                    }
                } else if current.season != nil {
                    // A numbered season finished and the candidate carries no
                    // number: it is not a follow-up we can name, so leave it be.
                    continue
                } else {
                    continue
                }
            } else if currentKey.count >= 2, otherKey.contains(currentKey) || currentKey.contains(otherKey) {
                // Title family ("庆余年" vs "庆余年特别篇"): weak but useful.
                if otherKey.count - currentKey.count > 6 { continue }
                kind = .relatedTitle
                score = 200
            } else if let category = video.category, !category.isEmpty,
                      let otherCategory = candidate.category, otherCategory == category {
                kind = .relatedTitle
                score = 50
            } else {
                continue
            }

            // Prefer the same year, then anything with a poster, then anything
            // that actually has episodes to play.
            if candidate.year == video.year { score += 30 }
            if candidate.poster != nil { score += 10 }
            if candidate.episodes.isEmpty { score -= 100 }

            scored.append((
                SeriesSuggestion(video: candidate, kind: kind, sourceKey: sourceKey, sourceName: sourceName, origin: origin),
                score
            ))
        }

        // Stable: higher score first, then keep the source's own order.
        let ordered = scored.enumerated()
            .sorted { lhs, rhs in
                lhs.element.1 == rhs.element.1 ? lhs.offset < rhs.offset : lhs.element.1 > rhs.element.1
            }
            .map(\.element.0)

        return Array(ordered.prefix(limit))
    }

    /// The row the end screen should auto-play when the countdown expires, if any.
    public static func autoAdvanceTarget(in suggestions: [SeriesSuggestion]) -> SeriesSuggestion? {
        suggestions.first { $0.kind.autoAdvances }
    }
}
