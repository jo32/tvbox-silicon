import Foundation
import Observation

/// A drive sign-in a plugin is waiting for: Baidu Netdisk or Aliyun Drive, or a drive a Wex-family
/// plugin signs in to through its own config center (OwnDriveSignIn.java). The plugin signs in itself
/// and saves the account; it only needs someone to scan its QR code, which this host can't show
/// in an Android dialog. The plugin runtime leaves the code in the source's session folder
/// (`login-prompt.json`, see LoginPrompt.java) and the app shows it while the request runs.
@MainActor @Observable public final class PluginSignIn {
    public static let shared = PluginSignIn()
    nonisolated static let fileName = "login-prompt.json"
    /// Left for the plugin runtime when the viewer signed in on the drive's own page instead (LoginPrompt.java).
    nonisolated static let appFileName = "app-signed-in"

    public struct Prompt: Identifiable, Equatable, Sendable {
        public let id: String
        /// `baidu`, `aliyun`, or the Wex provider: `quark`, `pan115`, `pan189`, `guangya`.
        public let drive: String
        /// Baidu serves its code as an image.
        public let image: URL?
        /// Aliyun gives the text to encode.
        public let content: String?
        /// When the plugin stops waiting.
        public let expires: Date
        public let source: String
        let file: URL

        static func signedIn(_ data: Data) -> Bool {
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["signedIn"] as? Bool == true
        }

        init?(data: Data, file: URL, source: String) {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let drive = json["drive"] as? String, let time = json["time"] as? Double else { return nil }
            image = (json["image"] as? String).flatMap(URL.init(string:))
            content = json["content"] as? String
            guard image != nil || content != nil else { return nil }
            self.drive = drive; self.source = source; self.file = file
            id = file.path + "#" + String(Int(time))
            expires = Date(timeIntervalSince1970: time / 1000 + ((json["seconds"] as? Double) ?? 180))
        }

        #if DEBUG
        /// A made-up prompt for QA screenshots.
        public static func sample(drive: String) -> Prompt? {
            let json: [String: Any] = ["drive": drive, "time": Date().timeIntervalSince1970 * 1000, "content": "https://passport.aliyundrive.com/qrcodeCheck.htm?lgToken=qa-sample"]
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
            return Prompt(data: data, file: FileManager.default.temporaryDirectory.appendingPathComponent("qa-sign-in/" + PluginSignIn.fileName), source: "QA Source")
        }
        #endif
    }

    public private(set) var prompt: Prompt?
    /// Codes the viewer closed; the same code is not shown again.
    private var dismissed: Set<String> = []

    public func dismiss() {
        if let prompt { dismissed.insert(prompt.id) }
        prompt = nil
    }

    /// The viewer signed in to the prompt's drive on its own page in the app (iPhone, iPad), and the
    /// account is saved: the waiting request starts over and reads it.
    public func signedInHere(_ prompt: Prompt) {
        // A request that already ended has nothing waiting; the next one reads the saved account anyway.
        guard self.prompt?.id == prompt.id else { return }
        let marker = prompt.file.deletingLastPathComponent().appendingPathComponent(Self.appFileName)
        try? Data().write(to: marker, options: .atomic)
        Diagnostics.shared.record(.info, "cloud.signin", "source=\(prompt.source) drive=\(prompt.drive) signed in on the page")
        dismiss()
    }

    private func show(_ value: Prompt) {
        guard !dismissed.contains(value.id), value.expires > Date() else { return }
        prompt = value
    }

    private func finish(_ file: URL) {
        if prompt?.file == file { prompt = nil }
    }

    /// Watches one plugin request for sign-in codes until `end()`.
    struct Watch: Sendable {
        let file: URL
        let task: Task<Void, Never>
        func end() async {
            task.cancel()
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent(PluginSignIn.appFileName))
            await PluginSignIn.shared.finish(file)
        }
    }

    /// Read fresh each time: URL resource values are cached, and a later write would go unseen.
    nonisolated private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    nonisolated static func watch(folder: URL, source: String) -> Watch {
        let file = folder.appendingPathComponent(fileName)
        // A code already there belongs to an earlier request.
        let earlier = modified(file)
        let task = Task.detached(priority: .utility) {
            var seen = earlier
            while !Task.isCancelled {
                if let date = modified(file),
                   date != seen, let data = try? Data(contentsOf: file) {
                    seen = date
                    if let prompt = Prompt(data: data, file: file, source: source) {
                        Diagnostics.shared.record(.info, "cloud.signin", "source=\(source) drive=\(prompt.drive) code shown")
                        await PluginSignIn.shared.show(prompt)
                    } else if Prompt.signedIn(data) {
                        // Scanned and confirmed: the source restarts with the account and the video loads.
                        // The account becomes the app's, so other sources don't ask again.
                        Diagnostics.shared.record(.info, "cloud.signin", "source=\(source) signed in")
                        if let notice = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { CloudDriveAccounts.adopt(notice) }
                        await PluginSignIn.shared.finish(file)
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        return Watch(file: file, task: task)
    }
}
