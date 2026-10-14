import AVFoundation
import Combine
import MediaPlayer
#if os(macOS)
import CoreAudio
#endif

@MainActor
final class PhonePlayback: ObservableObject {
    private let library: Library
    private var targets: [(MPRemoteCommand, Any)] = []
    private var changes: AnyCancellable?
    private var interruption: AnyCancellable?
    private var routeChange: AnyCancellable?
#if os(macOS)
    private var output: MacPlaybackOutput?
#endif

    init(library: Library) {
        self.library = library
        let commands = MPRemoteCommandCenter.shared()
        register(commands.playCommand) { [weak self] _ in
            Task { @MainActor in
                guard let library = self?.library else { return }
                library.resumePlayback()
            }
            return .success
        }
        register(commands.pauseCommand) { [weak self] _ in
            Task { @MainActor in
                guard let library = self?.library else { return }
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
#if os(iOS)
        interruption = NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor in
                    guard type == AVAudioSession.InterruptionType.began.rawValue,
                          let library = self?.library, library.playing || library.loading else { return }
                    library.pause()
                }
            }
        routeChange = NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                    self?.library.pause()
                }
            }
#endif
#if os(macOS)
        output = MacPlaybackOutput { [weak library] in library?.pause() }
#endif
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
        commands.changePlaybackPositionCommand.isEnabled = library.canSeek
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
#if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = library.playing ? .playing : .paused
#endif
    }
}

#if os(macOS)
@MainActor
private final class MacPlaybackOutput {
    private let pause: () -> Void
    private var device: AudioDeviceID = 0
    private var jack: UInt32?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(pause: @escaping () -> Void) {
        self.pause = pause
        observe(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        update()
    }

    deinit {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
    }

    private func observe(_ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func update() {
        if device != 0 {
            let nextJack = read(device, kAudioDevicePropertyJackIsConnected, scope: kAudioDevicePropertyScopeOutput)
            if read(device, kAudioDevicePropertyDeviceIsAlive) != 1 || (jack == 1 && nextJack == 0) { pause() }
            jack = nextJack
        }
        guard let next = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice), next != device else { return }
        let oldDevice = device
        for (object, address, block) in listeners where object == oldDevice {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners.removeAll { $0.0 == oldDevice }
        device = next
        jack = read(device, kAudioDevicePropertyJackIsConnected, scope: kAudioDevicePropertyScopeOutput)
        observe(device, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)
        observe(device, selector: kAudioDevicePropertyJackIsConnected, scope: kAudioDevicePropertyScopeOutput)
    }
}
#endif
