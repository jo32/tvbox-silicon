#if os(tvOS) || os(macOS)
import SwiftUI
import AVFoundation
import TVCore

/// Connects the Bilibili cast receiver to the app: a cast opens the player, and the phone's
/// pause, seek and stop drive it, while the player's progress goes back to the phone.
@MainActor final class BilibiliCastController {
    static let shared = BilibiliCastController()
    static let key = "bilibiliCastEnabled"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    private weak var store: Store?
    private var ticker: Task<Void, Never>?

    func start(_ store: Store) {
        self.store = store
        guard Self.enabled, store.extrasUnlocked, ticker == nil else { return }
        let receiver = BilibiliCastReceiver.shared
        #if os(tvOS)
        receiver.name = L10n.text("Yingxia") + " · Apple TV"
        #else
        receiver.name = L10n.text("Yingxia") + " · " + (Host.current().localizedName ?? "Mac")
        #endif
        receiver.onEvent = { event in Task { @MainActor in BilibiliCastController.shared.handle(event) } }
        receiver.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.report()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        ticker?.cancel(); ticker = nil
        BilibiliCastReceiver.shared.stop()
    }

    private func report() {
        guard store?.playing != nil, let player = PlaybackSession.current?.player, let item = player.currentItem else {
            BilibiliCastReceiver.shared.update(nil); return
        }
        let duration = item.duration.seconds, position = player.currentTime().seconds
        BilibiliCastReceiver.shared.update(.init(playing: player.rate != 0, position: position.isFinite ? position : 0, duration: duration.isFinite ? duration : 0))
    }

    private func handle(_ event: BilibiliCastReceiver.Event) {
        let player = PlaybackSession.current?.player
        switch event {
        case .play(let aid, let cid, let episode):
            Task {
                do {
                    BilibiliCastReceiver.log("play aid=\(aid) cid=\(cid) ep=\(episode)")
                    let channel = try await Bilibili.castChannel(aid: aid, cid: cid, episode: episode, in: store?.subscription)
                    BilibiliCastReceiver.log("resolved \(channel.url.absoluteString.prefix(80))")
                    // A new cast replaces what is playing: close the player first so it starts afresh.
                    if store?.playing != nil { store?.playing = nil; try? await Task.sleep(for: .milliseconds(700)) }
                    store?.playing = channel
                } catch { BilibiliCastReceiver.log("play failed \(error)"); store?.error = error.localizedDescription }
            }
        case .live(let room):
            Task {
                // The room plays through Yingxia's own Bilibili Live platform, which names it when it starts.
                guard let platform = LivePlatform(rawValue: "bilibili"), let url = URL(string: "\(platform.scheme)://room/\(room)") else {
                    store?.error = L10n.text("The phone sent a video this app can't open."); return
                }
                if store?.playing != nil { store?.playing = nil; try? await Task.sleep(for: .milliseconds(700)) }
                store?.playing = Channel(name: "", group: platform.name, url: url)
            }
        case .media(let url, let title):
            Task {
                // The phone casts Bilibili videos to DLNA TVs as a 720p MP4. When the part can be identified,
                // play the video itself instead: its HD streams (up to what the account allows) and danmaku.
                if let cid = Bilibili.castCID(url), let aid = await Bilibili.castVideo(cid: cid, title: title),
                   let channel = try? await Bilibili.castChannel(aid: aid, cid: cid, episode: 0, in: store?.subscription) {
                    BilibiliCastReceiver.log("play hd aid=\(aid) cid=\(cid)")
                    if store?.playing != nil { store?.playing = nil; try? await Task.sleep(for: .milliseconds(700)) }
                    store?.playing = channel
                    return
                }
                let comments = DanmakuSource.registerBilibiliMedia(url)
                BilibiliCastReceiver.log("play media danmaku=\(comments) \(url.absoluteString.prefix(120))")
                if store?.playing != nil { store?.playing = nil; try? await Task.sleep(for: .milliseconds(700)) }
                // Bilibili's CDN wants its referer; other servers ignore it.
                store?.playing = Channel(name: title.isEmpty ? L10n.text("Bilibili") : title, group: L10n.text("Bilibili"), url: url,
                                         headers: ["Referer": "https://www.bilibili.com/", "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"])
            }
        case .pause: player?.pause()
        case .resume: player?.play()
        case .stop: store?.playing = nil
        case .seek(let seconds): player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        case .danmaku(let on): UserDefaults.standard.set(on, forKey: DanmakuPreference.key)
        }
    }
}
#endif
