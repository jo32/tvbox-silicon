#if os(iOS) || os(tvOS)
import UIKit

extension UIApplication {
    /// The app's own window scene, on the device's screen. A connected display can add a second scene
    /// (`ExternalDisplay`), so `connectedScenes.first` may be that one: code that rotates, reads the screen or
    /// shows a window the user must tap uses this instead.
    var appWindowScene: UIWindowScene? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.session.role == .windowApplication }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}
#endif

#if os(iOS)
import AVFoundation
import SwiftUI
import TVCore
import UIKit

/// Shows the playing video on a connected display (HDMI, USB-C or AirPlay).
///
/// The extra display gets one more `AVPlayerLayer` for the player the device is already using: no second
/// stream is fetched, and the sound still comes from that one player only. From iOS 27 the system offers the
/// external-display scene only to apps that register a scene accessory (`ExternalDisplaySceneRegistrar`);
/// earlier systems offer it from the role this app declares in its `Info.plist` scene manifest.
@MainActor final class ExternalDisplay {
    static let shared = ExternalDisplay()

    private weak var player: AVPlayer?
    private var window: UIWindow?
    private var picture: ExternalDisplayViewController?
    private var sceneNotifications: [NSObjectProtocol] = []
    private weak var store: Store?
    private var seriesEndHost: UIHostingController<AnyView>?
    /// Which end-of-series this host is showing. Rebuilding on every change would
    /// restart the countdown the viewer is watching, so the host is reused for the
    /// same one — but a different title must replace it, or the display keeps naming
    /// the show that finished before.
    private var seriesEndShown: SeriesEndKey?

    private init() {
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.didDisconnectNotification] {
            sceneNotifications.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in ExternalDisplay.shared.refresh() }
            })
        }
    }

    /// The player screen appeared: put its picture on the display, if one is connected.
    func attach(_ player: AVPlayer, store: Store? = nil) {
        self.player = player
        if let store { self.store = store }
        refresh()
    }

    /// The player screen closed: the external window goes away. From iOS 27 the accessory is unregistered too
    /// (`ExternalDisplayAccessoryController`), so the system takes the display back; on earlier systems the
    /// app keeps the display's scene and it shows black until the next video.
    func detach(_ player: AVPlayer) {
        guard self.player === player else { return }
        self.player = nil
        picture?.player = nil
        removeSeriesEnd()
        window?.isHidden = true
        window = nil
        picture = nil
    }

    /// Re-reads the connected scenes: a display may have been plugged in or out during playback.
    func refresh() {
        guard let scene = externalScene, let player else {
            window?.isHidden = true
            return
        }
        if window?.windowScene !== scene {
            window?.isHidden = true
            let controller = ExternalDisplayViewController()
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.backgroundColor = .black
            self.window = window
            picture = controller
            window.makeKeyAndVisible()
            Diagnostics.shared.record(.info, "player", "external display connected \(Int(scene.screen.bounds.width))×\(Int(scene.screen.bounds.height))")
        }
        picture?.player = player
        window?.isHidden = false
        syncSeriesEnd()
    }

    /// The store's end-of-series state changed (it appeared, changed titles, or went
    /// away): bring the display's copy in step. Called by `Store` so the card does not
    /// wait for the next scene notification.
    func seriesEndChanged() {
        syncSeriesEnd()
    }

    // MARK: End of series on the display

    /// Mirrors the end-of-series screen onto the display.
    ///
    /// The display showed only the picture, so on a folded-out Duo the inner screen
    /// offered "what next" while the television stayed on the last frame. The card is
    /// the same `SeriesEndScreen` the player draws, hosted here as a plain overlay so
    /// the two stay one piece of UI rather than drifting apart.
    ///
    /// Asked for synchronously from the store's own change, so the card appears with
    /// the countdown rather than a frame later. The card is non-interactive on the
    /// display on purpose: an external display in the non-interactive role cannot take
    /// touches, and offering buttons that cannot be pressed would be worse than none.
    private func syncSeriesEnd() {
        guard let store, let picture, let window, !window.isHidden else { removeSeriesEnd(); return }
        guard let end = store.seriesEnd else { removeSeriesEnd(); return }
        // Already showing this one: nothing to rebuild, and rebuilding would restart
        // the countdown the viewer is watching. A different title replaces it.
        let key = SeriesEndKey(end)
        if seriesEndHost != nil, seriesEndShown == key { return }
        removeSeriesEnd()

        let card = SeriesEndScreen(
            finishedTitle: end.title,
            suggestions: end.suggestions,
            replay: {},
            choose: { _ in },
            dismiss: {}
        )
        .allowsHitTesting(false)

        let host = UIHostingController(rootView: AnyView(card))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        picture.addChild(host)
        picture.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: picture.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: picture.view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: picture.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: picture.view.bottomAnchor),
        ])
        host.didMove(toParent: picture)
        seriesEndHost = host
        seriesEndShown = key
        Diagnostics.shared.record(.info, "player", "external display shows end of series \(end.suggestions.count) suggestions")
    }

    private func removeSeriesEnd() {
        guard let host = seriesEndHost else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        seriesEndHost = nil
        seriesEndShown = nil
    }

    private var externalScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowExternalDisplayNonInteractive }
    }
}

/// Identity of one end-of-series card, so the external display can tell "the same
/// one, keep its countdown" from "a different title, replace it" without comparing
/// whole suggestion lists.
@MainActor
private struct SeriesEndKey: Equatable {
    let title: String
    let count: Int
    let firstSuggestion: String

    init(_ end: Store.SeriesEnd) {
        title = end.title
        count = end.suggestions.count
        firstSuggestion = end.suggestions.first?.id ?? ""
    }
}

/// What the external display shows: the player's picture, with no controls of its own.
private final class ExternalDisplayViewController: UIViewController {
    private let display = PlayerLayerDisplay()

    var player: AVPlayer? {
        get { display.playerLayer.player }
        set { display.playerLayer.player = newValue }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        display.frame = view.bounds
        display.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        display.playerLayer.videoGravity = .resizeAspect
        view.addSubview(display)
    }
}

private final class PlayerLayerDisplay: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// A view in the player screen that registers the external-display accessory (iOS 27). The registration lives
/// only while the player is on screen, so the system takes the display back once playback closes.
struct ExternalDisplaySceneRegistrar: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        if #available(iOS 27.0, *) { return ExternalDisplayAccessoryController() }
        return UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

@available(iOS 27.0, *)
private final class ExternalDisplayAccessoryController: UIViewController {
    private var registration: UISceneAccessoryRegistration?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard registration == nil else { return }
        let configuration = UISceneConfiguration()
        configuration.delegateClass = ExternalDisplaySceneDelegate.self
        registration = registerSceneAccessory(UISceneAccessory.externalNonInteractive(sceneConfiguration: configuration))
    }

    /// Gives the display back as soon as the player leaves the screen, not whenever this controller is freed.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard let registration else { return }
        unregisterSceneAccessory(registration)
        self.registration = nil
    }
}

/// The external-display scene's delegate. Its window is made by `ExternalDisplay`, when a video is playing.
@objc(ExternalDisplaySceneDelegate)
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    // Scene callbacks run on the main thread, which this class isn't isolated to under every SDK.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        MainActor.assumeIsolated { ExternalDisplay.shared.refresh() }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated { ExternalDisplay.shared.refresh() }
    }
}
#endif
