import SwiftUI
import TVCore
#if os(iOS)
import UIKit
#endif

// Where the assistant opens (Docs/agent.md, "Entry points"). Nothing shows until it is turned on in Settings › Assistant.

extension View {
    /// The app's root: where the panel shows. iPhone: over everything, from the right edge. iPad: a trailing panel
    /// beside the page. Mac (on the detail column's stack): an inspector. Apple TV: a full-screen page.
    func assistantHost() -> some View { modifier(AssistantHost()) }
    /// Watch Now's and Discover's root pages: the button that opens the assistant, and on iPhone and iPad the edge swipe.
    func assistantEntry(_ section: AppSection) -> some View { modifier(AssistantEntry(section: section)) }
}

private struct AssistantEntry: ViewModifier {
    let section: AppSection
    @Environment(AssistantController.self) private var assistant
    @AppStorage(AgentSettings.enabledKey) private var enabled = false
    func body(content: Content) -> some View {
        content
            // A page pushed over it, another tab or a player hides it: the swipe is only taken while it shows.
            .onAppear { assistant.entryPages.insert(section) }
            .onDisappear { assistant.entryPages.remove(section) }
            #if os(tvOS)
            .overlay(alignment: .top) {
                // Discover draws its own, beside its search button.
                if enabled, section == .home {
                    VStack {
                        AssistantTVButton()
                            .padding(.trailing, 50)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .focusSection()
                            .padding(.top, 50)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea()
                }
            }
            #else
            .toolbar {
                if enabled {
                    ToolbarItem(placement: .primaryAction) { AssistantToolbarButton() }
                }
            }
            #endif
    }
}

#if !os(tvOS)
/// The toolbar's sparkles: opens and closes the panel. ⌘⇧A on the Mac.
struct AssistantToolbarButton: View {
    @Environment(AssistantController.self) private var assistant
    var body: some View {
        Button { assistant.toggle() } label: {
            Label(L10n.text("Assistant"), systemImage: "sparkles")
        }
        .accessibilityLabel(L10n.text(assistant.isOpen ? "Close Assistant" : "Open Assistant"))
        .accessibilityIdentifier("assistant.open")
        #if os(macOS)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .help(L10n.text("Assistant (⇧⌘A)"))
        #endif
    }
}
#endif

#if os(tvOS)
/// Apple TV's round button at the top of Watch Now and Discover, as Discover's search button is.
struct AssistantTVButton: View {
    @Environment(AssistantController.self) private var assistant
    @AppStorage(AgentSettings.enabledKey) private var enabled = false
    var body: some View {
        if enabled { button }
    }
    private var button: some View {
        Button { assistant.setOpen(true) } label: {
            Image(systemName: "sparkles").font(.system(size: 28))
                .frame(width: 76, height: 76).glassSurface(.regular, in: Circle())
        }
        .tileButton()
        .accessibilityLabel(L10n.text("Assistant"))
        .accessibilityIdentifier("assistant.open")
    }
}
#endif

private struct AssistantHost: ViewModifier {
    @Environment(AssistantController.self) private var assistant
    @Environment(Store.self) private var store
    @AppStorage(AgentSettings.enabledKey) private var enabled = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0
    /// The panel's own drag back to the right: decided on the first move, so a scroll isn't taken for it.
    @State private var closing: Bool?
    #endif

    func body(content: Content) -> some View {
        @Bindable var assistant = assistant
        #if os(iOS)
        let docked = sizeClass == .regular && width >= 700
        let panelWidth = docked ? min(400, (width * 0.45).rounded()) : width
        let shown = assistant.pull ?? (assistant.isOpen ? 1 : 0)
        content
            .onAppear { assistant.attach(store) }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // iPad: the page narrows beside the open panel once the finger lets go.
            .padding(.trailing, enabled && docked && assistant.isOpen && assistant.pull == nil ? panelWidth : 0)
            .background { if enabled && docked && assistant.isOpen { Backdrop() } }
            .overlay(alignment: .trailing) {
                if enabled, assistant.hasOpened, panelWidth > 0 {
                    AssistantPanel()
                        .frame(width: panelWidth)
                        .overlay(alignment: .leading) { if docked { Divider().ignoresSafeArea() } }
                        .shadow(color: .black.opacity(docked || shown < 1 ? 0.18 * shown : 0), radius: 18)
                        .offset(x: (1 - shown) * (panelWidth + 24))
                        .allowsHitTesting(shown > 0.01)
                        .accessibilityHidden(!assistant.isOpen)
                        .opacity(shown > 0 ? 1 : 0)
                        .simultaneousGesture(closeDrag(panelWidth))
                        .accessibilityAction(.escape) { assistant.setOpen(false) }
                }
            }
            .background {
                if enabled {
                    AssistantEdgeSwipe(canBegin: { canPull }, began: { assistant.pullBegan() },
                                       changed: { dx in assistant.pull = min(1, max(0, -dx / max(panelWidth, 1))) },
                                       ended: { dx, vx in
                                           let pulled = -dx / max(panelWidth, 1)
                                           assistant.setOpen(vx < -500 || (pulled > 0.35 && vx < 300))
                                       })
                }
            }
        #elseif os(macOS)
        content
            .onAppear { assistant.attach(store) }
            .inspector(isPresented: Binding(get: { enabled && assistant.isOpen }, set: { assistant.isOpen = $0 })) {
                AssistantPanel()
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
            }
        #else
        content
            .onAppear { assistant.attach(store) }
            .fullScreenCover(isPresented: Binding(get: { enabled && assistant.isOpen }, set: { assistant.isOpen = $0 })) {
                AssistantTVPage().environment(assistant).environment(store)
            }
        #endif
    }

    #if os(iOS)
    /// Only on Watch Now's or Discover's own page, with nothing over it.
    private var canPull: Bool {
        !assistant.isOpen && assistant.entryPages.contains(store.section) && store.playing == nil
            && store.catalogSearchSheets.isEmpty && !store.music.presentsPlayer
    }

    private func closeDrag(_ panelWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .global)
            .onChanged { value in
                guard assistant.isOpen else { return }
                if closing == nil {
                    closing = value.translation.width > 0 && abs(value.translation.width) > abs(value.translation.height) * 1.4
                }
                guard closing == true else { return }
                assistant.pull = min(1, max(0, 1 - value.translation.width / max(panelWidth, 1)))
            }
            .onEnded { value in
                defer { closing = nil }
                guard closing == true else { return }
                let pulled = value.translation.width / max(panelWidth, 1)
                assistant.setOpen(!(value.velocity.width > 500 || (pulled > 0.4 && value.velocity.width > -300)))
            }
    }
    #endif
}

#if os(iOS)
/// A pan that starts within 24 pt of the window's right edge and moves left. It sits on the window, so it sees touches
/// before the page does; any other pan starting there (a shelf scrolling sideways) waits for it to decline, and one
/// starting anywhere else never reaches it. Nothing over the page (a sheet, the player) lets it start.
private struct AssistantEdgeSwipe: UIViewRepresentable {
    var canBegin: () -> Bool
    var began: () -> Void
    var changed: (CGFloat) -> Void
    var ended: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeUIView(context: Context) -> Anchor {
        let view = Anchor()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) { context.coordinator.parent = self }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.detach() }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Anchor: UIView {
        weak var coordinator: Coordinator?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: AssistantEdgeSwipe
        static let edge: CGFloat = 24
        private weak var window: UIWindow?
        private var pan: UIPanGestureRecognizer?
        init(parent: AssistantEdgeSwipe) { self.parent = parent }

        func attach(to window: UIWindow?) {
            guard window !== self.window else { return }
            detach()
            guard let window else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            pan.name = "assistant.edgeSwipe"
            window.addGestureRecognizer(pan)
            self.pan = pan
            self.window = window
        }

        func detach() {
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            pan = nil
            window = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let window else { return false }
            return touch.location(in: window).x >= window.bounds.width - Self.edge
                && window.rootViewController?.presentedViewController == nil && parent.canBegin()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: window)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other is UIPanGestureRecognizer && other !== pan
        }

        @objc private func handle(_ pan: UIPanGestureRecognizer) {
            let translation = pan.translation(in: window).x
            switch pan.state {
            case .began: parent.began(); parent.changed(translation)
            case .changed: parent.changed(translation)
            case .ended: parent.ended(translation, pan.velocity(in: window).x)
            case .cancelled, .failed: parent.ended(0, 0)
            default: break
            }
        }
    }
}
#endif

#if os(tvOS)
/// The assistant on Apple TV: the mark and its actions on the left, as Settings' pages are, and the conversation with
/// its text field on the right. The text field takes dictation from the remote's microphone.
struct AssistantTVPage: View {
    @Environment(AssistantController.self) private var assistant
    var body: some View {
        @Bindable var assistant = assistant
        NavigationStack {
            HStack(alignment: .center, spacing: 72) {
                VStack(spacing: 30) {
                    AssistantBadge(size: 200)
                    VStack(spacing: 10) {
                        Text(L10n.text("Assistant")).font(.system(size: 48, weight: .bold))
                        if !assistant.model.isEmpty {
                            Text(assistant.model).font(.system(size: 26)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    VStack(alignment: .leading, spacing: 4) {
                        TVSettingsAction(title: L10n.text("Clear Conversation"), destructive: true) { assistant.clear() }
                            .disabled(assistant.messages.isEmpty)
                        TVSettingsLink(title: L10n.text("Assistant Settings")) { AssistantSettingsView() }
                    }
                    .frame(width: 520)
                    .focusSection()
                }
                .frame(width: 560).frame(maxHeight: .infinity)
                VStack(spacing: 0) {
                    AssistantTranscript()
                    AssistantComposer().padding(.top, 12).focusSection()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
            }
            .padding(.horizontal, Layout.gutter)
            .padding(.vertical, 40)
            .screenBackdrop()
            .routeDestinations()
            .navigationDestination(isPresented: $assistant.showsSettings) { AssistantSettingsView() }
            .onAppear { assistant.prepare() }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
#endif
