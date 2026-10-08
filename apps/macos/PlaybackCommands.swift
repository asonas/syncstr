import SwiftUI
#if os(macOS)
import AppKit
#endif

struct PlaybackCommands: Commands {
    @FocusedObject private var library: Library?

    var body: some Commands {
        CommandMenu("コントロール") {
            Button(library?.playing == true || library?.loading == true ? "一時停止" : "再生") {
                library?.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(library?.current == nil)
            Button("次のトラック") { library?.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(library?.canGoNext != true)
            Button("前のトラック") { library?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(library?.canGoPrevious != true)
            Button("シャッフルを切り替え") {
                if let library { library.setShuffle(!library.shuffled) }
            }
            .keyboardShortcut(.space, modifiers: .option)
            .disabled(library?.connected != true)
            Button("現在の曲に移動") {
#if os(macOS)
                NSApp.keyWindow?.makeFirstResponder(nil)
#endif
                library?.search = ""
                library?.showingNowPlaying = true
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(library?.current == nil)
            Divider()
            Button("音量を上げる") {
                if let library { library.setVolume((library.volume * 100 + 10).rounded() / 100) }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(library == nil || library?.volume == 1)
            Button("音量を下げる") {
                if let library { library.setVolume((library.volume * 100 - 10).rounded() / 100) }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(library == nil || library?.volume == 0)
            Button("音量を最大に設定") { library?.setVolume(1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                .disabled(library == nil || library?.volume == 1)
            Button("音量を最小に設定") { library?.setVolume(0) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                .disabled(library == nil || library?.volume == 0)
            Divider()
            Toggle("シャッフル", isOn: Binding(
                get: { library?.shuffled ?? false },
                set: { library?.setShuffle($0) }
            ))
            .disabled(library?.connected != true)
            Picker("リピート", selection: Binding(
                get: { library?.repeatMode ?? .off },
                set: { library?.repeatMode = $0 }
            )) {
                ForEach(PlaybackRepeat.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(library?.connected != true)
            Divider()
            Button("戻る") {
#if os(macOS)
                NSApp.keyWindow?.makeFirstResponder(nil)
#endif
                library?.showingNowPlaying = false
            }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(library?.showingNowPlaying != true)
        }
    }
}
