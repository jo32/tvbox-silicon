import Foundation

/// Separate viewing lives inside one install: separate libraries, separate play data, separate
/// reporting — and no leakage between them.
///
/// The privacy vault hides things from whoever is holding the phone. This is a different idea, and
/// Rex is explicit that it is different (`Environment.strings`): each environment owns its own
/// discovery page, play progress, watched flags, watchlist, favourites, libraries, modules, and
/// source collections, and deleting an environment deletes only that environment's. Libraries and
/// modules still used by another environment survive. Reporting can be turned off for one environment
/// without touching the others.
///
/// That distinction matters. Hiding is a *view* — the data is still there, one passcode away. An
/// environment is a *partition*: the data under another environment is not reachable at all, so
/// there is nothing to unlock into. A viewer who wants "my shows" and "the children's shows" to be
/// genuinely separate needs the second, not the first.
///
/// Scoping is by identifier rather than by copying storage: every record carries the environment it
/// belongs to, and reads filter on the active one. Copying would double the disk and make a shared
/// record (a subscription used by both) ambiguous.
public struct Environments: Codable, Hashable, Sendable {

    /// One partition.
    public struct Environment: Codable, Hashable, Sendable, Identifiable {
        public let id: UUID
        public var name: String
        /// Whether play progress and watch history are reported to the outside world.
        ///
        /// Per environment, because the reason to have a second one is usually that its activity
        /// should not appear anywhere.
        public var reportsActivity: Bool
        /// Whether Trakt (or an equivalent) syncs this environment. Only one may, so the pairing on
        /// the service side stays unambiguous.
        public var syncsExternally: Bool
        public let createdAt: Date

        public init(id: UUID = UUID(), name: String, reportsActivity: Bool = true,
                    syncsExternally: Bool = false, createdAt: Date = Date()) {
            self.id = id
            self.name = name
            self.reportsActivity = reportsActivity
            self.syncsExternally = syncsExternally
            self.createdAt = createdAt
        }
    }

    public private(set) var all: [Environment]
    /// The environment currently being viewed.
    public private(set) var activeID: UUID

    /// The default environment always exists and cannot be deleted: it holds everything created
    /// before environments were a feature.
    public static let defaultName = "Default"

    public init(all: [Environment] = [Environment(name: defaultName)], activeID: UUID? = nil) {
        let list = all.isEmpty ? [Environment(name: Self.defaultName)] : all
        self.all = list
        self.activeID = activeID.flatMap { id in list.contains { $0.id == id } ? id : nil } ?? list[0].id
    }

    // MARK: Reading

    public var active: Environment {
        all.first { $0.id == activeID } ?? all[0]
    }

    public func environment(_ id: UUID) -> Environment? { all.first { $0.id == id } }

    /// Whether a record belonging to `id` is visible right now.
    ///
    /// `nil` means the record predates environments; those belong to the default one so an upgrade
    /// does not hide a viewer's whole library.
    public func shows(_ id: UUID?) -> Bool {
        (id ?? all[0].id) == activeID
    }

    /// The id to stamp on a record created now.
    public var stamp: UUID { activeID }

    // MARK: Writing

    /// Switches environments. Returns false when the id is unknown, so a stale button does nothing.
    @discardableResult
    public mutating func activate(_ id: UUID) -> Bool {
        guard all.contains(where: { $0.id == id }) else { return false }
        activeID = id
        return true
    }

    /// Adds an environment and activates it. The new one does not report or sync by default: a
    /// second environment is usually made to keep something quiet.
    @discardableResult
    public mutating func add(name: String, reportsActivity: Bool = false,
                             syncsExternally: Bool = false) -> Environment {
        var environment = Environment(name: name, reportsActivity: reportsActivity,
                                      syncsExternally: syncsExternally)
        if syncsExternally { clearExternalSync(except: environment.id) }
        all.append(environment)
        activeID = environment.id
        return environment
    }

    /// Removes an environment. The default one is refused, because everything that predates the
    /// feature lives there and deleting it would take the viewer's whole library.
    ///
    /// Returns the ids whose records should be deleted. The caller owns storage, so this type only
    /// says what to remove — it does not reach into a database it knows nothing about.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard all.count > 1, id != all[0].id, all.contains(where: { $0.id == id }) else { return false }
        all.removeAll { $0.id == id }
        if activeID == id { activeID = all[0].id }
        return true
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        all[index].name = trimmed
    }

    public mutating func setReportsActivity(_ reports: Bool, for id: UUID) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].reportsActivity = reports
    }

    /// Turns on external sync for one environment, turning it off everywhere else.
    ///
    /// Only one at a time: the service identifies a viewer, not an environment, so two environments
    /// syncing would interleave their histories into the same remote account.
    public mutating func setSyncsExternally(_ syncs: Bool, for id: UUID) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        if syncs { clearExternalSync(except: id) }
        all[index].syncsExternally = syncs
    }

    private mutating func clearExternalSync(except id: UUID) {
        for index in all.indices where all[index].id != id {
            all[index].syncsExternally = false
        }
    }

    /// The environment that owns external sync, if any.
    public var syncingEnvironment: Environment? {
        all.first { $0.syncsExternally }
    }
}
