import Foundation
#if canImport(MetricKit) && !os(tvOS)
import MetricKit
#endif

/// Crashes and hangs on iPhone, iPad and Mac, from MetricKit, which hands them over on a later launch.
/// (tvOS has no MetricKit; ErrorReports notices an exit while on screen there instead.) Each becomes one
/// error for ErrorReports: what happened, then the crashed thread's frames as binary+offset, which
/// `atos` turns into code lines with that release's dSYM (build/release-*/<version>/dSYMs).
/// An uncaught Objective-C exception reaches MetricKit only as the run loop rethrowing it, with no reason,
/// so on every platform its name, reason and the frames that threw it are also kept for the next launch.
public final class CrashReports: NSObject, @unchecked Sendable {
    public static let shared = CrashReports()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        if let message = try? String(contentsOf: Self.exceptionFile, encoding: .utf8) {
            try? FileManager.default.removeItem(at: Self.exceptionFile)
            Diagnostics.shared.record(.error, "crash", message)
        }
        Self.exceptionPath = Self.exceptionFile.path
        Self.previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            CrashReports.keep(exception)
            CrashReports.previousHandler?(exception)
        }
        #if canImport(MetricKit) && !os(tvOS)
        MXMetricManager.shared.add(self)
        #endif
    }

    private static var exceptionFile: URL { Diagnostics.shared.directory.appendingPathComponent("uncaught-exception.txt") }
    // Set once in start(), before the handler that reads them.
    nonisolated(unsafe) private static var exceptionPath: String?
    nonisolated(unsafe) private static var previousHandler: (@convention(c) (NSException) -> Void)?

    /// Runs just before the app aborts, so it only writes a file; the next launch reports it.
    private static func keep(_ exception: NSException) {
        guard let exceptionPath else { return }
        let message = uncaught(name: exception.name.rawValue, reason: exception.reason,
                               frames: frames(exception.callStackReturnAddresses.map(\.uintValue)),
                               executable: Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "",
                               origin: "app=\(ErrorReports.bundleValue("CFBundleShortVersionString")) (\(ErrorReports.bundleValue("CFBundleVersion")))")
        let file = URL(fileURLWithPath: exceptionPath)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(message.utf8).write(to: file, options: .atomic)
    }

    /// An uncaught exception, in the shape of a MetricKit crash: named by where the app's code threw it.
    static func uncaught(name: String, reason: String?, frames: [String], executable: String, origin: String) -> String {
        var lines = ["crash uncaught \(name) in \(place(frames, executable: executable))"]
        if let reason { lines.append("reason: " + reason) }
        lines.append(origin)
        lines.append(contentsOf: frames.prefix(16))
        return lines.joined(separator: "\n")
    }

    /// Return addresses as "binary+0xoffset" from the binary's load address, like MetricKit's frames.
    static func frames(_ addresses: [UInt]) -> [String] {
        addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase, let path = info.dli_fname else {
                return "?+0x\(String(address, radix: 16))"
            }
            return "\(URL(fileURLWithPath: String(cString: path)).lastPathComponent)+0x\(String(address - UInt(bitPattern: base), radix: 16))"
        }
    }

    /// One (category, message) per crash or hang in a MetricKit diagnostic payload's JSON.
    static func summaries(_ json: Data, executable: String = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "") -> [(category: String, message: String)] {
        guard let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        var found: [(String, String)] = []
        for crash in payload["crashDiagnostics"] as? [[String: Any]] ?? [] {
            let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
            let frames = Self.frames(crash["callStackTree"])
            let reason = meta["exceptionReason"] as? [String: Any]
            let kind = (reason?["exceptionName"] as? String) ?? Self.exception((meta["exceptionType"] as? NSNumber)?.intValue)
            var lines = ["crash \(kind) \(Self.signal((meta["signal"] as? NSNumber)?.intValue)) in \(Self.place(frames, executable: executable))"]
            if let message = reason?["composedMessage"] as? String { lines.append("reason: " + message) }
            if let termination = meta["terminationReason"] as? String { lines.append("termination: " + termination) }
            lines.append(Self.origin(meta))
            lines.append(contentsOf: frames.prefix(16))
            found.append(("crash", lines.joined(separator: "\n")))
        }
        for hang in payload["hangDiagnostics"] as? [[String: Any]] ?? [] {
            let meta = hang["diagnosticMetaData"] as? [String: Any] ?? [:]
            let frames = Self.frames(hang["callStackTree"])
            var lines = ["hang in \(Self.place(frames, executable: executable))"]
            lines.append("duration \(meta["hangDuration"] as? String ?? "-") " + Self.origin(meta))
            lines.append(contentsOf: frames.prefix(16))
            found.append(("hang", lines.joined(separator: "\n")))
        }
        return found
    }

    /// How iOS ended the app while it was on screen over a day (MetricKit's foreground exits), one message for
    /// each way other than a normal exit. A kill for memory and an `exit()` leave no crash diagnostic, so these
    /// counts are what tell them apart behind "Quit unexpectedly while on screen" (issue #159).
    static func exits(_ counts: [(kind: String, count: Int)], origin: String) -> [String] {
        counts.filter { $0.count > 0 }.map { "Ended on screen: \($0.kind) (MetricKit)\ncount=\($0.count) \(origin)" }
    }

    /// The version that crashed: payloads arrive on a later launch, maybe after an update.
    private static func origin(_ meta: [String: Any]) -> String {
        "app=\(meta["appVersion"] as? String ?? "-") (\(meta["appBuildVersion"] as? String ?? "-")) \(meta["platformArchitecture"] as? String ?? "")"
    }

    /// The first frame in the app's own binary: where a crash is usually fixed. It names the group.
    private static func place(_ frames: [String], executable: String) -> String {
        frames.first { !executable.isEmpty && $0.hasPrefix(executable + "+") } ?? frames.first ?? "-"
    }

    /// The attributed thread's frames, innermost first, as "binary+0xoffset".
    private static func frames(_ tree: Any?) -> [String] {
        let stacks = (tree as? [String: Any])?["callStacks"] as? [[String: Any]] ?? []
        let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        var result: [String] = []
        while let current = frame, result.count < 64 {
            let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
            result.append("\(current["binaryName"] as? String ?? "?")+0x\(String(offset, radix: 16))")
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return result
    }

    private static func exception(_ type: Int?) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        case let type?: "exception \(type)"
        case nil: "exception"
        }
    }

    private static func signal(_ number: Int?) -> String {
        switch number {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case let number?: "signal \(number)"
        case nil: ""
        }
    }
}

#if canImport(MetricKit) && !os(tvOS)
extension CrashReports: MXMetricManagerSubscriber {
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for summary in Self.summaries(payload.jsonRepresentation()) {
                Diagnostics.shared.record(.error, summary.category, summary.message)
            }
        }
    }

    #if os(iOS)
    public func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics?.foregroundExitData else { continue }
            let counts: [(kind: String, count: Int)] = [
                ("memory limit", exits.cumulativeMemoryResourceLimitExitCount), ("abnormal exit", exits.cumulativeAbnormalExitCount),
                ("watchdog", exits.cumulativeAppWatchdogExitCount), ("bad access", exits.cumulativeBadAccessExitCount),
                ("illegal instruction", exits.cumulativeIllegalInstructionExitCount)]
            let origin = "app=\(payload.latestApplicationVersion) (\(payload.metaData?.applicationBuildVersion ?? "-"))"
            for message in Self.exits(counts, origin: origin) {
                Diagnostics.shared.record(.error, "app", message)
            }
        }
    }
    #endif
}
#endif
