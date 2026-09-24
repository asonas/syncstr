import AVFoundation
import Foundation

@main
struct PlaybackCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "PlaybackCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Supply the test album folder"])
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let tracks = try MusicFiles.list(in: folder)
        guard tracks.count == 9 else {
            throw NSError(domain: "PlaybackCheck", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Expected 9 MP3 tracks, got \(tracks.count)"])
        }
        for (index, track) in tracks.enumerated() {
            precondition(track.lastPathComponent.hasPrefix(String(format: "%02d ", index + 1)))
            let player = try AVAudioPlayer(data: Data(contentsOf: track))
            precondition(player.duration > 0)
            player.volume = 0
            precondition(player.play(), "Audio engine failed to start")
            Thread.sleep(forTimeInterval: 0.2)
            precondition(player.currentTime > 0, "Playback clock did not advance")
            player.pause()
            precondition(!player.isPlaying)
            precondition(player.play(), "Playback failed to resume")
            player.stop()
        }
        print("PASS: 9 MP3 tracks listed in order, decoded, started, paused and resumed (muted).")
    }
}
