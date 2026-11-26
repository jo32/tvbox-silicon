#!/usr/bin/env python3
"""Exercise the production loopback proxy, or typecheck its iOS playback callers."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "Sources/TVCore"


def block(source, marker):
    start = source.index(marker)
    indent = marker[:len(marker) - len(marker.lstrip())]
    end = re.search(r"^" + indent + r"}$", source[start:], re.MULTILINE)
    if not end:
        raise ValueError(f"Unclosed Swift declaration: {marker}")
    return source[start:start + end.end()]


def signature(source, marker):
    return source[source.index(marker):].split(" {", 1)[0]


def playback_fixture():
    source = (ROOT / "App/PlaybackView.swift").read_text()
    fields = ("player", "liveMaintenance", "liveResolution", "generation", "liveRoom", "proxy",
              "isLive", "liveRetrying", "paused", "loading", "error", "quality", "qualities", "playing",
              "automatic", "liveReadyAt", "liveReopen", "observation", "sampler", "endObserver", "failureObserver")
    members = [re.search(rf"^    (?:private(?:\(set\))? )?(?:var|let) {name}\b.*$", source, re.MULTILINE)[0]
               for name in fields]
    members.append("    init() { player = AVQueuePlayer() }")
    for marker in ("    fileprivate func prepare(", "    private func configure(", "    private func note(_ step: String)"):
        members.append(signature(source, marker) + ' { fatalError("typecheck only") }')
    for marker in ("    fileprivate struct Prepared ", "    func choose(quality:", "    private func retryLive(",
                   "    private func detachItem(", "    private func maintainLivePlaylist(", "    private func useAdapter(",
                   "    fileprivate static func stopAdapter("):
        members.append(block(source, marker))
    return ("import AVFoundation\nimport TVCore\n@MainActor final class PlaybackSession {\n"
            + "\n".join(members) + "\n}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-typecheck", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="live-hls-renewal-") as directory:
        stage = Path(directory)
        models = (CORE / "Models.swift").read_text()
        deps = ["import Foundation", "extension Bundle { static var module: Bundle { .main } }",
                "struct ErrorReports { static let shared = ErrorReports(); func collect(_ entries: [LogEntry]) {} }",
                block(models, "public enum TVError:")]
        core = [CORE / (name + ".swift") for name in
                ("LiveHLSRenewal", "LiveRepair", "AdSkip", "MediaPayload", "Diagnostics", "Localization")]
        flags = ["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path",
                 os.environ.get("CLANG_MODULE_CACHE_PATH", str(stage / "modules"))]
        app = ROOT / "App/HLSProxy.swift"
        if args.ios_typecheck:
            sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True, timeout=15).strip()
            flags.extend(["-target", "arm64-apple-ios17.0", "-sdk", sdk])
            resolver = (CORE / "LiveCatalog.swift").read_text()
            deps.extend([block(models, "public struct ChannelLine:"), block(models, "public struct Channel:"),
                         block((CORE / "DashStreams.swift").read_text(), "public struct StreamQuality:"),
                         "public struct PlaybackHistoryContext: Codable, Hashable, Sendable {}",
                         "public struct ExternalSubtitle: Hashable, Sendable {}",
                         "public struct PlaybackSkip: Hashable, Sendable {}",
                         "public enum BilibiliAPI { public struct Part: Hashable, Sendable {} }",
                         "public enum LiveCatalog {",
                         signature(resolver, "    public static func isRoom(") + " { fatalError() }",
                         signature(resolver, "    public static func resolve(") + " { fatalError() }", "}",
                         "public enum Remux {",
                         signature((CORE / "Remux.swift").read_text(), "    public static func stop(") + " {}\n}"])
            core.append(CORE / "LiveReopen.swift")
        dependencies = stage / "Dependencies.swift"
        dependencies.write_text("\n".join(deps))
        module = ["-emit-module", "-module-name", "TVCore", "-emit-module-path", stage / "TVCore.swiftmodule",
                  dependencies, *core]
        if args.ios_typecheck:
            subprocess.run(flags + module, check=True, timeout=90)
            playback = stage / "PlaybackRenewal.swift"
            playback.write_text(playback_fixture())
            subprocess.run(flags + ["-typecheck", "-I", stage, app, playback], check=True, timeout=90)
            print("PASS arm64 iOS 17: production proxy, Channel/quality types, resolver signature, "
                  "PlaybackSession renewal, quality, retry and adapter lifecycle methods")
        else:
            subprocess.run(flags + module + ["-emit-library", "-o", stage / "libTVCore.dylib"], check=True, timeout=90)
            executable = stage / "check"
            subprocess.run(flags + ["-I", stage, "-L", stage, "-lTVCore", "-Xlinker", "-rpath", "-Xlinker", stage,
                                    app, ROOT / "Scripts/Fixtures/LiveHLSRenewalRegression.swift", "-o", executable],
                           check=True, timeout=90)
            subprocess.run([executable], check=True, timeout=40)


if __name__ == "__main__":
    main()
