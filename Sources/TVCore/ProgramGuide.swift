import Foundation

/// One programme in a live channel's guide (#802).
public struct Programme: Hashable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public init(title: String, start: Date, end: Date) { self.title = title; self.start = start; self.end = end }
}

extension Array where Element == Programme {
    /// The programme on at `date`. The schedule is in time order.
    public func now(at date: Date = Date()) -> Programme? { first { $0.start <= date && date < $0.end } }
    /// The first programme that starts after `date`.
    public func next(after date: Date = Date()) -> Programme? { first { $0.start > date } }
}

/// Where a live playlist's guide comes from: an XMLTV file for all its channels (an M3U's `x-tvg-url`), or an address
/// per channel with `{name}` and `{date}` in it, as DIYP players and TVBox's `epg` key give it.
public enum GuideAddress: Hashable, Sendable {
    case xmltv(URL)
    case perChannel(String)

    public init?(_ text: String, relativeTo origin: URL? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("{name}") {
            guard text.hasPrefix("http://") || text.hasPrefix("https://") else { return nil }
            self = .perChannel(text)
        } else {
            guard !text.isEmpty, let url = try? WebAddress.resolve(text, relativeTo: origin),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            self = .xmltv(url)
        }
    }

    /// A per-channel address for `name` on the day of `date`, in China's time zone as those servers keep it.
    public func address(for name: String, on date: Date, timeZone: TimeZone = ProgramGuide.chinaTime) -> URL? {
        guard case let .perChannel(template) = self else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return URL(string: template
            .replacingOccurrences(of: "{name}", with: name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
            .replacingOccurrences(of: "{date}", with: ProgramGuide.dayString(date, timeZone: timeZone)))
    }
}

/// What's on a playlist's channels, by a key of each name and id the guide gives a channel (#802).
public struct ProgramGuide: Sendable {
    /// Programmes in time order, by `key(_:)`.
    let schedules: [String: [Programme]]
    public var isEmpty: Bool { schedules.isEmpty }

    /// The channel's programmes: by its `tvg-id`/`tvg-name`, else by its name.
    public func schedule(for channel: Channel) -> [Programme]? {
        for name in [channel.guideID, channel.name].compactMap({ $0 }) {
            if let found = schedules[Self.key(name)] { return found }
        }
        return nil
    }

    /// The keys a guide's channels are looked up by, for the channels a playlist lists.
    public static func wanted(_ channels: [Channel]) -> Set<String> {
        var keys = Set<String>()
        for channel in channels {
            keys.insert(key(channel.name))
            if let id = channel.guideID { keys.insert(key(id)) }
        }
        return keys
    }

    /// One key for the ways playlists and guides write a channel's name: "CCTV-1 综合", "CCTV1 高清" and "cctv1" are
    /// one channel, as are "湖南卫视HD" and "湖南卫视".
    public static func key(_ name: String) -> String {
        let folded = (name.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? name).lowercased()
        var text = String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "+" }))
        if text.hasPrefix("cctv") {
            let rest = text.dropFirst(4)
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if !digits.isEmpty {
                let after = rest.dropFirst(digits.count).first
                return "cctv" + digits + (after == "+" || after == "k" ? String(after!) : "")
            }
        }
        var trimmed = true
        while trimmed {
            trimmed = false
            for suffix in ["高清", "超清", "标清", "蓝光", "频道", "fhd", "uhd", "hd", "4k", "8k"]
            where text.count > suffix.count && text.hasSuffix(suffix) {
                text.removeLast(suffix.count)
                trimmed = true
            }
        }
        return text
    }

    // MARK: XMLTV

    /// An XMLTV file (gzipped or not), keeping the programmes of the `wanted` channels (all when nil) that are on
    /// between `from` and `to`.
    public static func xmltv(_ data: Data, wanted: Set<String>?, from: Date, to: Date) throws -> ProgramGuide {
        let xml: Data
        if data.starts(with: [0x1F, 0x8B]) {
            guard let inflated = LoadedLivePlugin.inflate(data, format: "gzip") else { throw TVError.invalidConfiguration }
            xml = inflated
        } else {
            xml = data
        }
        let reader = XMLTVReader(wanted: wanted, from: from, to: to)
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        // A guide cut short (a dropped connection, a bad character near the end) keeps what was read.
        if !parser.parse(), reader.programmes.isEmpty { throw parser.parserError ?? TVError.invalidConfiguration }
        var schedules: [String: [Programme]] = [:]
        for (id, list) in reader.programmes {
            let keys = reader.channelKeys[id] ?? [key(id)]
            let sorted = closingGaps(list.sorted { $0.start < $1.start })
            for key in keys where schedules[key] == nil && (wanted?.contains(key) ?? true) { schedules[key] = sorted }
        }
        return ProgramGuide(schedules: schedules)
    }

    /// `20261114083000 +0800`.
    static func xmltvDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard let stamp = parts.first?.utf8.map({ Int($0) - 48 }), stamp.count >= 12, stamp.prefix(14).allSatisfy({ (0...9).contains($0) })
        else { return nil }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + stamp[$1] } }
        var offset = 0
        if parts.count > 1 {
            let zone = Array(parts[1].utf8)
            let digits = zone.dropFirst().map { Int($0) - 48 }
            if zone.count == 5, zone[0] == UInt8(ascii: "+") || zone[0] == UInt8(ascii: "-"), digits.allSatisfy({ (0...9).contains($0) }) {
                offset = ((digits[0] * 10 + digits[1]) * 60 + digits[2] * 10 + digits[3]) * 60 * (zone[0] == UInt8(ascii: "-") ? -1 : 1)
            }
        }
        let days = daysFromCivil(number(0..<4), number(4..<6), number(6..<8))
        let seconds = days * 86_400 + number(8..<10) * 3600 + number(10..<12) * 60 + (stamp.count >= 14 ? number(12..<14) : 0) - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's `days_from_civil`).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        return era * 146_097 + yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear - 719_468
    }

    /// A programme without an end runs until the next one starts; the last one, an hour.
    static func closingGaps(_ sorted: [Programme]) -> [Programme] {
        sorted.indices.compactMap { index in
            let item = sorted[index]
            guard item.end == .distantFuture else { return item.end > item.start ? item : nil }
            let end = index + 1 < sorted.count ? sorted[index + 1].start : item.start.addingTimeInterval(3600)
            return end > item.start ? Programme(title: item.title, start: item.start, end: end) : nil
        }
    }

    // MARK: DIYP

    public static let chinaTime = TimeZone(identifier: "Asia/Shanghai")!

    /// `2026-11-14` in China's time zone.
    static func dayString(_ date: Date, timeZone: TimeZone = chinaTime) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// A DIYP answer, `{"epg_data": [{"start": "19:00", "end": "19:30", "title": "…"}]}`, for the day of `date` in
    /// China's time zone.
    public static func diyp(_ data: Data, on date: Date, timeZone: TimeZone = chinaTime) -> [Programme] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["epg_data"] as? [[String: Any]] else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: date)
        func time(_ value: Any?) -> TimeInterval? {
            guard let text = value as? String else { return nil }
            let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 2, (0...24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
            return TimeInterval(parts[0] * 3600 + parts[1] * 60)
        }
        var list: [Programme] = []
        for entry in entries {
            guard let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let start = time(entry["start"]) else { continue }
            let from = start == 86400 ? (calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(start))
                : (calendar.date(bySettingHour: Int(start) / 3600, minute: Int(start) % 3600 / 60, second: 0, of: midnight) ?? midnight.addingTimeInterval(start))
            var end = time(entry["end"]).map { value in
                value == 86400 ? (calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(value))
                    : (calendar.date(bySettingHour: Int(value) / 3600, minute: Int(value) % 3600 / 60, second: 0, of: midnight) ?? midnight.addingTimeInterval(value))
            } ?? .distantFuture
            // A programme that runs past midnight ends "the next day" at an earlier time.
            if end <= from { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end.addingTimeInterval(86_400) }
            list.append(Programme(title: title, start: from, end: end))
        }
        return closingGaps(list.sorted { $0.start < $1.start })
    }
}

/// Reads `<channel>` names and `<programme>` entries as XMLParser goes, keeping only what's asked for, so a guide of
/// thousands of channels and a week of days doesn't stay in memory.
private final class XMLTVReader: NSObject, XMLParserDelegate {
    let wanted: Set<String>?
    let from: Date, to: Date
    /// The keys of each `<channel id>`'s id and display names.
    var channelKeys: [String: [String]] = [:]
    var programmes: [String: [Programme]] = [:]
    private var kept: [String: Bool] = [:]
    private var channel: String?
    private var keys: [String] = []
    private var programme: (channel: String, start: Date, end: Date)?
    private var title: String?
    private var text = ""
    private var reading = false

    init(wanted: Set<String>?, from: Date, to: Date) { self.wanted = wanted; self.from = from; self.to = to }

    private func keeps(_ id: String) -> Bool {
        if let known = kept[id] { return known }
        let keys = channelKeys[id] ?? [ProgramGuide.key(id)]
        let keep = wanted.map { wanted in keys.contains { wanted.contains($0) } } ?? true
        kept[id] = keep
        return keep
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch element {
        case "channel":
            channel = attributes["id"]
            keys = channel.map { [ProgramGuide.key($0)] } ?? []
        case "display-name" where channel != nil:
            text = ""; reading = true
        case "programme":
            guard let id = attributes["channel"], let start = ProgramGuide.xmltvDate(attributes["start"]) else { return }
            let end = ProgramGuide.xmltvDate(attributes["stop"]) ?? .distantFuture
            // Without an end, a programme that started over half a day before the window is long over.
            let over = end == .distantFuture ? start < from.addingTimeInterval(-43_200) : end <= from
            guard !over, start < to, keeps(id) else { return }
            programme = (id, start, end); title = nil
        case "title" where programme != nil && title == nil:
            text = ""; reading = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if reading { text += string } }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "display-name" where channel != nil:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { keys.append(ProgramGuide.key(name)) }
            reading = false
        case "channel":
            if let channel { channelKeys[channel] = keys }
            channel = nil; keys = []
        case "title" where programme != nil && title == nil:
            title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            reading = false
        case "programme":
            if let programme, let title, !title.isEmpty {
                programmes[programme.channel, default: []].append(Programme(title: title, start: programme.start, end: programme.end))
            }
            programme = nil; title = nil; reading = false
        default:
            break
        }
    }
}

/// Loads guides and keeps them a while, for the Live tab and the player (#802). XMLTV files are parsed here, off the
/// main thread.
public actor ProgramGuides {
    public static let shared = ProgramGuides()
    private struct Key: Hashable { let url: URL; let context: GuideRequestContext; let day: Date }
    private struct Loaded { let guide: ProgramGuide; let wanted: Set<String>; let expires: Date }
    private struct Day { let programmes: [Programme]; let expires: Date }
    private var guides: [Key: Loaded] = [:]
    private var loading: [Key: Task<Loaded, Error>] = [:]
    private var days: [Key: Day] = [:]
    private var failures: [Key: Date] = [:]

    /// Request/account and calendar-day namespaces prevent one source or day's guide from serving another.
    public func guide(_ url: URL, for channels: [Channel], context: GuideRequestContext = .init(), on date: Date = Date()) async throws -> ProgramGuide {
        let key = Key(url: url, context: context, day: context.day(date))
        let wanted = ProgramGuide.wanted(channels), now = Date()
        if let loaded = guides[key], loaded.wanted.isSuperset(of: wanted), now < loaded.expires { return loaded.guide }
        if let task = loading[key] {
            let loaded = try await task.value
            if loaded.wanted.isSuperset(of: wanted) { return loaded.guide }
        }
        if let retry = failures[key], now < retry { throw URLError(.resourceUnavailable) }
        let union = guides[key].map { now < $0.expires ? $0.wanted.union(wanted) : wanted } ?? wanted
        let task = Task {
            let response = try await GuideDownload.fetch(url, context: context)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = context.timeZone
            let to = calendar.date(byAdding: .day, value: 2, to: key.day) ?? key.day.addingTimeInterval(48 * 3600)
            let guide = try ProgramGuide.xmltv(response.data, wanted: union, from: key.day, to: to)
            return Loaded(guide: guide, wanted: union, expires: Date().addingTimeInterval(response.lifetime))
        }
        loading[key] = task
        defer { loading[key] = nil }
        do {
            let loaded = try await task.value
            failures[key] = nil
            if guides.count >= 4, let oldest = guides.min(by: { $0.value.expires < $1.value.expires })?.key { guides[oldest] = nil }
            guides[key] = loaded.expires > Date() ? loaded : nil
            return loaded.guide
        } catch {
            if !Self.cancelled(error) { recordFailure(key) }
            throw error
        }
    }

    /// Failures back off briefly; they never replace a successful day's schedule with a three-hour empty entry.
    public func schedule(_ address: GuideAddress, name: String, context: GuideRequestContext = .init(), on date: Date = Date()) async -> [Programme]? {
        let now = Date()
        guard let url = address.address(for: name, on: date, timeZone: context.timeZone) else { return [] }
        let key = Key(url: url, context: context, day: context.day(date))
        if let day = days[key], now < day.expires { return day.programmes }
        if let retry = failures[key], now < retry { return days[key]?.programmes ?? [] }
        do {
            let response = try await GuideDownload.fetch(url, context: context, limit: 20_000_000)
            let programmes = ProgramGuide.diyp(response.data, on: date, timeZone: context.timeZone)
            failures[key] = nil
            if days.count >= 600 { days = days.filter { now < $0.value.expires } }
            if days.count >= 600, let oldest = days.min(by: { $0.value.expires < $1.value.expires })?.key { days[oldest] = nil }
            days[key] = response.lifetime > 0 ? Day(programmes: programmes, expires: Date().addingTimeInterval(response.lifetime)) : nil
            return programmes
        } catch {
            if Self.cancelled(error) { return nil }
            recordFailure(key)
            return days[key]?.programmes ?? []
        }
    }

    private func recordFailure(_ key: Key) {
        let now = Date()
        if failures.count >= 600 { failures = failures.filter { now < $0.value } }
        if failures.count >= 600, let oldest = failures.min(by: { $0.value < $1.value })?.key { failures[oldest] = nil }
        failures[key] = now.addingTimeInterval(30)
    }

    private static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled
    }
}
