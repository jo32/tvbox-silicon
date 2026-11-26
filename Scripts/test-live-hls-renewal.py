#!/usr/bin/env python3
"""Narrow Swift production-proxy regression; no application or simulator build."""
from pathlib import Path
import subprocess
import argparse
import tempfile
parser = argparse.ArgumentParser()
parser.add_argument('--ios-typecheck', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='live-hls-renewal-') as directory:
    stage = Path(directory)
    # Unrelated ad removal/diagnostics/payload conversion are outside this fixture.
    # The production proxy, renewal policy, HTTP stack and listener run unchanged.
    (stage/'Dependencies.swift').write_text('''import Foundation
public enum TVError: Error { case http(Int) }
public enum AdSkip {
 public static let enabled = false
 public struct Cleaned { public let runs: Int; public let seconds: Double; public let host: String; public let text: String }
 public static func clean(_ text: String, origin: URL) -> Cleaned? { nil }
}
public struct Diagnostics: Sendable {
 public static let shared = Diagnostics()
 public enum Level { case info, warning }
 public func record(_ level: Level, _ category: String, _ message: String) {}
}
public enum MediaPayload { public static func transportStream(_ data: Data) -> Data { data } }
''')
    core = [stage/'Dependencies.swift', root/'Sources/TVCore/LiveRepair.swift']
    policy = root/'Sources/TVCore/LiveHLSRenewal.swift'
    if policy.exists(): core.append(policy)
    if args.ios_typecheck:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
        flags = ['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-ios17.0', '-sdk', sdk]
        subprocess.run(flags + ['-emit-module', '-module-name', 'TVCore', *map(str, core), '-emit-module-path', str(stage/'TVCore.swiftmodule')], check=True)
        subprocess.run(flags + ['-typecheck', '-I', str(stage), str(root/'App/HLSProxy.swift')], check=True)
        playback = (root/'App/PlaybackView.swift').read_text()
        def method(marker):
            start = playback.index(marker); end = playback.index('\n    }', start) + len('\n    }')
            return playback[start:end]
        context = """import Foundation
import AVFoundation
import TVCore
struct Channel { let name: String; let group: String; let url: URL; let logo: URL?; var headers: [String: String] = [:] }
enum LiveCatalog { static func resolve(_ channel: Channel) async throws -> (channel: Channel, current: Int?) { (channel, nil) } }
@MainActor final class PlaybackSession {
 var liveMaintenance: Task<Void, Never>?
 var liveResolution = UUID()
 var generation = UUID()
 var liveRoom: Channel?
 var proxy: HLSProxy?
 var player = AVPlayer()
 var isLive = true
 var liveRetrying = false
 var paused = false
 var error: String?
 var quality: Int?
 var playing: Channel?
""" + method('    private func maintainLivePlaylist(') + '\n' + method('    private func useAdapter(') + '\n}\n'
        (stage/'PlaybackRenewal.swift').write_text(context)
        subprocess.run(flags + ['-typecheck', '-I', str(stage), str(root/'App/HLSProxy.swift'), str(stage/'PlaybackRenewal.swift')], check=True)
        print('PASS iOS17 arm64 typecheck: production renewal policy, LiveRepair, HLSProxy and playback maintenance methods')
    else:
        subprocess.run(['xcrun','swiftc','-swift-version','6','-emit-library','-emit-module','-module-name','TVCore',*map(str,core),'-o',str(stage/'libTVCore.dylib'),'-emit-module-path',str(stage/'TVCore.swiftmodule')], check=True)
        executable = stage/'check'
        subprocess.run(['xcrun','swiftc','-swift-version','6','-I',str(stage),'-L',str(stage),'-lTVCore','-Xlinker','-rpath','-Xlinker',str(stage),str(root/'App/HLSProxy.swift'),str(root/'Scripts/Fixtures/LiveHLSRenewalRegression.swift'),'-o',str(executable)],check=True)
        subprocess.run([str(executable)], check=True, timeout=40)
