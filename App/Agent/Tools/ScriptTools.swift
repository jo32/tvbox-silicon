import SwiftUI
import TVCore

/// The viewer's own Python and JavaScript spider scripts, the ones imported as files (`ImportedFiles`): listing,
/// reading, editing (with a backup and a diff) and trying one as a source.
@MainActor enum ScriptTools {
    static let extensions: Set<String> = ["py", "js"]
    static let maxBytes = 1_000_000

    static func make(_ context: AgentToolContext) -> [AppTool] {
        let store = context.store
        return [
            AppTool("scripts_list", .read, """
                The viewer's imported spider scripts (.py and .js files): name, size, line count, and the \
                subscription that uses each.
                """, Schema.object()) { _ in list(store) },

            AppTool("script_read", .read, """
                Reads lines of one of the viewer's scripts, numbered (`  12| code`). Long files come in parts: \
                when `truncated` is true, read on from `last_line + 1`.
                """, Schema.object([
                    "name": Schema.string("The script's file name from scripts_list."),
                    "start_line": Schema.integer("First line (default 1).", minimum: 1),
                    "end_line": Schema.integer("Last line (default: as many as fit, up to 200 lines).", minimum: 1),
                ], required: ["name"])) { args in try read(args) },

            AppTool("script_write", .destructive, """
                Changes one of the viewer's scripts: either replace text (find, copied exactly from script_read \
                without the line numbers, and replace; find must occur once unless occurrences says how many), or \
                write the whole new content. The old version is kept as `<name>.bak`, and the subscription that \
                uses the script reloads. Returns a unified diff. Test it with script_test afterwards.
                """, Schema.object([
                    "name": Schema.string("The script's file name from scripts_list."),
                    "find": Schema.string("The exact text to replace."),
                    "replace": Schema.string("What to put in its place (may be empty)."),
                    "occurrences": Schema.integer("How many times `find` occurs, when more than once; all are replaced.", minimum: 1),
                    "content": Schema.string("The whole new script, instead of find and replace."),
                ], required: ["name"]), summary: { args in writeSummary(args) }) { args in try await write(args, store) },

            AppTool("script_test", .read, """
                Loads one of the viewer's scripts as a source, runs its home page and a search through the app's \
                script hosts, and reports what came back (categories, videos, results) and any errors, with the \
                latest log lines. Each step gives up after `timeout_seconds`.
                """, Schema.object([
                    "name": Schema.string("The script's file name from scripts_list."),
                    "query": Schema.string("What to search for (default: the first title the home page lists)."),
                    "timeout_seconds": Schema.integer("Per step (default 30).", minimum: 5, maximum: 60),
                ], required: ["name"])) { args in try await test(args, store) },
        ]
    }

    // MARK: Files

    static func file(_ name: String) throws -> URL {
        guard extensions.contains((name as NSString).pathExtension.lowercased()), let url = ImportedFiles.file(named: name) else {
            throw AgentToolError("`\(name)` isn't one of the viewer's scripts. Call scripts_list for the names.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AgentToolError("No script is called `\(name)`. Call scripts_list.") }
        return url
    }

    static func text(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw AgentToolError("The script is larger than 1 MB.") }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentToolError("The script isn't UTF-8 text.") }
        return text
    }

    /// The subscriptions that load `name`: added as the file itself, or naming it as a source's script.
    static func users(_ name: String, _ store: Store) -> [SubscriptionEntry] {
        let address = ImportedFiles.address(named: name).absoluteString
        return store.subscriptions.filter { entry in
            entry.address == address || (store.documents[entry.address]?.sites.contains { $0.api == address || $0.api.hasSuffix("/" + name) } ?? false)
        }
    }

    private static func list(_ store: Store) -> JSONValue {
        let items: [JSONValue] = ImportedFiles.names().filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }.map { name in
            let url = ImportedFiles.file(named: name)
            let data = url.flatMap { try? Data(contentsOf: $0) }
            let lines = data.flatMap { String(data: $0, encoding: .utf8) }.map { AgentScriptText.lines($0).count }
            let users = users(name, store)
            return .obj([
                "name": .str(name), "bytes": data.map { .num($0.count) }, "lines": lines.map { .num($0) },
                "used_by": users.isEmpty ? nil : .list(users.map { .str(SubscriptionTools.title($0)) }),
                "backup": ImportedFiles.file(named: name + ".bak").map { FileManager.default.fileExists(atPath: $0.path) } == true ? .bool(true) : nil,
            ])
        }
        return .capped("scripts", items, limit: 30)
    }

    private static func read(_ args: AgentArguments) throws -> JSONValue {
        let name = try args.requiredString("name")
        let text = try text(try file(name))
        let excerpt = try AgentScriptText.excerpt(text, from: try args.int("start_line"), to: try args.int("end_line"))
        return .obj(["name": .str(name), "first_line": .num(excerpt.first), "last_line": .num(excerpt.last),
                     "total_lines": .num(excerpt.total), "truncated": .bool(excerpt.truncated), "text": .str(excerpt.text)])
    }

    // MARK: Write

    /// The new text a write would leave, from the arguments.
    private static func edited(_ args: AgentArguments, old: String) throws -> (text: String, replaced: Int?) {
        let content = try args.text("content")
        let find = try args.text("find")
        switch (content, find) {
        case (let content?, nil):
            guard content.utf8.count <= maxBytes else { throw AgentToolError("The new content is larger than 1 MB.") }
            return (content, nil)
        case (nil, let find?):
            let result = try AgentScriptText.replacing(find, with: try args.text("replace") ?? "", in: old, expected: try args.int("occurrences"))
            return (result.text, result.count)
        default:
            throw AgentToolError("Give either `content`, or `find` and `replace`.")
        }
    }

    private static func writeSummary(_ args: AgentArguments) -> (summary: String, detail: String?) {
        let name = ((try? args.string("name")) ?? nil) ?? "?"
        guard let url = try? file(name), let old = try? text(url), let new = try? edited(args, old: old) else {
            return (L10n.text("Change the script “%@”?", name), nil)
        }
        return (L10n.text("Change the script “%@”?", name), AgentScriptText.unifiedDiff(old: old, new: new.text, name: name, maxLines: 60))
    }

    private static func write(_ args: AgentArguments, _ store: Store) async throws -> JSONValue {
        let name = try args.requiredString("name")
        let url = try file(name)
        let old = try text(url)
        let new = try edited(args, old: old)
        let diff = AgentScriptText.unifiedDiff(old: old, new: new.text, name: name)
        guard !diff.isEmpty else { return .obj(["name": .str(name), "changed": .bool(false)]) }
        guard let backup = ImportedFiles.file(named: name + ".bak") else { throw AgentToolError("Can't keep a backup of `\(name)`.") }
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        try Data(new.text.utf8).write(to: url, options: .atomic)
        Diagnostics.shared.record(.info, "agent", "script_write \(name) bytes=\(new.text.utf8.count)")
        // The JavaScript host keeps a session per address; Python's and the JAR host's follow the content.
        await ScriptRuntime.shared.forget(scriptURL: ImportedFiles.address(named: name))
        var reloaded: [String] = []
        for entry in users(name, store) where entry.enabled {
            try? await waitIdle(store)
            await store.refreshSubscription(entry)
            reloaded.append(SubscriptionTools.title(entry))
        }
        return .obj(["name": .str(name), "changed": .bool(true), "backup": .str(name + ".bak"),
                     "replaced": new.replaced.map { .num($0) }, "reloaded": .list(reloaded.map { .str($0) }), "diff": .str(diff)])
    }

    private static func waitIdle(_ store: Store) async throws {
        for _ in 0..<120 where store.importing { try await Task.sleep(for: .milliseconds(250)) }
    }

    // MARK: Test

    private static func test(_ args: AgentArguments, _ store: Store) async throws -> JSONValue {
        let name = try args.requiredString("name")
        _ = try file(name)
        let timeout = Double(try args.int("timeout_seconds", in: 5...60, default: 30))
        let address = ImportedFiles.address(named: name)
        await ScriptRuntime.shared.forget(scriptURL: address)
        let started = Date()
        let http = HTTPClient()
        let imported = try await AgentToolKit.withTimeout(timeout, "Loading the script") { try await http.subscriptionImport(address, fresh: true) }
        guard case .subscription(let config) = imported, !config.sites.isEmpty else {
            throw AgentToolError("The file didn't load as a source.")
        }
        var results: [JSONValue] = []
        for site in config.sites.prefix(3) {
            let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
            var fields: [String: JSONValue?] = ["source": .str(site.name), "kind": .str(String(describing: site.runtime))]
            var firstTitle: String?
            let clock = ContinuousClock()
            do {
                let began = clock.now
                let home = try await AgentToolKit.withTimeout(timeout, "home") { try await client.home() }
                firstTitle = home.videos.first?.name
                fields["home"] = .obj(["ok": .bool(true), "categories": .num(home.categories.count), "videos": .num(home.videos.count),
                                       "sample": .list(home.videos.prefix(3).map { .str($0.name) }), "ms": .num(Self.ms(clock.now - began))])
                if home.videos.isEmpty, let category = home.categories.first {
                    let page = try await AgentToolKit.withTimeout(timeout, "category") { try await client.list(category: category.id, query: "", page: 1) }
                    firstTitle = page.videos.first?.name
                    fields["category"] = .obj(["name": .str(category.name), "videos": .num(page.videos.count)])
                }
            } catch {
                fields["home"] = .obj(["ok": .bool(false), "error": .str(AgentToolKit.clip(error.localizedDescription, 300))])
            }
            let query = try args.string("query") ?? firstTitle.map { String($0.prefix(8)) }
            if let query, site.searchable {
                do {
                    let began = clock.now
                    let page = try await AgentToolKit.withTimeout(timeout, "search") { try await client.list(category: nil, query: query, page: 1) }
                    fields["search"] = .obj(["ok": .bool(true), "query": .str(query), "results": .num(page.videos.count),
                                             "sample": .list(page.videos.prefix(3).map { .str($0.name) }), "ms": .num(Self.ms(clock.now - began))])
                    if let first = page.videos.first(where: { !$0.isFolder }) {
                        let video = try await AgentToolKit.withTimeout(timeout, "detail") { try await client.detail(first.id) }
                        fields["detail"] = .obj(["ok": .bool(true), "title": .str(video.name), "lines": .num(AgentLookup.lines(video).count),
                                                 "episodes": .num(video.episodes.count)])
                    }
                } catch {
                    fields["search"] = .obj(["ok": .bool(false), "query": .str(query), "error": .str(AgentToolKit.clip(error.localizedDescription, 300))])
                }
            }
            results.append(.obj(fields))
        }
        // What the hosts logged while it ran: a Python traceback, a JavaScript exception.
        let log = await Diagnostics.shared.snapshot().entries.filter { $0.date >= started && $0.level != .debug }
        return .obj(["name": .str(name), "sources": .list(results),
                     "log": .list(log.suffix(15).map { .str("\($0.level.rawValue) \($0.category): \(AgentToolKit.clip($0.message, 240))") })])
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
