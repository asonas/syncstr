import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class PhonePlayback: ObservableObject {
    private let library: Library
    private var targets: [(MPRemoteCommand, Any)] = []
    private var changes: AnyCancellable?
    private var interruption: AnyCancellable?

    init(library: Library) {
        self.library = library
        let commands = MPRemoteCommandCenter.shared()
        register(commands.playCommand) { [weak self] _ in
            Task { @MainActor in
                guard let library = self?.library, !library.playing && !library.loading else { return }
                library.togglePlayback()
            }
            return .success
        }
        register(commands.pauseCommand) { [weak self] _ in
            Task { @MainActor in
                guard let library = self?.library, library.playing || library.loading else { return }
                library.pause()
            }
            return .success
        }
        register(commands.togglePlayPauseCommand) { [weak self] _ in
            Task { @MainActor in self?.library.togglePlayback() }
            return .success
        }
        register(commands.nextTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.library.next() }
            return .success
        }
        register(commands.previousTrackCommand) { [weak self] _ in
            Task { @MainActor in self?.library.previous() }
            return .success
        }
        register(commands.changePlaybackPositionCommand) { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.library.seek(to: position) }
            return .success
        }
        changes = library.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.update() }
        }
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in
                    guard type == AVAudioSession.InterruptionType.began.rawValue,
                          let library = self?.library, library.playing || library.loading else { return }
                    library.pause()
                }
            }
        update()
    }

    deinit {
        for (command, target) in targets { command.removeTarget(target) }
    }

    private func register(_ command: MPRemoteCommand, action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        targets.append((command, command.addTarget(handler: action)))
    }

    private func update() {
        let commands = MPRemoteCommandCenter.shared()
        let selected = library.current != nil
        commands.playCommand.isEnabled = selected
        commands.pauseCommand.isEnabled = selected
        commands.togglePlayPauseCommand.isEnabled = selected
        commands.nextTrackCommand.isEnabled = library.canGoNext
        commands.previousTrackCommand.isEnabled = library.canGoPrevious
        commands.changePlaybackPositionCommand.isEnabled = selected && library.duration > 0
        guard let track = library.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist ?? "アーティスト不明",
            MPMediaItemPropertyAlbumTitle: track.album ?? "",
            MPMediaItemPropertyPlaybackDuration: library.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: library.position,
            MPNowPlayingInfoPropertyPlaybackRate: library.playing ? 1.0 : 0.0
        ]
    }
}
