import Foundation
import TVCore

@main struct Probe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("Usage: TVBoxProbe <jar path> [class descriptor] [static int method]")
            print("       TVBoxProbe --subscription-check <URL> [...]")
            return
        }
        if args[1] == "--subscription-check" {
            struct Result: Encodable, Sendable {
                let address: String
                var origin: String? = nil
                var sites: Int? = nil
                var lives: Int? = nil
                var error: String? = nil
            }
            var results: [Result] = []
            let addresses = Array(args.dropFirst(2))
            for start in stride(from: 0, to: addresses.count, by: 6) {
                await withTaskGroup(of: Result.self) { group in
                    for address in addresses[start..<min(start + 6, addresses.count)] {
                        group.addTask {
                            do {
                                let config = try await HTTPClient().subscription(WebAddress.resolve(address))
                                return Result(address: address, origin: config.origin.absoluteString, sites: config.sites.count, lives: config.lives.count)
                            } catch { return Result(address: address, error: error.localizedDescription) }
                        }
                    }
                    for await result in group { results.append(result) }
                }
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(results.sorted { $0.address < $1.address }), as: UTF8.self))
            return
        }
        if args[1] == "--catalog-check", args.count >= 3 {
            // Browses sources the way the app does (CatalogClient, so lite ports with their JAR
            // fallback): home, a category when home has no videos, detail, then playback.
            let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) } }
            var passed = 0
            for site in sites {
                let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL)
                var stage = "home"
                do {
                    let home = try await client.home()
                    var videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        stage = "category"
                        videos = try await client.list(category: category.id, query: "", page: 1).videos
                    }
                    guard let first = videos.first else { throw TVError.unsupported("no videos") }
                    stage = "detail"
                    let video = try await client.detail(first.id)
                    guard let episode = video.episodes.first else { throw TVError.unsupported("no episodes") }
                    stage = "play"
                    let plan = try await client.preparePlayback(episode)
                    passed += 1
                    print("OK   \(site.name)  [\(site.compatibility)]  \(home.categories.count) categories, play \(plan.choices[0].address.prefix(90))")
                } catch {
                    print("FAIL \(site.name)  [\(site.compatibility)]  [\(stage)] \(error.localizedDescription)")
                }
            }
            for entry in await Diagnostics.shared.snapshot().entries where entry.category == "lite.fallback" { print("     fallback: \(entry.message)") }
            print("\(passed)/\(sites.count) sources reached playback")
            return
        }
        if args[1] == "--script-check", args.count >= 3 {
            // Runs a subscription's JavaScript sources on the in-process QuickJS runtime (as iOS and
            // tvOS do): home, a category when home has no videos, detail, then playback.
            let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
            let filters = Array(args.dropFirst(3))
            let sites = config.sites.filter { site in site.preferredRuntime == .javascript && (filters.isEmpty || filters.contains { site.name.contains($0) || site.key.contains($0) }) }
            var passed = 0
            for site in sites {
                func call(_ params: [String: String]) async throws -> [String: JSONValue] {
                    // Lite ports run alone here, without the JAR fallback, so the check measures the ports.
                    try await ScriptRuntime.shared.request(site: site, scriptURL: site.liteScript ?? site.scriptURL(origin: config.origin), params: params, http: HTTPClient(), origin: config.origin)
                }
                var stage = "home"
                do {
                    let home = CatalogPage(json: try await call(site.type == 4 ? ["filter": "true"] : [:]), origin: config.origin)
                    var videos = home.videos
                    if videos.isEmpty, let category = home.categories.first {
                        stage = "category"
                        videos = CatalogPage(json: try await call(["pg": "1", "ac": "detail", "t": category.id]), origin: config.origin).videos
                    }
                    guard let first = videos.first else { throw TVError.unsupported("no videos") }
                    stage = "detail"
                    let detail = CatalogPage(json: try await call(["ac": "detail", "ids": first.id]), origin: config.origin).videos.first
                    guard let episode = detail?.episodes.first else { throw TVError.unsupported("no episodes") }
                    stage = "play"
                    let play = try await call(["play": episode.address, "flag": episode.flag])
                    let address = play["url"]?.string ?? play["url"]?.array.map { "\($0.count / 2) choices" } ?? "none"
                    passed += 1
                    print("OK   \(site.name.prefix(24))  \(home.categories.count) categories, \(videos.count) videos, play \(address.prefix(80))")
                } catch {
                    print("FAIL \(site.name.prefix(24))  [\(stage)] \(error.localizedDescription.prefix(160))")
                }
            }
            print("\(passed)/\(sites.count) JavaScript sources reached playback on QuickJS")
            return
        }
        if args[1] == "--subscription-export", args.count == 3 {
            do {
                let config = try await HTTPClient().subscription(WebAddress.resolve(args[2]))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(config), as: UTF8.self))
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                exit(1)
            }
            return
        }
        if args[1] == "--live-check" {
            let origin = URL(string: "https://raw.githubusercontent.com/qist/tvbox/master/fty.json")!
            let config = try await HTTPClient().subscription(origin)
            print("Subscription: \(config.sites.count) sites, \(config.lives.count) live lists")
            await withTaskGroup(of: String.self) { group in
                for source in config.lives {
                    group.addTask {
                        do {
                            let channels = try await HTTPClient().channels(source)
                            return "\(source.name): \(channels.count) parsed channels (playback not verified)"
                        } catch { return "\(source.name): \(error.localizedDescription)" }
                    }
                }
                for await result in group { print(result) }
            }
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let runtime = JarRuntime()
        let report: JarReport
        if args.count >= 4 { report = await runtime.runStaticInt(data, className: args[2], method: args[3]) }
        else { report = await runtime.inspect(data) }
        let values: [String: Any] = ["status": report.status, "dexFiles": report.dexFiles, "classes": report.classes,
                                    "nativeLibraries": report.nativeLibraries, "instructions": report.instructions,
                                    "value": report.value, "message": report.message]
        let json = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        if report.status != 0 { exit(1) }
    }
}
