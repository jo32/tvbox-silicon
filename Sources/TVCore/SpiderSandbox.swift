#if os(macOS)
import Foundation

/// Wraps a spider child process (Java / Node / Python) in a kernel Seatbelt sandbox via
/// `/usr/bin/sandbox-exec`, so that attacker-controlled subscription spider code cannot read
/// the contents of user files outside the app's caches, write anywhere else, or execute other
/// programs. Only the macOS child hosts need this: iOS and tvOS already confine the whole app
/// with the OS sandbox, and the in-process QuickJS lite ports are a capability sandbox.
///
/// The profile (`spider.sb`) is bundled next to each host's resources. Dynamic paths are passed
/// as `-D` parameters, which the profile references with `(param "NAME")`.
enum SpiderSandbox {
    /// Default on. Set `TVBOX_DISABLE_SANDBOX=1` in the environment to launch the interpreter
    /// directly, as an escape hatch if a profile problem ever blocks a working source.
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["TVBOX_DISABLE_SANDBOX"] != "1"

    private static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")

    /// Rewrites `(executable, arguments)` to run under the Seatbelt profile. `host` is the
    /// interpreter's resource directory (which also holds `spider.sb`); `cacheRoot` is the host's
    /// writable working root; `job` and `profile` are this request's session directory and the
    /// source's persistent profile directory (both under `cacheRoot` in practice).
    ///
    /// Returns the inputs unchanged — launching unsandboxed — when the sandbox is disabled or the
    /// profile / `sandbox-exec` is missing, so a packaging problem degrades gracefully instead of
    /// breaking playback. Callers log that fallback.
    static func wrap(executable: URL, arguments: [String], host: URL, cacheRoot: URL, job: URL, profile: URL) -> (executable: URL, arguments: [String]) {
        guard isEnabled else { return (executable, arguments) }
        let profileFile = host.appendingPathComponent("spider.sb")
        guard FileManager.default.fileExists(atPath: profileFile.path),
              FileManager.default.isExecutableFile(atPath: sandboxExec.path) else {
            Diagnostics.shared.record(.warning, "jar.sandbox", "spider.sb or sandbox-exec missing; launching unsandboxed host=\(host.lastPathComponent)")
            return (executable, arguments)
        }
        // Seatbelt matches canonical paths, so resolve symlinks (e.g. /var -> /private/var) before
        // injecting. The home directory is cut off wholesale by the profile; the app's own dirs,
        // which live under it, are reopened by the RESOURCES/CACHE_ROOT/JOB/PROFILE parameters.
        // Not `resolvingSymlinksInPath`: it strips a leading /private, so an app run from /private/tmp
        // or App Translocation (/private/var/folders/...) could not exec its own interpreter.
        func canonical(_ url: URL) -> String {
            if let resolved = realpath(url.path, nil) { defer { free(resolved) }; return String(cString: resolved) }
            // Not created yet (the accounts file before the first sign-in): resolve its folder.
            let parent = url.deletingLastPathComponent()
            return parent.path == url.path ? url.path : canonical(parent) + "/" + url.lastPathComponent
        }
        let home = canonical(FileManager.default.homeDirectoryForCurrentUser)
        // The JVM binds 127.0.0.1 through a dual-stack IPv6 socket (as ::ffff:127.0.0.1). macOS 15's
        // Seatbelt doesn't match that against the profile's `localhost` and fails the bind with EPERM,
        // so no JAR source could start its loopback bridge there. Plain IPv4 sockets, as the Python
        // host uses, match on every version.
        let interpreterOptions = executable.lastPathComponent == "java" ? ["-Djava.net.preferIPv4Stack=true"] : []
        var argv = ["-f", profileFile.path,
                    "-D", "RESOURCES=\(canonical(host))",
                    "-D", "CACHE_ROOT=\(canonical(cacheRoot))",
                    "-D", "JOB=\(canonical(job))",
                    "-D", "PROFILE=\(canonical(profile))",
                    "-D", "ACCOUNTS=\(canonical(CloudDriveAccounts.fileURL))",
                    "-D", "HOME=\(home)",
                    "--", executable.path] + interpreterOptions
        argv.append(contentsOf: arguments)
        return (sandboxExec, argv)
    }
}
#endif
