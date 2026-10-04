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
