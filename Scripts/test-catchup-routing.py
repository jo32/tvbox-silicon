#!/usr/bin/env python3
"""Execute production player/Store routing against finite replay and residual next-item contexts."""
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


store = (ROOT / 'App/Store.swift').read_text()
player = (ROOT / 'App/PlayerView.swift').read_text()
support = '''import Foundation
struct Replay: Sendable, Equatable { let channelID: String }
public struct Channel: Sendable, Equatable { let id: String; let name: String; var replay: Replay? = nil }
final class LiveGuide {}
struct PlayerStep { let name: String; let busy: Bool; var channel = false; let go: () -> Void }
final class PlaybackSession {
 var onPlaybackEnded: (() -> Void)?
 var playsOn: () -> Bool = { true }
 func playUpcoming() -> Bool { false }
}
final class Store {
 var liveLineup: LiveLineup?
 var liveGuide: LiveGuide?
 var playing: Channel?
 var resolvingEpisode: String?
 var autoPlayNext = true
 let next = Channel(id: "next", name: "Next episode")
 func previousEpisode(before: Channel) -> Channel? { next }
 func nextEpisode(after: Channel) -> Channel? { next }
 func previousFile(before: Channel) -> Channel? { next }
 func nextFile(after: Channel) -> Channel? { next }
 func selectEpisode(_ episode: Channel, from: Channel) { playing = episode }
'''
for marker in ['    func guide(for', '    func liveChannel(for', '    func lineup(for']:
    support += declaration(store, marker) + '\n'
support += declaration(player, '    func step(back:') + '\n}\n'
support += 'func install(_ session: PlaybackSession, channel: Channel, store: Store) {\n'
support += declaration(player, '    session.onPlaybackEnded =') + '\n'
support += declaration(player, '    session.playsOn =') + '\n}\n'
support += '''
@main struct Checks {
 static func main() {
  let live = Channel(id: "source|news|live", name: "News")
  let replay = Channel(id: "source|news|replay", name: "News replay", replay: Replay(channelID: live.id))
  let store = Store(), session = PlaybackSession()
  let guide = LiveGuide()
  store.liveLineup = LiveLineup(title: "Single channel", channels: [live]); store.liveGuide = guide
  precondition(store.guide(for: live) === guide, "single-channel playlist lost its guide entry")
  precondition(store.guide(for: replay) === guide && store.liveChannel(for: replay) == live,
               "replay lost its explicit return-to-live source or guide")
  precondition(store.lineup(for: replay) == nil, "finite replay became a channel-zapping lineup")
  precondition(store.step(back: false, from: replay, session: session) == nil
               && store.step(back: true, from: replay, session: session) == nil,
               "finite replay inherited residual catalog/file/channel navigation")
  store.playing = replay
  install(session, channel: replay, store: store)
  session.onPlaybackEnded?()
  precondition(store.playing == replay && !session.playsOn(), "replay end advanced into another item")
  store.playing = live
  install(session, channel: live, store: store)
  session.onPlaybackEnded?()
  precondition(store.playing == store.next && session.playsOn(), "ordinary auto-next was removed")
  print("PASS: production Store/player callbacks keep finite replay out of auto-next and channel stepping, with explicit live/guide recovery")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='tvbox-catchup-routing-') as directory:
    folder = Path(directory)
    fixture = folder / 'Check.swift'; fixture.write_text(support)
    executable = folder / 'check'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(fixture), str(ROOT / 'Sources/TVCore/LiveLineup.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
