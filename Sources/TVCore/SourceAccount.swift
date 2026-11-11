import Foundation

/// A sign-in to the service behind one of the recommended sources, for a source whose entry says it takes one
/// (`yingxia.account` names it, `yingxia.signIn` says how). The app knows no service: the source's own script
/// gives the code to scan and reads the answers (its `account` function), and the app shows the code and keeps
/// what comes back on this device, to hand to that source alone (`SourceAccounts`).
public struct SourceAccount: Codable, Equatable, Sendable {
    /// The service's cookies for the signed-in session, as the script returned them.
    public var cookie = ""
    public var name = ""
    public init(cookie: String = "", name: String = "") { self.cookie = cookie; self.name = name }
    public var signedIn: Bool { !cookie.isEmpty }

    /// `id` names the folder, so only plain names are accounts.
    static func valid(_ id: String) -> Bool { !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }

    static func fileURL(_ id: String) -> URL {
        #if os(tvOS)
        // tvOS only permits Caches; `load` restores a purged copy from user defaults.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        // One folder per account, named after it with a capital, as versions up to 1.8.17 already kept theirs.
        return base.appendingPathComponent("com.tvbox.yingxia/\(id.prefix(1).uppercased() + id.dropFirst())/account.json")
    }
    private static func defaultsKey(_ id: String) -> String { id + "Account" }

    public static func load(_ id: String) -> Self {
        guard valid(id) else { return Self() }
        if let data = try? Data(contentsOf: fileURL(id)), let account = try? JSONDecoder().decode(Self.self, from: data) { return account }
        #if os(tvOS)
        if let data = UserDefaults.standard.data(forKey: defaultsKey(id)), let account = try? JSONDecoder().decode(Self.self, from: data) {
            try? account.save(id)
            return account
        }
        #endif
        return Self()
    }

    public func save(_ id: String) throws {
        guard Self.valid(id) else { throw TVError.invalidConfiguration }
        let file = Self.fileURL(id), folder = file.deletingLastPathComponent()
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #if os(tvOS)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey(id))
        #endif
    }

    public static func signOut(_ id: String) {
        guard valid(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(id))
        UserDefaults.standard.removeObject(forKey: defaultsKey(id))
    }
}

/// How a source that takes an account signs in, from its entry (`yingxia.signIn`).
public struct SourceSignIn: Identifiable, Sendable {
    /// The account's name (`yingxia.account`).
    public let id: String
    public let site: Site
    let notes: [String: String]
    let signedInNotes: [String: String]

    init?(site: Site) {
        guard let id = site.account, SourceAccount.valid(id), let signIn = site.yingxia["signIn"]?.object, signIn["kind"]?.string == "qr" else { return nil }
        self.id = id; self.site = site
        notes = signIn["note"]?.object?.compactMapValues(\.string) ?? [:]
        signedInNotes = signIn["signedIn"]?.object?.compactMapValues(\.string) ?? [:]
    }

    /// The sources of the latest copy of the recommended sources' subscription that sign in this way.
    public static var all: [SourceSignIn] { (CloudSources.current?.sites ?? []).compactMap(SourceSignIn.init(site:)) }

    /// The service's name, as the source is called.
    public var name: String { site.name }
    /// What to tell someone about to sign in, in the source's words.
    public var note: String? { Self.pick(notes) }
    /// What to tell someone who has signed in.
    public var signedInNote: String? { Self.pick(signedInNotes) }
    private static func pick(_ texts: [String: String]) -> String? { (texts[L10n.resolvedLanguage()] ?? texts["en"]).flatMap { $0.isEmpty ? nil : $0 } }

    public enum Status: Sendable, Equatable { case waiting, scanned, expired, signedIn(SourceAccount) }

    /// A code to show, and the token that asks about it.
    public struct Code: Sendable, Equatable {
        /// The text to encode in the QR code.
        public let code: String
        let token: String
    }

    private func ask(_ request: String, _ input: [String: String] = [:]) async throws -> [String: JSONValue] {
        let text = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        return try await ScriptRuntime.shared.request(site: site, scriptURL: try WebAddress.resolve(site.api, relativeTo: CloudSources.address),
                                                      params: ["account": request, "input": text], http: HTTPClient(), origin: CloudSources.address)
    }

    public func start() async throws -> Code {
        let reply = try await ask("start")
        guard let code = reply["code"]?.string, !code.isEmpty, let token = reply["token"]?.string, !token.isEmpty else {
            throw TVError.unsupported(L10n.text("Couldn't get a sign-in code. Try again."))
        }
        return Code(code: code, token: token)
    }

    /// Asks whether the code was scanned; a finished sign-in is saved before it is returned.
    public func poll(_ code: Code) async throws -> Status {
        let reply = try await ask("poll", ["token": code.token])
        switch reply["status"]?.string {
        case "waiting": return .waiting
        case "scanned": return .scanned
        case "signedIn":
            guard let cookie = reply["cookie"]?.string, !cookie.isEmpty else { return .expired }
            let account = SourceAccount(cookie: cookie, name: reply["name"]?.string ?? "")
            try account.save(id)
            return .signedIn(account)
        default: return .expired
        }
    }

    /// The saved sign-in with its current name, or nil when the service no longer accepts it. A source that can't
    /// be asked right now says nothing about the sign-in.
    public func refreshed(_ account: SourceAccount) async -> SourceAccount? {
        guard account.signedIn else { return nil }
        guard let reply = try? await ask("check", ["cookie": account.cookie]) else { return account }
        if case .bool(false)? = reply["valid"] { return nil }
        var current = account
        if let name = reply["name"]?.string, !name.isEmpty { current.name = name }
        return current
    }
}
