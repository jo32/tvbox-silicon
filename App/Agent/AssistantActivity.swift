import Foundation
import TVCore

/// How a tool call reads in the conversation: "Searching “庆余年”…" while it runs, "Searched “庆余年”" after, with a
/// symbol. Tools are told apart by their name's first word (`search_videos`, `settings_set`, `favorites_add`), so a
/// new tool reads sensibly before it has words of its own.
struct AssistantActivity {
    let symbol: String
    let running: String
    let done: String

    init(_ call: AgentToolCall) {
        let arguments = (try? JSONDecoder().decode([String: JSONValue].self, from: Data(call.arguments.utf8))) ?? [:]
        let subject = Self.subject(arguments)
        let name = call.name
        func pick(_ symbol: String, _ running: String, _ done: String, _ runningWith: String? = nil, _ doneWith: String? = nil) -> (String, String, String) {
            if let subject, let runningWith, let doneWith {
                return (symbol, L10n.text(runningWith, subject), L10n.text(doneWith, subject))
            }
            return (symbol, L10n.text(running), L10n.text(done))
        }
        let (symbol, running, done): (String, String, String) = {
            switch name {
            case "app_state": return pick("eye", "Looking at the app…", "Looked at the app")
            case "open_page", "settings_open": return pick("arrow.up.forward.square", "Opening the page…", "Opened the page", "Opening %@…", "Opened %@")
            case "settings_search", "settings_get": return pick("gearshape", "Looking in Settings…", "Looked in Settings", "Looking for “%@” in Settings…", "Looked for “%@” in Settings")
            case "settings_set": return pick("gearshape.2", "Changing a setting…", "Changed a setting", "Changing %@…", "Changed %@")
            case "search_videos": return pick("magnifyingglass", "Searching…", "Searched", "Searching “%@”…", "Searched “%@”")
            case "video_details": return pick("info.circle", "Reading the details…", "Read the details", "Reading about %@…", "Read about %@")
            case "play": return pick("play.fill", "Starting playback…", "Started playback", "Playing %@…", "Played %@")
            case "player_control": return pick("playpause", "Controlling the player…", "Controlled the player")
            case "scripts_list": return pick("doc.text", "Listing your scripts…", "Listed your scripts")
            case "script_read": return pick("doc.text.magnifyingglass", "Reading the script…", "Read the script", "Reading %@…", "Read %@")
            case "script_write": return pick("square.and.pencil", "Editing the script…", "Edited the script", "Editing %@…", "Edited %@")
            case "script_test": return pick("checkmark.seal", "Testing the script…", "Tested the script", "Testing %@…", "Tested %@")
            case "discover_open": return pick("arrow.up.forward.square", "Opening the page…", "Opened the page", "Opening %@…", "Opened %@")
            case "recent_log": return pick("list.bullet.rectangle", "Reading the recent log…", "Read the recent log")
            default: break
            }
            switch name.split(separator: "_").first.map(String.init) ?? name {
            case "history": return pick("clock.arrow.circlepath", "Checking your history…", "Checked your history")
            case "favorites": return pick("heart", "Checking your favorites…", "Checked your favorites")
            case "downloads": return pick("arrow.down.circle", "Checking your downloads…", "Checked your downloads")
            case "subscriptions", "subscription": return pick("list.bullet.rectangle", "Checking your subscriptions…", "Checked your subscriptions")
            case "sources", "source": return pick("square.grid.2x2", "Checking sources…", "Checked sources", "Checking %@…", "Checked %@")
            case "live": return pick("dot.radiowaves.left.and.right", "Looking in Live TV…", "Looked in Live TV", "Looking for “%@” in Live TV…", "Looked for “%@” in Live TV")
            case "music": return pick("music.note", "Looking in Music…", "Looked in Music", "Looking for “%@” in Music…", "Looked for “%@” in Music")
            case "novels", "novel": return pick("text.book.closed", "Looking in Novels…", "Looked in Novels", "Looking for “%@” in Novels…", "Looked for “%@” in Novels")
            case "discover": return pick("film.stack", "Looking in Discover…", "Looked in Discover", "Looking for “%@” in Discover…", "Looked for “%@” in Discover")
            case "manga": return pick("book", "Looking in Manga…", "Looked in Manga", "Looking for “%@” in Manga…", "Looked for “%@” in Manga")
            default: return ("wrench.and.screwdriver", L10n.text("Using %@…", name), L10n.text("Used %@", name))
            }
        }()
        self.symbol = symbol; self.running = running; self.done = done
    }

    /// What the call is about, for its line: the words searched for, the script or the page.
    private static func subject(_ arguments: [String: JSONValue]) -> String? {
        for key in ["query", "keyword", "title", "name", "page", "section", "setting", "key", "source"] {
            if let text = arguments[key]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text.count > 40 ? String(text.prefix(40)) + "…" : text
            }
        }
        return nil
    }

    /// JSON text indented for reading, or as it came when it isn't JSON.
    static func pretty(_ text: String) -> String {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: pretty, encoding: .utf8) else { return text }
        return string
    }
}
