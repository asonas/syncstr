import Foundation
import AVFoundation
import AudioToolbox

enum SharedAudioPlayback {
    static func player(_ url: URL) -> AVPlayer {
        guard url.isFileURL, url.pathExtension == "audio" else { return AVPlayer(url: url) }
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return AVPlayer(url: url) }
        defer { AudioFileClose(file) }
        var format: AudioFileTypeID = 0
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(file, kAudioFilePropertyFileFormat, &size, &format) == noErr else { return AVPlayer(url: url) }
        var types: Unmanaged<CFArray>?
        var typesSize = UInt32(MemoryLayout.size(ofValue: types))
        guard AudioFileGetGlobalInfo(kAudioFileGlobalInfo_MIMETypesForType, size, &format, &typesSize, &types) == noErr,
              let mime = (types?.takeRetainedValue() as? [String])?.first else { return AVPlayer(url: url) }
        // Hash paths deliberately omit the encoding; identify it from verified local bytes.
        let asset = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: mime])
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
}
