#if os(iOS)
import MediaPlayer
import TVCore
import UIKit

extension Store {
    /// The one store, which the Lock Screen controls reach outside any view.
    static let shared = Store()
}

/// The song playing, and its controls, on the Lock Screen, in Control Center, on headphones and
/// in the car's own Now Playing screen. Music holds the system's Now Playing
/// while it has a song and no video plays; the video player uses it otherwise.
@MainActor final class MusicRemoteControl {
    static let shared = MusicRemoteControl(store: .shared)

    private let store: Store
    private var active = false
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    private init(store: Store) {
        self.store = store
        update()
        observe()
    }

    /// What the Now Playing info depends on. The position is read when it is written, not
    /// watched: the system runs the clock on from the elapsed time and the rate.
    private struct State: Equatable {
        var track: String?
        var phase: MusicPlaybackSession.Phase
        var duration: Double?
        var index: Int?
        var count: Int
        var seeking: Bool
        var video: Bool
        var repeatMode: MusicRepeatMode
        var shuffled: Bool
        var advances: Bool
    }

    private var state: State {
        let music = store.music
        return State(track: music.track?.id, phase: music.phase, duration: music.duration, index: music.queue?.index,
                     count: music.queue?.tracks.count ?? 0, seeking: music.seekingTo != nil, video: store.playing != nil,
                     repeatMode: music.repeatMode, shuffled: music.shuffled, advances: music.canAdvance)
    }

    private func observe() {
        withObservationTracking { _ = state } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.update(); self?.observe() }
        }
    }

    private func update() {
        let music = store.music, center = MPNowPlayingInfoCenter.default()
        guard let track = music.track, store.playing == nil else {
            if active {
                active = false
                for (command, target) in targets { command.removeTarget(target) }
                targets = []
                center.nowPlayingInfo = nil
                center.playbackState = .stopped
            }
            return
        }
        if !active { active = true; addTargets() }
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = music.canAdvance
        commands.changeRepeatModeCommand.currentRepeatType = switch music.repeatMode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
        commands.changeShuffleModeCommand.currentShuffleType = music.shuffled ? .items : .off
        commands.previousTrackCommand.isEnabled = true

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistLine,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: music.seekingTo ?? music.position,
            MPNowPlayingInfoPropertyPlaybackRate: music.phase == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let album = track.album ?? music.queue?.source { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = music.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let queue = music.queue, queue.tracks.count > 1 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queue.index
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.tracks.count
        }
        if track.artwork != artworkURL { loadArtwork(track.artwork) }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = switch music.phase {
        case .playing: .playing
        case .idle: .stopped
        default: .paused
        }
    }

    private func loadArtwork(_ url: URL?) {
        artworkURL = url; artwork = nil
        artworkTask?.cancel()
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let bitmap = await PosterPalette.image(url), !Task.isCancelled, let self, self.artworkURL == url else { return }
            self.artwork = Self.artwork(UIImage(cgImage: bitmap))
            self.update()
        }
    }

    /// MediaPlayer asks for the image on its own queue: a closure made on the main actor would
    /// trap there, checking it runs on the main thread.
    private nonisolated static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func addTargets() {
        let commands = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MusicPlaybackSession, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                MainActor.assumeIsolated {
                    guard let music = self?.store.music, music.track != nil else { return .noActionableNowPlayingItem }
                    return action(music, event)
                }
            }
            targets.append((command, target))
        }
        on(commands.playCommand) { music, _ in
            if music.phase != .playing && music.phase != .loading { music.toggle() }
            return .success
        }
        on(commands.pauseCommand) { music, _ in music.pause(); return .success }
        on(commands.togglePlayPauseCommand) { music, _ in music.toggle(); return .success }
        on(commands.nextTrackCommand) { music, _ in
            guard music.canAdvance else { return .noSuchContent }
            music.next(); return .success
        }
        on(commands.previousTrackCommand) { music, _ in music.previous(); return .success }
        // The car's and the Lock Screen's repeat and shuffle buttons (#1281).
        on(commands.changeRepeatModeCommand) { music, event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: MusicRepeatMode = switch event.repeatType {
            case .one: .one
            case .all: .all
            default: .off
            }
            music.setRepeat(mode)
            return .success
        }
        on(commands.changeShuffleModeCommand) { music, event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            music.setShuffle(event.shuffleType != .off)
            return .success
        }
        on(commands.changePlaybackPositionCommand) { music, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            music.seek(to: event.positionTime); return .success
        }
    }
}
#endif
