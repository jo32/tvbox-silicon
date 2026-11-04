import Foundation
import CryptoKit

/// Hides chosen subscriptions and sources behind a passcode, together with everything that could
/// reveal them.
///
/// The requirement is stricter than "hide a row in a list". A hidden source must also stop
/// appearing in playback history, in search results, in favourites, in the source picker, in
/// recommendations, and in any diagnostic dump — otherwise the list is a fig leaf. So this type is
/// built around one question, asked at every read site: *may this source be seen right now?*
///
/// Two states, and the difference matters:
///
/// * **Locked** — the default, and also the state after relaunch and after a timeout. Hidden items
///   are removed from every listing. A passcode is required to see them.
/// * **Unlocked** — a deliberate, temporary state. Everything behaves normally until the timeout
///   expires, the app goes to the background, or the user locks it again.
///
/// The passcode itself is never stored. What is stored is a PBKDF2-shaped digest with a random
/// salt, so a copied preferences file cannot be turned back into the passcode, and two installs
/// with the same passcode do not produce the same digest. `CryptoKit` is used rather than
/// CommonCrypto so this compiles on every Apple platform without a bridging header.
///
/// Framework-free: no UI, no storage, no networking. The caller decides where the blob lives and
/// when to lock.
public struct PrivacyVault: Codable, Equatable, Sendable {

    // MARK: 存储的字段

    /// Source identities the user hid, each written as `<subscription origin>|<source key>`.
    ///
    /// The bare key is not enough: unrelated subscriptions very often use the same key (`csp_AppYsV2`
    /// appears in dozens of public feeds), so a bare-key list flips every namesake at once — the
    /// "turning off A also turned off B" report. The origin makes the identity the same one the rest of
    /// the app uses (`EpisodeSkipSettings.scope`), so history, favourites and search agree with it.
    public private(set) var hiddenSources: Set<String>
    /// Keys saved by builds before identities carried an origin. They still hide, matching by key
    /// alone, so an existing vault does not quietly stop working after the update.
    public private(set) var legacyKeys: Set<String>
    /// Subscription origins (`Subscription.origin`) the user hid, so an empty-but-present
    /// subscription does not linger in the list.
    public private(set) var hiddenSubscriptions: Set<String>
    /// Salt for the passcode digest, base64. Regenerated when the passcode changes.
    private var salt: Data
    /// SHA-256 over salt + passcode, iterated. Not the passcode.
    private var digest: Data
    /// Iteration count, stored so a future change can migrate old digests.
    public private(set) var rounds: Int
    /// How long an unlock lasts before the vault locks itself again.
    public var unlockDuration: TimeInterval
    /// Whether a passcode has been set at all. With no passcode, hiding is refused rather than
    /// silently ineffective.
    public var hasPasscode: Bool { !digest.isEmpty }

    // MARK: 运行时状态（不持久化）

    /// When the current unlock began. Not encoded: a relaunch always starts locked.
    private var unlockedAt: Date?
    /// Failed attempts, to slow down guessing. Not encoded, so it resets on relaunch — the
    /// persisted digest is the real barrier.
    public private(set) var failedAttempts: Int = 0
    /// Bumps whenever what is visible changes — a hide, a show, a lock, an unlock. Cached source
    /// lists compare it, and a view that reads it redraws when the vault is opened or closed.
    public private(set) var revision = 0

    /// The iteration count for a new digest. 120 000 keeps a four-digit passcode's search space
    /// expensive without making unlock feel slow on an old phone.
    public static let defaultRounds = 120_000
    /// Attempts allowed before a cooldown.
    public static let attemptsBeforeCooldown = 5

    public init(rounds: Int = PrivacyVault.defaultRounds, unlockDuration: TimeInterval = 300) {
        self.hiddenSources = []
        self.legacyKeys = []
        self.hiddenSubscriptions = []
        self.salt = Data()
        self.digest = Data()
        self.rounds = rounds
        self.unlockDuration = unlockDuration
    }

    // MARK: 密码

    public enum PasscodeError: Error, Equatable, Sendable {
        /// No passcode set, so hiding cannot be protected.
        case noPasscode
        /// The passcode did not match.
        case wrongPasscode
        /// Too many failures in a row; wait before trying again.
        case coolingDown(seconds: TimeInterval)
        /// A new passcode was too short to be worth the digest.
        case tooShort
    }

    /// Shortest passcode accepted. Four digits is the familiar phone-lock length; six is better,
    /// but refusing four would push people to disable the feature.
    public static let minimumLength = 4

    /// Sets the first passcode, or replaces one after verifying `current`.
    public mutating func setPasscode(_ passcode: String, replacing current: String? = nil,
                                     now: Date = Date()) throws {
        if hasPasscode {
            guard let current, verify(current) else { throw PasscodeError.wrongPasscode }
        }
        guard passcode.count >= Self.minimumLength else { throw PasscodeError.tooShort }
        let newSalt = Self.randomSalt()
        salt = newSalt
        digest = Self.derive(passcode, salt: newSalt, rounds: rounds)
        // Setting a passcode leaves the owner unlocked: they just proved they are the owner.
        unlockedAt = now
        failedAttempts = 0
        cooldownEnds = nil
        revision += 1
    }

    /// Checks a passcode and, on success, unlocks. Returns whether it matched.
    @discardableResult
    public mutating func unlock(_ passcode: String, now: Date = Date()) -> Bool {
        guard hasPasscode else { return false }
        if let until = cooldownEnds, now < until { return false }
        if verify(passcode) {
            unlockedAt = now
            failedAttempts = 0
            revision += 1
            return true
        }
        failedAttempts += 1
        if failedAttempts >= Self.attemptsBeforeCooldown {
            // 8 s after the fifth failure, doubling each time, capped at five minutes. Two seconds
            // would be no obstacle at all to a script.
            let step = Double(failedAttempts - Self.attemptsBeforeCooldown)
            cooldownEnds = now.addingTimeInterval(min(300, 8 * pow(2, step)))
        }
        return false
    }

    /// When the cooldown ends, if one is running.
    public private(set) var cooldownEnds: Date?

    /// Relocks immediately. Called when the app goes to the background, or from a "lock now" row.
    public mutating func lock() {
        guard unlockedAt != nil else { return }
        unlockedAt = nil
        revision += 1
    }

    /// Whether hidden items may be shown right now. Also expires a stale unlock, so a caller does
    /// not have to run a timer to be safe — reading this is enough.
    public mutating func isUnlocked(now: Date = Date()) -> Bool {
        guard let started = unlockedAt else { return false }
        guard now.timeIntervalSince(started) < unlockDuration else {
            unlockedAt = nil
            revision += 1
            return false
        }
        return true
    }

    /// Same as `isUnlocked` without mutating, for use in a `View` body.
    public func unlocked(now: Date = Date()) -> Bool {
        guard let started = unlockedAt else { return false }
        return now.timeIntervalSince(started) < unlockDuration
    }

    // MARK: 隐藏与显示

    /// The stored identity of one source. Every hide and every read builds it the same way, so a
    /// source cannot be hidden under one name and looked for under another.
    public static func scope(origin: URL, sourceKey: String) -> String {
        origin.absoluteString + "|" + sourceKey
    }

    /// Hides sources, each identified by its subscription's origin. Requires an unlock, so a
    /// passer-by cannot hide things to confuse the owner.
    public mutating func hide(sourceKeys: some Sequence<String>, origin: URL, now: Date = Date()) throws {
        guard hasPasscode else { throw PasscodeError.noPasscode }
        guard isUnlocked(now: now) else { throw PasscodeError.wrongPasscode }
        let scopes = sourceKeys.map { Self.scope(origin: origin, sourceKey: $0) }
        guard scopes.contains(where: { !hiddenSources.contains($0) }) else { return }
        hiddenSources.formUnion(scopes)
        revision += 1
    }

    /// Unhides sources. Also requires an unlock.
    public mutating func show(sourceKeys: some Sequence<String>, origin: URL, now: Date = Date()) throws {
        guard hasPasscode else { throw PasscodeError.noPasscode }
        guard isUnlocked(now: now) else { throw PasscodeError.wrongPasscode }
        hiddenSources.subtract(sourceKeys.map { Self.scope(origin: origin, sourceKey: $0) })
        // A key saved by an older build is cleared by key, since it cannot be told apart by origin.
        legacyKeys.subtract(sourceKeys)
        revision += 1
    }

    /// Hides a whole subscription by origin, and every source it contributed.
    public mutating func hide(subscription origin: URL, sourceKeys: some Sequence<String>, now: Date = Date()) throws {
        guard hasPasscode else { throw PasscodeError.noPasscode }
        guard isUnlocked(now: now) else { throw PasscodeError.wrongPasscode }
        hiddenSources.formUnion(sourceKeys.map { Self.scope(origin: origin, sourceKey: $0) })
        if hiddenSubscriptions.insert(origin.absoluteString).inserted { revision += 1 }
    }

    /// Unhides a subscription and its sources.
    public mutating func show(subscription origin: URL, sourceKeys: some Sequence<String>, now: Date = Date()) throws {
        guard hasPasscode else { throw PasscodeError.noPasscode }
        guard isUnlocked(now: now) else { throw PasscodeError.wrongPasscode }
        let scopes = Set(sourceKeys.map { Self.scope(origin: origin, sourceKey: $0) })
        hiddenSources.subtract(scopes)
        legacyKeys.subtract(sourceKeys)
        hiddenSubscriptions.remove(origin.absoluteString)
        revision += 1
    }

    /// Removes the passcode and unhides everything. Called from a "turn off" row, which must have
    /// been unlocked first — otherwise the data would stay hidden with no way back.
    public mutating func removePasscode(now: Date = Date()) throws {
        guard isUnlocked(now: now) else { throw PasscodeError.wrongPasscode }
        hiddenSources.removeAll()
        legacyKeys.removeAll()
        hiddenSubscriptions.removeAll()
        digest = Data()
        salt = Data()
        unlockedAt = nil
        failedAttempts = 0
        cooldownEnds = nil
        revision += 1
    }

    // MARK: 过滤 —— 每个读取点都要问的问题

    /// Whether one source may be listed, searched, or resumed right now.
    ///
    /// Every read site calls this. It is deliberately cheap and non-mutating: a `View` body calls
    /// it once per row.
    public func permits(sourceKey: String, origin: URL, now: Date = Date()) -> Bool {
        // No passcode means nothing is hidden: a leftover list from a removed passcode must not
        // quietly keep content out of the app with no way to bring it back.
        guard hasPasscode else { return true }
        let scope = Self.scope(origin: origin, sourceKey: sourceKey)
        guard hiddenSources.contains(scope) || legacyKeys.contains(sourceKey) else { return true }
        return unlocked(now: now)
    }

    /// Whether a source counts as hidden at all, whatever the lock state. For a switch's position.
    public func isHidden(sourceKey: String, origin: URL) -> Bool {
        hiddenSources.contains(Self.scope(origin: origin, sourceKey: sourceKey)) || legacyKeys.contains(sourceKey)
    }

    /// Whether a subscription as a whole is hidden, whatever the lock state.
    public func isHidden(subscription origin: URL) -> Bool {
        hiddenSubscriptions.contains(origin.absoluteString)
    }

    /// Whether a whole subscription may be listed.
    public func permits(subscription origin: URL, now: Date = Date()) -> Bool {
        guard hasPasscode else { return true }
        guard hiddenSubscriptions.contains(origin.absoluteString) else { return true }
        return unlocked(now: now)
    }

    /// Whether one source of one subscription may be shown: neither it nor its whole subscription
    /// hidden, unless the vault is open.
    ///
    /// The subscription test uses the source's *own* origin, never the merged document's. That
    /// fallback belongs to the first subscription and the built-in sources carry no origin at all,
    /// so testing it would hide every built-in source the moment one subscription was hidden.
    public func permits(site: Site, fallback: URL, now: Date = Date()) -> Bool {
        let origin = site.origin(or: fallback)
        guard permits(sourceKey: site.sourceKey, origin: origin, now: now) else { return false }
        guard let own = site.provenance?.origin else { return true }
        return permits(subscription: own, now: now)
    }

    /// Filters sources whose owners are hidden. Use it in the source picker, the search fan-out,
    /// and the recommendation fan-out — anywhere a set of keys becomes a set of requests.
    public func visibleSources(_ keys: some Sequence<String>, origin: URL, now: Date = Date()) -> [String] {
        let open = unlocked(now: now)
        if open { return Array(keys) }
        return keys.filter { !isHidden(sourceKey: $0, origin: origin) }
    }

    /// Filters subscriptions for the subscription list.
    public func visibleSubscriptions(_ origins: some Sequence<URL>, now: Date = Date()) -> [URL] {
        let open = unlocked(now: now)
        if open { return Array(origins) }
        return origins.filter { !hiddenSubscriptions.contains($0.absoluteString) }
    }

    /// Whether anything is hidden at all, so a settings row can show a count instead of a switch.
    public var hasHiddenItems: Bool { !hiddenSources.isEmpty || !hiddenSubscriptions.isEmpty || !legacyKeys.isEmpty }
    public var hiddenCount: Int { hiddenSources.count + hiddenSubscriptions.count + legacyKeys.count }

    // MARK: 摘要

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        // SystemRandomNumberGenerator is the platform CSPRNG; no need for arc4random elsewhere.
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes)
    }

    /// Iterated SHA-256 over salt + passcode. Not PBKDF2 proper, but the same shape: a per-install
    /// salt and enough rounds that guessing is slow. Kept simple so it has no dependency beyond
    /// CryptoKit.
    static func derive(_ passcode: String, salt: Data, rounds: Int) -> Data {
        let secret = Data(passcode.utf8)
        var accumulator = salt + secret
        for _ in 0..<max(1, rounds) {
            accumulator = Data(SHA256.hash(data: accumulator))
        }
        return accumulator
    }

    /// Constant-time comparison, so a timing watcher cannot learn the digest byte by byte.
    private func verify(_ passcode: String) -> Bool {
        guard hasPasscode else { return false }
        let candidate = Self.derive(passcode, salt: salt, rounds: rounds)
        guard candidate.count == digest.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(candidate, digest) { difference |= left ^ right }
        return difference == 0
    }

    // MARK: 编解码 —— 只存能存的东西

    private enum CodingKeys: String, CodingKey {
        case hiddenSources, legacyKeys, hiddenSubscriptions, salt, digest, rounds, unlockDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let saved = Set(try container.decodeIfPresent([String].self, forKey: .hiddenSources) ?? [])
        // Builds before this one saved bare keys. Everything is read through one set, so split the
        // saved list by whether an identity carries its origin.
        hiddenSources = saved.filter { $0.contains("|") }
        legacyKeys = Set(try container.decodeIfPresent([String].self, forKey: .legacyKeys) ?? [])
            .union(saved.filter { !$0.contains("|") })
        hiddenSubscriptions = Set(try container.decodeIfPresent([String].self, forKey: .hiddenSubscriptions) ?? [])
        salt = try container.decodeIfPresent(Data.self, forKey: .salt) ?? Data()
        digest = try container.decodeIfPresent(Data.self, forKey: .digest) ?? Data()
        rounds = try container.decodeIfPresent(Int.self, forKey: .rounds) ?? Self.defaultRounds
        unlockDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .unlockDuration) ?? 300
        // unlockedAt and failedAttempts are deliberately not restored: a copied file, or a relaunch,
        // must never start in the unlocked state.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Array(hiddenSources).sorted(), forKey: .hiddenSources)
        try container.encode(Array(legacyKeys).sorted(), forKey: .legacyKeys)
        try container.encode(Array(hiddenSubscriptions).sorted(), forKey: .hiddenSubscriptions)
        try container.encode(salt, forKey: .salt)
        try container.encode(digest, forKey: .digest)
        try container.encode(rounds, forKey: .rounds)
        try container.encode(unlockDuration, forKey: .unlockDuration)
    }
}

// MARK: - 接入：把过滤套到已有的数据类型上

/// The read sites a hidden source has to disappear from, expressed as functions over the models
/// 映匣 already has. Kept beside `PrivacyVault` rather than inside each view so the rule lives in
/// one place: if a new listing is added, it calls one of these and inherits the behaviour.
///
/// Nothing here mutates storage. Hiding is a *view* of the data, so unhiding restores everything
/// exactly as it was — no history lost, no favourites re-added.
extension PrivacyVault {

    /// Playback history rows the user may see. A hidden source's episodes vanish from "continue
    /// watching" entirely, not greyed out.
    public func visibleHistory(_ entries: [PlaybackHistoryEntry], now: Date = Date()) -> [PlaybackHistoryEntry] {
        let open = unlocked(now: now)
        if open { return entries }
        return entries.filter { permits($0, now: now) }
    }

    /// Whether one history row may be shown. For a view that renders rows one at a time.
    public func permits(_ entry: PlaybackHistoryEntry, now: Date = Date()) -> Bool {
        let context = entry.context
        guard permits(sourceKey: context.sourceKey, origin: context.origin, now: now) else { return false }
        return permits(subscription: context.origin, now: now)
    }

    /// Whether a favourite may be shown. A favourite with no source key (a live room, a song) is
    /// always visible — it cannot belong to a hidden source.
    public func permits(_ item: FavoriteItem, now: Date = Date()) -> Bool {
        guard let (key, origin) = Self.sourceKey(of: item) else { return true }
        guard permits(sourceKey: key, origin: origin, now: now) else { return false }
        return permits(subscription: origin, now: now)
    }

    /// Favourites the user may see.
    public func visibleFavorites(_ items: [FavoriteItem], now: Date = Date()) -> [FavoriteItem] {
        let open = unlocked(now: now)
        if open { return items }
        return items.filter { permits($0, now: now) }
    }

    /// Source keys a search may fan out to.
    ///
    /// This is the one that matters most in practice: a search that queries every source would
    /// otherwise *return results from a hidden source*, which reveals both its existence and its
    /// content. Filtering at the fan-out point, not at the results, is what makes hiding real.
    public func searchableSources(_ keys: [String], origin: URL, now: Date = Date()) -> [String] {
        visibleSources(keys, origin: origin, now: now)
    }

    /// Whether a search result may be shown, for a result that names the source it came from.
    public func permits(searchResultFrom sourceKey: String, origin: URL, now: Date = Date()) -> Bool {
        permits(sourceKey: sourceKey, origin: origin, now: now)
    }

    /// Whether an episode may be opened at all. A deep link, a resumed session, or a recommendation
    /// must all pass through this — otherwise hiding the row achieves nothing.
    public func permitsPlayback(sourceKey: String, origin: URL, now: Date = Date()) -> Bool {
        permits(sourceKey: sourceKey, origin: origin, now: now) && permits(subscription: origin, now: now)
    }

    /// The subscription list, filtered.
    public func visibleSubscriptions(_ subscriptions: [Subscription], now: Date = Date()) -> [Subscription] {
        let open = unlocked(now: now)
        if open { return subscriptions }
        return subscriptions.filter { !hiddenSubscriptions.contains($0.origin.absoluteString) }
    }

    /// The source keys contributed by one subscription, for hiding a whole feed at once.
    public static func sourceKeys(of subscription: Subscription) -> Set<String> {
        Set(subscription.sites.map(\.sourceKey))
    }

    /// The source key behind a favourite, and the subscription it came from, when it has one.
    ///
    /// Returns nil for a live channel and for a music track: neither carries a source key, because
    /// neither comes from a subscription's sources — a live room is addressed by URL and a song by
    /// its platform track id. They are therefore never hidden by this vault, and a view should
    /// treat nil as "always visible" rather than as "unknown".
    static func sourceKey(of item: FavoriteItem) -> (key: String, origin: URL)? {
        switch item {
        case .video(let video): return (video.sourceKey, video.origin)
        case .episode(let episode): return (episode.video.sourceKey, episode.video.origin)
        case .cloud, .live, .music: return nil
        }
    }
}
