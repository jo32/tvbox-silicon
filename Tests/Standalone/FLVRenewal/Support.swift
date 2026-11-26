import Foundation
public enum TVError: Error { case unsupported(String), http(Int) }
enum L10n { static func text(_ value: String) -> String { value } }
enum Diagnostics { static let shared = Logger(); enum Level { case info, warning }; struct Logger: Sendable { func record(_ level: Level, _ category: String, _ text: String) {} }; static func describe(_ error: Error) -> String { String(describing: error) } }
struct RemuxPlan { struct Device: Sendable {} }
enum RemuxSession { static func device() -> RemuxPlan.Device { .init() } }
protocol SegmentedStream { var id: String { get }; func close() }
final class RemuxStore: @unchecked Sendable { static let shared = RemuxStore(); func add(_ session: any SegmentedStream) {}; func remove(_ id: String) -> (any SegmentedStream)? { nil } }
actor RemuxServer { static let shared = RemuxServer(); func base() throws -> URL { URL(string: "http://127.0.0.1:12345/")! } }
// Only the native FFmpeg conversion boundary is substituted; parser, segmenter, session,
// URLSession HTTP callbacks, retry ownership and HLS playlist/retention are production code.
enum HLSRemux {
    struct Output: Sendable { var video = "h264", audio: String? = "aac", width = 10, height = 10, transfer = 0; var initializations: [Int: Data]; var media: [Int: Data] }
    static func repackage(_ file: Data, device: RemuxPlan.Device) throws -> Output {
        var reader = FLVTagReader(); let tags = try reader.append(file)
        return Output(initializations: [0: tags.first!.body, 1: Data([1])], media: [0: file, 1: file])
    }
}
