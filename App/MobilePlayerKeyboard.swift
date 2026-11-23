#if os(iOS)
import SwiftUI
import GameController
import TVCore

/// A player-scoped responder accepts hardware keys without requiring Full Keyboard Access or tabbing to a control.
struct MobilePlayerKeyboard: ViewModifier {
    var enabled: Bool
    var canPlay: Bool
    var canSeek: Bool
    var canBoost: Bool
    var item: ObjectIdentifier?
    var action: (PlaybackKeyboard.Action) -> Void

    func body(content: Content) -> some View {
        content.background {
            if UIDevice.current.userInterfaceIdiom == .pad {
                Receiver(configuration: self).frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
    }

    private struct Receiver: UIViewRepresentable {
        let configuration: MobilePlayerKeyboard
        func makeUIView(context: Context) -> KeyView { KeyView() }
        func updateUIView(_ view: KeyView, context: Context) { view.configure(configuration) }
        static func dismantleUIView(_ view: KeyView, coordinator: ()) { view.stop() }
    }

    private final class KeyView: UIView {
        private var configuration: MobilePlayerKeyboard?
        private var keyboard = PlaybackKeyboard()
        private var pressed: Set<PlaybackKeyboard.Key> = []
        private var holdTask: Task<Void, Never>?
        private var observers: [NSObjectProtocol] = []

        override var canBecomeFirstResponder: Bool { configuration?.enabled == true }

        func configure(_ next: MobilePlayerKeyboard) {
            let previous = configuration
            configuration = next
            let cancel = (previous?.enabled == true && !next.enabled) || previous?.item != next.item
                || (previous?.canPlay == true && !next.canPlay) || (previous?.canSeek == true && !next.canSeek)
                || (previous?.canBoost == true && !next.canBoost)
            let acquire = next.enabled && previous?.enabled != true
            guard cancel || acquire else { return }
            // SwiftUI is updating the view here. Responder changes can update playback state, so perform them afterward.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if cancel { self.cancelKeys() }
                if self.configuration?.enabled != true { self.resignFirstResponder() }
                else if acquire { self.acquireFocus() }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stop() }
            else {
                observeWindow()
                DispatchQueue.main.async { [weak self] in self?.acquireFocus() }
            }
        }

        private func observeWindow() {
            observers.forEach(NotificationCenter.default.removeObserver)
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.acquireFocus() }
                },
                center.addObserver(forName: UIWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelKeys() }
                },
                center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancelKeys() }
                },
            ]
        }

        private func acquireFocus() {
            guard configuration?.enabled == true, let window, window.isKeyWindow, !OpenMenu.showing else { return }
            // Sheets and text fields keep the responder they chose. Never dismiss a software keyboard to take keys.
            if let first = firstResponder(in: window), first !== self, first is any UITextInput || first is UIControl { return }
            guard isOnTop else { return }
            becomeFirstResponder()
        }

        private func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            return view.subviews.lazy.compactMap { self.firstResponder(in: $0) }.first
        }

        private var isOnTop: Bool {
            guard let window, window.isKeyWindow, window.windowScene?.activationState == .foregroundActive else { return false }
            var top = window.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top.map { isDescendant(of: $0.view) } ?? false
        }

        private var acceptsKeys: Bool { configuration?.enabled == true && isFirstResponder && isOnTop && !OpenMenu.showing }

        override func resignFirstResponder() -> Bool {
            cancelKeys()
            return super.resignFirstResponder()
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            cancelKeys(); resignFirstResponder()
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let unhandled = Set(presses.filter { !handle($0, released: false) })
            if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
        }

        override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let unhandled = Set(presses.filter { !handle($0, released: false) })
            if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let unhandled = Set(presses.filter { !handle($0, released: true) })
            if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            cancelKeys()
            super.pressesCancelled(presses, with: event)
        }

        private func handle(_ press: UIPress, released: Bool) -> Bool {
            guard let input = press.key else { return false }
            guard acceptsKeys, input.modifierFlags.intersection([.command, .control, .alternate]).isEmpty else {
                cancelKeys()
                return false
            }
            let key: PlaybackKeyboard.Key
            switch input.keyCode {
            case .keyboardSpacebar: key = .space
            case .keyboardLeftArrow: key = .left
            case .keyboardRightArrow: key = .right
            case .keyboardUpArrow: key = .up
            case .keyboardDownArrow: key = .down
            default:
                guard input.charactersIgnoringModifiers.lowercased() == "m" else { return false }
                key = .mute
            }
            guard configuration?.canPlay == true else { return false }
            guard (key != .left && key != .right) || configuration?.canSeek == true else { return false }
            let phase: PlaybackKeyboard.Phase
            if released {
                pressed.remove(key)
                if key == .right { holdTask?.cancel(); holdTask = nil }
                phase = .up
            } else {
                phase = pressed.insert(key).inserted ? .down : .repeated
            }
            run(keyboard.handle(key, phase: phase, shift: input.modifierFlags.contains(.shift)))
            return true
        }

        private func run(_ actions: [PlaybackKeyboard.Action]) {
            for command in actions {
                if command == .waitForHold {
                    holdTask?.cancel()
                    guard configuration?.canBoost == true else { continue }
                    holdTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(KeyHold.delay))
                        guard !Task.isCancelled, let self else { return }
                        guard self.acceptsKeys, self.configuration?.canBoost == true else { self.cancelKeys(); return }
                        self.run(self.keyboard.held())
                        // A native menu can take key-up without resigning our responder. Watch only during a hold.
                        while !Task.isCancelled, self.pressed.contains(.right) {
                            try? await Task.sleep(for: .milliseconds(100))
                            guard !Task.isCancelled else { return }
                            if !self.acceptsKeys { self.cancelKeys(); return }
                        }
                    }
                } else { configuration?.action(command) }
            }
        }

        private func cancelKeys() {
            holdTask?.cancel(); holdTask = nil
            pressed.removeAll()
            run(keyboard.cancel())
        }
    }
}
#endif
