import Foundation

/// What a plugin shows for one of its settings (a listed title with an `action`, as TVBox runs it with
/// `Spider.action`). Plugins draw these with Android dialogs and views on TVBox's Activity; the JAR host keeps
/// those views and describes them here, the app draws them, and the viewer's taps and edits go back to the
/// plugin's own listeners (`CatalogClient.pluginWindow`). Nothing here knows any plugin.
public struct PluginScreen: Equatable, Sendable {
    /// Open windows, the topmost last.
    public var windows: [PluginWindow]
    /// The plugin's toasts since the last answer.
    public var notices: [String]
    /// Pages the plugin opened (a browser page, another app).
    public var links: [URL]
    /// The setting's own answer (`msg`), when it ran without a window.
    public var message: String?
    /// Text the plugin copied, for the device's pasteboard.
    public var clipboard: String?
    /// Why the setting showed nothing: the error that ended the plugin's thread.
    public var error: String?

    public init(windows: [PluginWindow] = [], notices: [String] = [], links: [URL] = [], message: String? = nil,
                clipboard: String? = nil, error: String? = nil) {
        self.windows = windows; self.notices = notices; self.links = links; self.message = message
        self.clipboard = clipboard; self.error = error
    }

    init(json: [String: JSONValue]) {
        let ui = json["ui"]?.object ?? [:]
        windows = (ui["windows"]?.array ?? []).compactMap { $0.object.map(PluginWindow.init(json:)) }
        links = (ui["links"]?.array ?? []).compactMap { $0.string.flatMap(URL.init(string:)) }
        notices = (json["notices"]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        message = json["msg"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).pluginNonEmpty
        clipboard = ui["clipboard"]?.string?.pluginNonEmpty
        error = json["error"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).pluginNonEmpty
    }
}

public struct PluginWindow: Equatable, Sendable, Identifiable {
    public enum Choice: String, Sendable { case plain, single, multi }
    public struct Item: Equatable, Sendable { public let text: String; public let checked: Bool? }
    public struct Button: Equatable, Sendable, Identifiable {
        public enum Role: String, Sendable { case positive, negative, neutral }
        public let id: Int
        public let text: String
        public let role: Role
        public let enabled: Bool
    }
    public let id: Int
    public let title: String?
    public let message: String?
    public let cancelable: Bool
    public let background: PluginColor?
    public let header: PluginNode?
    public let root: PluginNode?
    public let items: [Item]
    public let choice: Choice
    public let buttons: [Button]
    public let progress: PluginNode?

    init(json: [String: JSONValue]) {
        id = json["id"]?.int ?? -1
        title = json["title"]?.string?.pluginNonEmpty
        message = json["message"]?.string?.pluginNonEmpty
        cancelable = json["cancelable"].flatMap(\.pluginFlag) ?? true
        background = json["background"]?.string.flatMap(PluginColor.init(hex:))
        header = json["header"]?.object.map(PluginNode.init(json:))
        root = json["root"]?.object.map(PluginNode.init(json:))
        items = (json["items"]?.array ?? []).compactMap { $0.object }.map { Item(text: $0["text"]?.string ?? "", checked: $0["checked"].flatMap(\.pluginFlag)) }
        choice = json["choice"]?.string.flatMap(Choice.init(rawValue:)) ?? .plain
        buttons = (json["buttons"]?.array ?? []).compactMap { $0.object }.compactMap { button in
            guard let id = button["id"]?.int else { return nil }
            return Button(id: id, text: button["text"]?.string ?? "", role: button["role"]?.string.flatMap(Button.Role.init(rawValue:)) ?? .neutral,
                          enabled: button["enabled"].flatMap(\.pluginFlag) ?? true)
        }
        progress = json["progress"]?.object.map(PluginNode.init(json:))
    }

    /// The color the plugin paints the window with: its own, or its content's.
    public var surface: PluginColor? { background ?? root?.background }
}

/// One view in a plugin window.
public struct PluginNode: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case stack, scroll, text, button, input, check, `switch`, radio, radios, progress, slider, image, view }
    public enum Axis: String, Sendable { case v, h, z }
    public let id: Int
    public let kind: Kind
    public let axis: Axis
    public let text: String?
    public let hint: String?
    public let color: PluginColor?
    public let background: PluginColor?
    /// Text size in Android sp.
    public let size: Double?
    public let bold: Bool
    public let lines: Int?
    /// Android Gravity bits.
    public let gravity: Int?
    public let tappable: Bool
    public let enabled: Bool
    public let selected: Bool
    public let checked: Bool
    public let secure: Bool
    public let keyboard: String?
    public let multiline: Bool
    public let image: Data?
    /// A picture the plugin reads touches on (a color wheel): a tap sends where it landed.
    public let touch: Bool
    /// Fills its image frame (center-crop or stretch) rather than fitting in it.
    public let fill: Bool
    /// Size in Android dp, when the plugin set one.
    public let width: Double?
    public let height: Double?
    public let fillWidth: Bool
    public let weight: Double?
    public let alpha: Double?
    /// The plugin's padding in dp: leading, top, trailing, bottom.
    public let padding: [Double]?
    public let minimum: Int
    public let maximum: Int
    public let progress: Int
    public let step: Int
    public let indeterminate: Bool
    public let children: [PluginNode]

    init(json: [String: JSONValue]) {
        id = json["id"]?.int ?? 0
        kind = json["type"]?.string.flatMap(Kind.init(rawValue:)) ?? .view
        axis = json["axis"]?.string.flatMap(Axis.init(rawValue:)) ?? .v
        text = json["text"]?.string
        hint = json["hint"]?.string?.pluginNonEmpty
        color = json["color"]?.string.flatMap(PluginColor.init(hex:))
        background = json["background"]?.string.flatMap(PluginColor.init(hex:))
        size = json["size"]?.double
        bold = json["bold"].flatMap(\.pluginFlag) ?? false
        lines = json["lines"]?.int
        gravity = json["gravity"]?.int
        tappable = json["tappable"].flatMap(\.pluginFlag) ?? false
        enabled = json["enabled"].flatMap(\.pluginFlag) ?? true
        selected = json["selected"].flatMap(\.pluginFlag) ?? false
        checked = json["checked"].flatMap(\.pluginFlag) ?? false
        secure = json["secure"].flatMap(\.pluginFlag) ?? false
        keyboard = json["keyboard"]?.string
        multiline = json["multiline"].flatMap(\.pluginFlag) ?? false
        image = json["image"]?.string.flatMap { Data(base64Encoded: $0) }
        touch = json["touch"].flatMap(\.pluginFlag) ?? false
        fill = json["fill"].flatMap(\.pluginFlag) ?? false
        width = json["width"]?.double
        height = json["height"]?.double
        fillWidth = json["fillWidth"].flatMap(\.pluginFlag) ?? false
        weight = json["weight"]?.double
        alpha = json["alpha"]?.double
        padding = json["padding"]?.array.map { $0.compactMap(\.double) }.flatMap { $0.count == 4 ? $0 : nil }
        minimum = json["min"]?.int ?? 0
        maximum = json["max"]?.int ?? 100
        progress = json["progress"]?.int ?? 0
        step = max(1, json["step"]?.int ?? 1)
        indeterminate = json["indeterminate"].flatMap(\.pluginFlag) ?? false
        children = (json["children"]?.array ?? []).compactMap { $0.object.map(PluginNode.init(json:)) }
    }

    /// Text centered across the view (Gravity.CENTER_HORIZONTAL).
    public var centered: Bool { (gravity ?? 0) & 0x7 == 0x1 }
    /// Text against the trailing edge (Gravity.RIGHT or END).
    public var trailing: Bool { let g = gravity ?? 0; return g & 0x7 == 0x5 }
    /// Everything this view and its children say, for accessibility and list rows.
    public var spokenText: String {
        ([text].compactMap { $0?.pluginNonEmpty } + children.map(\.spokenText).filter { !$0.isEmpty }).joined(separator: ", ")
    }
}

/// An Android ARGB color.
public struct PluginColor: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double, alpha: Double
    public init?(hex: String) {
        guard hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16), hex.count == 9 else { return nil }
        alpha = Double(value >> 24 & 0xFF) / 255; red = Double(value >> 16 & 0xFF) / 255
        green = Double(value >> 8 & 0xFF) / 255; blue = Double(value & 0xFF) / 255
    }
    /// Perceived brightness, 0 (black) to 1 (white).
    public var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
}

/// The viewer's input to a plugin window.
public struct PluginEvent: Sendable {
    public enum Kind: String, Sendable {
        case click, submit, item, change, back, close, poll
        /// A tap at a point of a `touch` picture.
        case touch
        /// Closes every window, when the viewer leaves the setting.
        case closeAll
    }
    public enum Value: Sendable, Equatable { case text(String), on(Bool), number(Int) }
    public let window: Int
    public let kind: Kind
    public var view: Int?
    public var index: Int?
    /// Where a touch landed, as fractions (0...1) of the picture's width and height.
    public var x: Double?
    public var y: Double?
    /// Fields' current values by view id, applied before the tap runs.
    public var values: [Int: Value]

    public init(window: Int, kind: Kind, view: Int? = nil, index: Int? = nil, x: Double? = nil, y: Double? = nil, values: [Int: Value] = [:]) {
        self.window = window; self.kind = kind; self.view = view; self.index = index; self.x = x; self.y = y; self.values = values
    }

    var json: String {
        var object: [String: Any] = ["window": window, "kind": kind.rawValue]
        if let view { object["view"] = view }
        if let index { object["index"] = index }
        if let x, let y { object["x"] = min(1, max(0, x)); object["y"] = min(1, max(0, y)) }
        if !values.isEmpty {
            object["values"] = Dictionary(uniqueKeysWithValues: values.map { key, value -> (String, Any) in
                switch value { case .text(let text): (String(key), text); case .on(let on): (String(key), on); case .number(let n): (String(key), n) }
            })
        }
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private extension String {
    var pluginNonEmpty: String? { isEmpty ? nil : self }
}

private extension JSONValue {
    var pluginFlag: Bool? { if case .bool(let value) = self { value } else { nil } }
}
