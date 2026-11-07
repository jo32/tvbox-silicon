import SwiftUI
import TVCore
#if os(iOS) || os(tvOS)
import UIKit
#endif
#if os(iOS)
import AVKit
#endif

/// How other devices name this one.
@MainActor enum PlayOnDevice {
    static var name: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }
}

#if os(tvOS) || os(macOS)
/// Plays what Yingxia on another device sends (PlayOn): a catalog episode through this device's own copy
/// of its source, so Next and the episode list work here too, else the stream as the sender had it.
@MainActor @Observable final class PlayOnController {
    static let shared = PlayOnController()
    static let key = "playOnReceives"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// What is being opened and who sent it, shown until the player opens.
    private(set) var incoming: (title: String, sender: String)?
    @ObservationIgnored private weak var store: Store?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(_ store: Store) {
        self.store = store
        guard Self.enabled else { return }
        let receiver = PlayOnReceiver.shared
        #if os(macOS)
        receiver.kind = .mac
        #endif
        receiver.onRequest = { request in await PlayOnController.shared.handle(request) }
        receiver.start()
    }

    func stop() { PlayOnReceiver.shared.stop() }

    /// How a request plays here.
    private enum Plan {
        /// A catalog episode, resolved again through this device's source.
        case source(CatalogClient, PlaybackHistoryContext, Video?)
        /// A channel that plays as it is: a Cloud Files file, a live room or a stream on the network.
        case channel(Channel)
    }

    private func handle(_ request: PlayOn.Request) -> PlayOn.Reply {
        guard let store else { return PlayOn.Reply(accepted: false) }
        let here = PlayOnReceiver.shared.name
        let sent = request.channel, position = request.position.flatMap { $0.isFinite && $0 > 1 ? $0 : nil }
        // The stream as the sender had it, when it doesn't live inside the sender's app.
        let direct = PlayOn.isPortable(sent.url)
            ? Channel(name: sent.name, group: sent.group, url: sent.url, logo: sent.logo, headers: sent.headers,
                      skipScope: sent.skipScope, historyContext: sent.historyContext, resumePosition: position)
            : nil
        let plan: Plan
        if let context = sent.historyContext, context.sourceKey == CloudFiles.sourceKey {
            guard CloudFiles.drive(key: context.episodeFlag) != nil else {
                return PlayOn.Reply(accepted: false, message: L10n.text("This file's drive isn't in Cloud Files on %@. Add it there, then try again.", here))
            }
            plan = .channel(CloudFiles.channel(context, resumePosition: position))
        } else if let context = sent.historyContext, let config = store.subscription,
                  let site = config.sites.first(where: { $0.origin(or: config.origin) == context.origin && $0.sourceKey == context.sourceKey }) {
            let client = CatalogClient(site: site, origin: config.origin, jarURL: config.spiderURL).applying(config)
            plan = .source(client, context, request.video)
        } else if let direct {
            plan = .channel(direct)
        } else if let context = sent.historyContext {
            return PlayOn.Reply(accepted: false, message: L10n.text("Yingxia on %@ doesn't have the source %@. Add the same subscription there, then try again.", here, context.sourceName))
        } else {
            return PlayOn.Reply(accepted: false, message: L10n.text("This video plays from inside Yingxia on this device, so %@ can't open it.", here))
        }
        let route = switch plan { case .source: "source"; case .channel(let channel): CloudFiles.isFile(channel.url) ? "file" : "direct" }
        Diagnostics.shared.record(.info, "play-on", "request source=\(sent.historyContext?.sourceKey ?? "-") route=\(route)")
        task?.cancel()
        incoming = (sent.historyContext.map { "\($0.videoName) · \($0.episodeName)" } ?? sent.name, request.sender)
        task = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.incoming = nil } }
            let channel: Channel
            switch plan {
            case .channel(let ready): channel = ready
            case .source(let client, let context, let video):
                do { channel = try await self.resolve(context, video: video, client: client, position: position) }
                catch {
                    guard !Task.isCancelled else { return }
                    Diagnostics.shared.failure("play-on", "resolve source=\(context.sourceKey)", error)
                    // The sender's own stream may still open here.
                    guard let direct else {
                        store.error = L10n.text("Couldn't play what %@ sent: %@", request.sender, error.localizedDescription)
                        return
                    }
                    channel = direct
                }
            }
            guard !Task.isCancelled else { return }
            store.cancelResume()
            // Whatever plays here makes way: the player closes first so the new one starts afresh.
            if store.playing != nil { store.playing = nil; try? await Task.sleep(for: .milliseconds(700)) }
            guard !Task.isCancelled else { return }
            store.playing = channel
        }
        return PlayOn.Reply(accepted: true)
    }

    /// The episode's stream from this device's source, as Continue Watching resumes one.
    private func resolve(_ context: PlaybackHistoryContext, video sent: Video?, client: CatalogClient, position: Double?) async throws -> Channel {
        guard let store else { throw CancellationError() }
        var video: Video
        if let sent, context.episode(in: sent.episodes) != nil { video = sent }
        else { video = try await client.detail(context.videoID, cached: client.site.type == 3 || client.site.type == 4) }
        guard var episode = context.episode(in: video.episodes) else {
            throw TVError.unsupported(L10n.text("The saved episode is no longer available from this source. Choose an episode again."))
        }
        let resolved: Channel
        do { resolved = try await client.playback(episode) }
        catch {
            // The details may be stale (or the sender's): fetch them here and try once more.
            try Task.checkCancellation()
            video = try await client.detail(context.videoID)
            guard let refreshed = context.episode(in: video.episodes) else { throw error }
            episode = refreshed
            resolved = try await client.playback(refreshed)
        }
        try Task.checkCancellation()
        return store.catalogChannel(resolved, video: video.keepingPoster(context.poster, headers: context.posterHeaders),
                                    episode: episode, client: client, resumePosition: position)
    }
}

/// What another device sent and from where, at the top of the window until the player opens.
struct PlayOnIncoming: View {
    var body: some View {
        if let incoming = PlayOnController.shared.incoming {
            HStack(spacing: Self.spacing) {
                ProgressView()
                    #if os(macOS)
                    .appControlSize(.small)
                    #endif
                VStack(alignment: .leading, spacing: 4) {
                    Text(incoming.title).font(.headline).lineLimit(1)
                    Text(L10n.text("From %@", incoming.sender)).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Self.spacing * 1.8).padding(.vertical, Self.spacing * 1.1)
            .glassSurface(.regular, in: Capsule())
            .frame(maxWidth: 900)
            .padding(.top, Self.spacing * 2.2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    #if os(tvOS)
    private static let spacing: CGFloat = 18
    #else
    private static let spacing: CGFloat = 10
    #endif
}
#endif

#if os(iOS) || os(macOS)
/// The player's Play On button (iPhone, iPad and Mac), like AirPlay's: shown while Yingxia is open on an
/// Apple TV or another Mac on this network, it sends what plays here to the one chosen, then pauses here.
/// On iPhone and iPad it takes the AirPlay button's place, with AirPlay as the menu's last item.
struct PlayOnButton: View {
    let channel: Channel
    let session: PlaybackSession
    let browser: PlayOnBrowser
    /// The receiver took it: the name it goes by.
    let sent: (String) -> Void
    @Environment(Store.self) private var store
    @State private var sending: String?
    @State private var failure: (receiver: String, message: String)?
    #if os(iOS)
    @State private var airPlay = AirPlayPicker()
    #endif

    var body: some View {
        Menu {
            Section(L10n.text("Play On")) {
                ForEach(browser.receivers) { receiver in
                    Button { send(to: receiver) } label: { Label(receiver.name, systemImage: Self.symbol(receiver.kind)) }
                }
            }
            #if os(iOS)
            Section {
                Button(action: airPlay.present) { Label(L10n.text("AirPlay"), systemImage: "airplay.video") }
            }
            #endif
        } label: {
            #if os(macOS)
            // As the Mac player's other buttons (DesktopPlaybackView's options menu).
            Group {
                if sending != nil { ProgressView().appControlSize(.small) }
                else { Image(systemName: symbol).font(.system(size: 14, weight: .medium)) }
            }
            .frame(width: 34, height: 34).contentShape(Circle())
            #else
            Group {
                if sending != nil { ProgressView().tint(.white) }
                else { Image(systemName: "airplay.video").font(.headline) }
            }
            .frame(width: 22, height: 22)
            #endif
        }
        #if os(iOS)
        // The picker AirPlay opens from, and where an iPad's popover points; all but invisible, not hidden.
        .background { AirPlayPickerView(picker: airPlay).opacity(0.02).allowsHitTesting(false) }
        #endif
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .glassSurface(.regular.interactive(), in: Circle())
        .help(L10n.text("Play on Another Device"))
        #else
        .chromeButton()
        #endif
        .disabled(sending != nil)
        .accessibilityLabel(L10n.text("Play on Another Device"))
        .accessibilityIdentifier("player.playOn")
        .alert(L10n.text("Couldn't Play on %@", failure?.receiver ?? ""), isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(L10n.text("OK"), role: .cancel) { failure = nil }
        } message: { Text(failure?.message ?? "") }
        #if DEBUG
        // `-qaPlayOn <name or *>`: sends to that device once it shows up, once per launch, after
        // `-qaPlayOnDelay <seconds>` of playback.
        .onChange(of: browser.receivers, initial: true) { _, receivers in
            guard let wanted = UserDefaults.standard.string(forKey: "qaPlayOn"), !Self.qaSent,
                  let receiver = receivers.first(where: { $0.name == wanted || wanted == "*" }) else { return }
            Self.qaSent = true
            Task {
                try? await Task.sleep(for: .seconds(UserDefaults.standard.double(forKey: "qaPlayOnDelay")))
                send(to: receiver)
            }
        }
        #if os(iOS)
        // `-qaAirPlay 1`: opens the AirPlay picker from here a few seconds in.
        .task {
            guard UserDefaults.standard.bool(forKey: "qaAirPlay") else { return }
            try? await Task.sleep(for: .seconds(4))
            airPlay.present()
        }
        #endif
        #endif
    }
    #if DEBUG
    @MainActor private static var qaSent = false
    #endif

    #if os(macOS)
    /// An Apple TV while every device found is one; a screen once a Mac is among them.
    private var symbol: String { browser.receivers.allSatisfy { $0.kind == .tv } ? "appletv" : "play.tv" }
    #endif
    private static func symbol(_ kind: PlayOn.Kind) -> String { kind == .tv ? "appletv" : "display" }

    private func send(to receiver: PlayOnBrowser.Receiver) {
        let position = session.isLive ? nil : session.player.currentTime().seconds
        let request = PlayOn.Request(sender: PlayOnDevice.name, channel: channel, position: position,
                                     video: store.catalog(for: channel)?.video)
        sending = receiver.name
        Task {
            defer { sending = nil }
            do {
                let reply = try await PlayOnBrowser.send(request, to: receiver)
                Diagnostics.shared.record(.info, "play-on", "sent kind=\(receiver.kind.rawValue) accepted=\(reply.accepted)")
                if reply.accepted { sent(receiver.name) }
                else { failure = (receiver.name, reply.message ?? L10n.text("%@ couldn't play this video.", receiver.name)) }
            } catch {
                Diagnostics.shared.failure("play-on", "send", error)
                failure = (receiver.name, error.localizedDescription)
            }
        }
    }
}

#if os(iOS)
/// The system's AirPlay picker, opened from a menu item: AVRoutePickerView has no call for that, so this
/// taps its button.
@MainActor final class AirPlayPicker {
    fileprivate let view: AVRoutePickerView = {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        return view
    }()

    func present() {
        func button(in view: UIView) -> UIButton? { view as? UIButton ?? view.subviews.lazy.compactMap(button).first }
        button(in: view)?.sendActions(for: .touchUpInside)
    }
}

private struct AirPlayPickerView: UIViewRepresentable {
    let picker: AirPlayPicker
    func makeUIView(context: Context) -> AVRoutePickerView { picker.view }
    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif

/// Over the paused picture once another device has the video: where it plays, and a way to carry on here instead.
struct PlayOnPlaceholder: View {
    let receiver: String
    let playHere: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.tv").font(.system(size: 48, weight: .light))
            Text(L10n.text("Playing on %@", receiver)).font(.callout)
            Button(L10n.text("Play Here"), action: playHere)
                .controlButton()
                .accessibilityIdentifier("player.playHere")
        }
        .foregroundStyle(.white.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(32)
    }
}
#endif
