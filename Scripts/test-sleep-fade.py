#!/usr/bin/env python3
"""Focused sleep fade state tests; no application build or simulator."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='sleep-fade-') as temp:
    folder = Path(temp)
    helper = root / 'App/PlaybackSleepFade.swift'
    if not helper.exists():
        # Exercise the original production loop through the same volume/identity test boundary.
        source = (root / 'App/SleepTimer.swift').read_text()
        start = source.index('    static func fadeOut(')
        end = source.index('\n}\n', start)
        method = source[start:end]
        method = method.replace('static func fadeOut(_ player: AVPlayer, pause:', 'func fadeOut(_ player: PlayerAdapter, pause:')
        method = method.replace('let start = player.volume, steps = 30', 'let start = player.volume, steps = steps')
        method = method.replace('fadeLength /', 'duration /')
        helper = folder / 'PlaybackSleepFade.swift'
        helper.write_text('''import Foundation
@MainActor final class PlayerAdapter {
 let read: () -> Float; let write: (Float) -> Void; let active: () -> Bool
 init(_ read: @escaping () -> Float, _ write: @escaping (Float) -> Void, _ active: @escaping () -> Bool) { self.read=read; self.write=write; self.active=active }
 var volume: Float { get { read() } set { write(newValue) } }
 var rate: Float { active() ? 1 : 0 }
}
@MainActor final class PlaybackSleepFade {
 let duration: Double; let steps: Int
 init(duration: Double, steps: Int) { self.duration=duration; self.steps=steps }
 func cancel() {}
 func start(volume: @escaping () -> Float, isCurrent: @escaping () -> Bool, shouldContinue: @escaping () -> Bool, setVolume: @escaping (Float) -> Void, pause: @escaping @MainActor () -> Void) { fadeOut(PlayerAdapter(volume, setVolume, shouldContinue), pause: pause) }
''' + method + '\n}\n')
    schedule = (root / 'App/SleepTimer.swift').read_text().split('/// What "the end"')[0]
    schedule = schedule.replace('import SwiftUI', 'import Observation').replace('import TVCore', '')
    timer = folder / 'SleepTimer.swift'
    timer.write_text(schedule)
    binary = folder / 'check'
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', str(helper), str(root / 'Tests/Standalone/SleepFade/Main.swift'), str(root / 'Tests/Standalone/SleepFade/TimerSupport.swift'), str(timer), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
