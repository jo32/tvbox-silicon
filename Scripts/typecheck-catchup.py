#!/usr/bin/env python3
"""Typecheck replay UI and production player/guide entry points with SDK APIs, without building an app."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


core_support = '''import Foundation
public struct ExternalSubtitle: Hashable, Sendable {}
public struct PlaybackSkip: Hashable, Sendable {}
public enum BilibiliAPI { public struct Part: Hashable, Sendable {} }
public struct PlaybackHistoryContext: Codable, Hashable, Sendable {}
public enum L10n { public static func text(_ value: String, _ arguments: CVarArg...) -> String { value } }
enum LoadedLivePlugin { static func inflate(_ data: Data, format: String) -> Data? { nil } }
struct HTTPClient: Sendable {
 func get(_ url: URL, limit: Int = 20000000) async throws -> (Data, URL) {
  let (data, response) = try await URLSession.shared.data(from: url)
  return (data, response.url ?? url)
 }
}
public struct Diagnostics: Sendable {
 public static let shared = Self()
 public enum Level { case warning }
 public func record(_ level: Level, _ domain: String, _ message: String) {}
}
'''
models = (ROOT / 'Sources/TVCore/Models.swift').read_text()
for marker in ['public enum TVError:', 'public enum WebAddress', 'public struct LiveSource:', 'public struct ChannelLine:', 'public struct Channel:']:
    core_support += declaration(models, marker) + '\n'

app_support = '''import SwiftUI
import TVCore
@MainActor @Observable final class Store {
 var liveLineup: LiveLineup?
 var liveGuide: LiveGuide?
 var guideAddresses: [String: String] = [:]
 var playing: Channel?
'''
store = (ROOT / 'App/Store.swift').read_text()
for marker in ['    func guide(for', '    func liveChannel(for', '    func lineup(for']:
    app_support += declaration(store, marker) + '\n'
app_support += '''
}
@MainActor @Observable final class PlaybackSession {
 var lines: [Channel] = []
 var line = 0
 func choose(line index: Int) {}
}
struct ChannelLogo: View {
 let channel: Channel
 var size: CGFloat = 40
 var body: some View { Color.clear }
}
enum Brand { static let accent = Color.blue }
struct SourceStrip: View {
 struct Item { let id: String; let name: String }
 let items: [Item]; let selection: String; let select: (String) -> Void
 var body: some View { Color.clear }
}
private struct GlassKey: EnvironmentKey { static var defaultValue: Bool { false } }
extension EnvironmentValues {
 var glassControls: Bool { get { self[GlassKey.self] } set { self[GlassKey.self] = newValue } }
}
struct PlayerSheetPresentation<Sheet: View>: ViewModifier {
 @Binding var isPresented: Bool
 @ViewBuilder var sheet: () -> Sheet
 func body(content: Content) -> some View { content.sheet(isPresented: $isPresented, content: sheet) }
}
extension View { func playerSheet() -> some View { self } }
#if os(tvOS)
enum TestGlass { case regular }
extension View { func glassSurface<S: Shape>(_ glass: TestGlass, in shape: S) -> some View { self } }
struct TVEpisodePlateStyle: ButtonStyle {
 let selected: Bool; let capsule: Bool
 func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct ChannelChoices { let key: String; let panel: () -> AnyView }
'''
app_support += declaration((ROOT / 'App/TVPlayerEpisodes.swift').read_text(), 'struct TVPlayerChannelsPanel:') + '\n'
app_support += 'struct PlayerEntryCheck: View { let channel: Channel; let store = Store(); var body: some View { Color.clear }\n'
app_support += declaration((ROOT / 'App/PlayerView.swift').read_text(), '    private var channelChoices:') + '\n}\n#endif\n'

with tempfile.TemporaryDirectory(prefix='tvbox-catchup-ui-') as directory:
    folder = Path(directory)
    core = folder / 'CoreSupport.swift'; core.write_text(core_support)
    app = folder / 'AppSupport.swift'; app.write_text(app_support)
    core_files = [str(core)] + [str(ROOT / 'Sources/TVCore' / name) for name in ['Playlist.swift', 'ProgramGuide.swift', 'LiveLineup.swift', 'ProgramCatchup.swift']]
    for sdk_name, target in [('iphoneos', 'arm64-apple-ios17.0'), ('appletvos', 'arm64-apple-tvos17.0')]:
        sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()
        output = folder / sdk_name; output.mkdir()
        common = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-sdk', sdk, '-target', target]
        subprocess.run(common + ['-emit-module', '-module-name', 'TVCore', '-emit-module-path', str(output / 'TVCore.swiftmodule')] + core_files, check=True)
        subprocess.run(common + ['-typecheck', '-I', str(output), str(ROOT / 'App/LiveGuide.swift'), str(ROOT / 'App/ProgrammeCatchupView.swift'), str(ROOT / 'App/PlayerChannels.swift'), str(app)], check=True)
        print('PASS: actual replay sheet, LiveGuide, Store routing and player channel entry points: ' + target)
