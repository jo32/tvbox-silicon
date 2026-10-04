// Run via Scripts/test-player.sh. Uses a generated local clip; no subscription or network required.
import AppKit
import AVKit
import TVCore

@main struct PlayerSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let controller = PlayerWindowController()
            let channel = Channel(name: "Player verification", url: URL(fileURLWithPath: CommandLine.arguments[1]))
            var closed = false
            controller.present(channel) { closed = true }
            guard let window = app.windows.compactMap({ $0 as? PlaybackWindow }).first,
                  let session = window.session else { fatalError("Player window was not created") }
            assert(window.styleMask.contains(.resizable))
            assert(window.styleMask.contains(.fullSizeContentView))
            assert(window.titlebarAppearsTransparent && window.titleVisibility == .hidden)
            assert(window.sheetParent == nil)
            window.setContentSize(NSSize(width: 640, height: 400))
            assert(abs(window.contentView!.bounds.width - 640) < 2)
            window.setContentSize(NSSize(width: 1100, height: 700))
            assert(abs(window.contentView!.bounds.width - 1100) < 2)
            for _ in 0..<100 {
                if !session.loading { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            assert(session.error == nil && !session.loading, "Local clip failed to load")
            window.contentView?.layoutSubtreeIfNeeded()
            @MainActor func findPlayer(in view: NSView) -> AVPlayerView? {
                if let player = view as? AVPlayerView { return player }
                return view.subviews.lazy.compactMap { findPlayer(in: $0) }.first
            }
            let content = window.contentView!
            guard let playerView = findPlayer(in: content) else { fatalError("Missing native player") }
            assert(playerView.controlsStyle == .floating)
            let playerFrame = playerView.convert(playerView.bounds, to: content)
            assert(abs(playerFrame.height - content.bounds.height) < 2, "Player must fill the window without toolbar bands")
            assert(abs(playerFrame.width - content.bounds.width) < 2)
            assert(abs(content.bounds.height - window.frame.height) < 2, "Title bar must not reserve space above video")
            if let capturePath = ProcessInfo.processInfo.environment["PLAYER_SCREENSHOT"] {
                window.setContentSize(NSSize(width: 960, height: 540))
                try? await Task.sleep(for: .seconds(5))
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), capturePath]
                try? capture.run()
                capture.waitUntilExit()
            }
            session.player.pause()
            @MainActor func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: code)!
                assert(window.performKeyEquivalent(with: event))
            }
            window.makeFirstResponder(nil)
            key(49, " ")
            assert(session.player.rate > 0)
            key(49, " ")
            assert(session.player.rate == 0)
            key(46, "m")
            assert(session.player.isMuted)
            key(46, "m")
            assert(!session.player.isMuted)
            session.setSpeed(1.5)
            assert(session.player.defaultRate == 1.5 && session.player.rate == 0)
            session.player.volume = 0.5
            key(126, "")
            assert(abs(session.player.volume - 0.55) < 0.01)
            key(124, "")
            try? await Task.sleep(for: .milliseconds(500))
            assert(session.player.currentTime().seconds >= 9, "Seek shortcut did not advance")
            session.looping = true
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: session.player.currentItem)
            try? await Task.sleep(for: .milliseconds(500))
            assert(session.player.currentTime().seconds < 3 && session.player.rate > 0, "Loop did not restart")
            controller.present(Channel(name: "Replacement", url: channel.url)) { closed = true }
            assert(app.windows.compactMap({ $0 as? PlaybackWindow }).count == 1)
            assert(window.title == "Replacement")
            controller.close()
            assert(closed && session.player.currentItem == nil)
            controller.present(channel) { closed = true }
            controller.close()
            print("PASS: edge-to-edge video, transparent title bar, floating controls, independent window, resize, play/pause, seek, mute, volume, speed, loop, replacement, close cleanup, reopen")
            app.terminate(nil)
        }
        app.run()
    }
}
