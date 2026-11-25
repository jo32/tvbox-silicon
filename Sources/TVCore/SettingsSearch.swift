import Foundation

/// An item indexed for Settings search.
public struct SettingsSearchItem<ID: Hashable & Sendable>: Identifiable, Sendable {
    public let id: ID
    public let title: String
    public let section: String
    public let subtitle: String
    public let keywords: [String]
    public let order: Int

    public init(id: ID, title: String, section: String, subtitle: String = "", keywords: [String] = [], order: Int = 0) {
        self.id = id
        self.title = title
        self.section = section
        self.subtitle = subtitle
        self.keywords = keywords
        self.order = order
    }
}

/// Multi-field, multi-token, bilingual (including CJK Pinyin) ranked search for Settings.
public enum SettingsSearchEngine {
    public static func search<ID: Hashable & Sendable>(
        query: String,
        in items: [SettingsSearchItem<ID>]
    ) -> [SettingsSearchItem<ID>] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        var scored: [(item: SettingsSearchItem<ID>, score: Double)] = []
        scored.reserveCapacity(items.count)

        for item in items {
            if let total = score(item: item, tokens: tokens) {
                scored.append((item, total))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.order < rhs.item.order
        }
        return scored.map(\.item)
    }

    // MARK: - Scoring

    private struct IndexedField {
        let text: String
        let words: [String]
        let weight: Double
        let allowFuzzy: Bool
    }

    private static func score<ID>(item: SettingsSearchItem<ID>, tokens: [String]) -> Double? {
        let fields = buildFields(for: item)
        var totalScore: Double = 0
        var titleHits = 0

        for token in tokens {
            var bestTokenScore: Double = 0
            var matchedTitle = false

            for (index, field) in fields.enumerated() {
                let base = matchScore(token: token, in: field)
                if base > 0 {
                    let weighted = base * field.weight
                    if weighted > bestTokenScore {
                        bestTokenScore = weighted
                        matchedTitle = (index == 0)
                    }
                }
            }

            // AND semantics: every token must match at least one field.
            guard bestTokenScore > 0 else { return nil }
            totalScore += bestTokenScore
            if matchedTitle { titleHits += 1 }
        }

        // Prefer results where all query tokens hit the primary title directly.
        if titleHits == tokens.count {
            totalScore += 120
        }
        return totalScore
    }

    private static func buildFields<ID>(for item: SettingsSearchItem<ID>) -> [IndexedField] {
        var fields: [IndexedField] = []
        let normTitle = normalize(item.title)
        fields.append(IndexedField(text: normTitle, words: splitWords(normTitle), weight: 1.0, allowFuzzy: true))

        if containsNonASCII(item.title) {
            let py = pinyinVariants(of: item.title)
            if !py.full.isEmpty {
                fields.append(IndexedField(text: py.full, words: py.syllables, weight: 0.78, allowFuzzy: true))
            }
            if !py.initials.isEmpty {
                fields.append(IndexedField(text: py.initials, words: [py.initials], weight: 0.68, allowFuzzy: false))
            }
        }

        let normKeywords = item.keywords.map(normalize).filter { !$0.isEmpty }
        if !normKeywords.isEmpty {
            let joined = normKeywords.joined(separator: " ")
            fields.append(IndexedField(text: joined, words: normKeywords.flatMap(splitWords), weight: 0.85, allowFuzzy: true))
        }

        let normSection = normalize(item.section)
        if !normSection.isEmpty {
            fields.append(IndexedField(text: normSection, words: splitWords(normSection), weight: 0.70, allowFuzzy: false))
        }

        let normSubtitle = normalize(item.subtitle)
        if !normSubtitle.isEmpty {
            fields.append(IndexedField(text: normSubtitle, words: splitWords(normSubtitle), weight: 0.50, allowFuzzy: false))
        }

        return fields
    }

    private static func matchScore(token: String, in field: IndexedField) -> Double {
        let text = field.text
        guard !text.isEmpty, !token.isEmpty else { return 0 }

        if text == token {
            return 1000
        }
        if text.hasPrefix(token) {
            let ratio = Double(token.count) / Double(max(text.count, 1))
            return 850 + ratio * 50
        }
        for (idx, word) in field.words.enumerated() {
            if word == token {
                return 820 - Double(min(idx, 10)) * 5
            }
            if word.hasPrefix(token) {
                return 750 - Double(min(idx, 10)) * 5
            }
        }
        if let range = text.range(of: token) {
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            return max(560, 650 - Double(offset) * 2)
        }

        guard field.allowFuzzy else { return 0 }

        // 1-edit-distance typo tolerance on individual words (only for tokens >= 4 chars).
        if token.count >= 4 {
            for word in field.words where word.count >= 4 && abs(word.count - token.count) <= 1 {
                if isOneEditAway(token, word) {
                    return 340
                }
            }
        }

        // Ordered subsequence match for abbreviations (e.g. "dmk" -> "danmaku").
        if token.count >= 3 {
            return subsequenceScore(token: token, in: text)
        }
        return 0
    }

    // MARK: - String Helpers

    static func tokenize(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitWords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func containsNonASCII(_ text: String) -> Bool {
        text.unicodeScalars.contains { !$0.isASCII }
    }

    private static func pinyinVariants(of text: String) -> (full: String, initials: String, syllables: [String]) {
        let latin: String
        if let known = transliterations.object(forKey: text as NSString) {
            latin = known as String
        } else {
            latin = text.applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)?
                .lowercased() ?? ""
            transliterations.setObject(latin as NSString, forKey: text as NSString)
        }

        let syllables = latin.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let full = syllables.joined()
        let initials = String(syllables.compactMap(\.first))
        return (full, initials, syllables)
    }
    /// Transliterating takes milliseconds a title, too slow to redo for every title on every keystroke; the titles
    /// are the same each time.
    nonisolated(unsafe) private static let transliterations = NSCache<NSString, NSString>()

    private static func subsequenceScore(token: String, in text: String) -> Double {
        let queryChars = Array(token)
        let textChars = Array(text)
        var qi = 0
        var consecutive = 0
        var maxConsecutive = 0
        var firstMatch = -1
        var lastMatch = -1

        for (ti, ch) in textChars.enumerated() {
            if ch == queryChars[qi] {
                if firstMatch == -1 { firstMatch = ti }
                if lastMatch == ti - 1 {
                    consecutive += 1
                } else {
                    consecutive = 1
                }
                if consecutive > maxConsecutive { maxConsecutive = consecutive }
                lastMatch = ti
                qi += 1
                if qi == queryChars.count {
                    let span = lastMatch - firstMatch + 1
                    let density = Double(queryChars.count) / Double(max(span, 1))
                    // Capped strictly below substring match (560).
                    return min(480, 220 + Double(maxConsecutive) * 35 + density * 120)
                }
            }
        }
        return 0
    }

    private static func isOneEditAway(_ a: String, _ b: String) -> Bool {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count
        if abs(n - m) > 1 { return false }

        if n == m {
            var diffs: [Int] = []
            for i in 0..<n where aChars[i] != bChars[i] {
                diffs.append(i)
                if diffs.count > 2 { return false }
            }
            if diffs.count == 1 { return true }
            // Adjacent transposition (e.g. "danamku" vs "danmaku").
            if diffs.count == 2, diffs[1] == diffs[0] + 1 {
                return aChars[diffs[0]] == bChars[diffs[1]] && aChars[diffs[1]] == bChars[diffs[0]]
            }
            return false
        }

        // One insertion / deletion.
        let shorter = n < m ? aChars : bChars
        let longer = n < m ? bChars : aChars
        var si = 0, li = 0
        var skipped = false
        while si < shorter.count && li < longer.count {
            if shorter[si] == longer[li] {
                si += 1
                li += 1
            } else if skipped {
                return false
            } else {
                skipped = true
                li += 1
            }
        }
        return true
    }
}
