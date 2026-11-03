import Foundation

public struct PlaybackChoice: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let address: String
    static func parse(_ value: JSONValue?, prefix: String = "", fallbackName: String) -> [PlaybackChoice] {
        if let text = value?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [PlaybackChoice(id: 0, name: fallbackName, address: prefix + text)]
        }
        guard let values = value?.array else { return [] }
        var choices: [PlaybackChoice] = []
        for index in stride(from: 0, to: values.count - values.count % 2, by: 2) {
            guard let name = values[index].string, let address = values[index + 1].string,
                  !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            choices.append(PlaybackChoice(id: index / 2, name: name.isEmpty ? fallbackName : name, address: prefix + address))
        }
        return choices
    }
}

public struct PlaybackPlan: Sendable {
    public let choices: [PlaybackChoice]
    public let headers: [String: String]
    public let group: String
    public let requiresWebDetection: Bool
    /// Site click when that is non-empty, otherwise the play result click.
    public let click: String
    /// `json:` or `parse:` copied off the front of the address. Empty when the prefix is already joined on, or there is none.
    public let webPlayURL: String
    /// The play result's subtitle files (`subs`).
    public let subtitles: [ExternalSubtitle]
    public init(choices: [PlaybackChoice], headers: [String: String], group: String, requiresWebDetection: Bool, click: String = "", webPlayURL: String = "",
                subtitles: [ExternalSubtitle] = []) {
        self.choices = choices
        self.headers = headers
        self.group = group
        self.requiresWebDetection = requiresWebDetection
        self.click = click
        self.webPlayURL = webPlayURL
        self.subtitles = subtitles
    }
}
