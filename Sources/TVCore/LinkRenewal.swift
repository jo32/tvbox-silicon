import Foundation

/// A fresh link to the file an episode plays, for a stream whose link expired while it played (a drive's signed
/// address refused with HTTP 403 after a while, a plugin's proxy answering the link it kept). The episode is resolved
/// again from its source (`resolve`: the play request a viewer makes by choosing it) and followed to the file the way
/// the player first did: a plugin's proxy that reveals its drive link, a CatPawOpen bundle's proxy, or the address
/// itself. Only a link to a file of the same length counts. At most once a minute and five times an episode, so a
/// source that keeps answering dead links isn't asked over and over.
public actor LinkRenewal {
    public typealias Resolve = @Sendable () async -> (url: URL, headers: [String: String])?
    private let resolve: Resolve
    private var last: Date?
    private var count = 0
    private var running: Task<CloudStreams.Source?, Never>?
    static let spacing: TimeInterval = 60
    static let most = 5

    public init(resolve: @escaping Resolve) { self.resolve = resolve }

    /// A closure for `CloudStreams.register` and `Remux.httpSource`: a fresh link to a file of `length` bytes (the
    /// reader checks the length itself when it isn't known yet).
    public nonisolated func renewal(length: Int?, name: String) -> @Sendable () async -> CloudStreams.Source? {
        { [self] in await self.source(length: length, name: name) }
    }

    public func source(length: Int?, name: String) async -> CloudStreams.Source? {
        if let running { return await running.value }
        if let last, Date().timeIntervalSince(last) < Self.spacing { return nil }
        guard count < Self.most else { return nil }
        last = Date(); count += 1
        let resolve = resolve
        let task = Task { await Self.follow(resolve, length: length, name: name) }
        running = task
        let source = await task.value
        running = nil
        return source
    }

    private static func follow(_ resolve: Resolve, length: Int?, name: String) async -> CloudStreams.Source? {
        guard let (resolved, headers) = await resolve() else {
            Diagnostics.shared.record(.warning, "player", "link renewal: the source gave no address")
            return nil
        }
        var address = resolved
        if let recovered = try? await EmbeddedJarHost.shared.recoverProxy(address) { address = recovered }
        let source: CloudStreams.Source?
        if let media = await EmbeddedJarHost.shared.directMedia(address) { source = media }
        else if let media = await CatPawOpen.proxiedMedia(address, headers: headers) {
            source = await CatPawOpen.directMedia(media) ?? media
        } else if ["http", "https"].contains(address.scheme?.lowercased() ?? "") {
            source = await probe(address, headers: headers, name: name)
        } else { source = nil }
        guard let source, length.map({ source.length == $0 }) ?? true else {
            Diagnostics.shared.record(.warning, "player", "link renewal: no file of the same length host=\(address.host() ?? "-") length=\(source?.length ?? -1)")
            return nil
        }
        Diagnostics.shared.record(.info, "player", "link renewed host=\(source.url.host() ?? "-")")
        return source
    }

    /// The file behind a plain link, from its answer to a two-byte range.
    private static func probe(_ url: URL, headers: [String: String], name: String) async -> CloudStreams.Source? {
        guard let connection = try? await RangeConnection.open(url, headers: headers, from: 0, through: 1,
                                                               configuration: RangeConnection.configuration, counter: CloudCounter()) else { return nil }
        connection.close()
        guard connection.length > 0 else { return nil }
        return CloudStreams.Source(url: url, headers: headers, length: Int(connection.length), name: name)
    }
}
